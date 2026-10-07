import Combine
import Foundation
import os

/// The single source of truth for playback. The phone UI and the CarPlay scene
/// both observe this object, which is why the two stay in sync for free.
///
/// Audio is moved by a `PlaybackEngine`, chosen per track from what the source
/// hands back. The controller owns the queue, the metadata and the transport
/// semantics; engines only play.
@MainActor
final class PlayerController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var queue = PlayQueue()
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var lastError: String?

    var currentTrack: Track? { queue.current?.track }

    /// 0...1, safe to bind directly to a progress view.
    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    // MARK: - Dependencies

    private let nowPlaying = NowPlayingCenter()
    private var source: MusicSource

    /// Engines are created on demand and kept, because tearing down and
    /// rebuilding a `WKWebView` on every track would be slow and lose state.
    private lazy var avEngine: AVPlayerEngine = {
        let engine = AVPlayerEngine()
        engine.delegate = self
        return engine
    }()

    private lazy var youTubeEngine: YouTubeEmbedEngine = {
        let engine = YouTubeEmbedEngine()
        engine.delegate = self
        return engine
    }()

    private var activeEngine: PlaybackEngine?

    private let log = Logger(subsystem: "com.example.aura", category: "player")

    // MARK: - Internal state

    /// Generation counter: every new load increments it, so a slow resolution
    /// that finishes after the user has already skipped is discarded instead of
    /// hijacking playback.
    private var loadGeneration = 0

    private var prefetched: (trackID: String, request: PlaybackRequest)?
    private var continuationTask: Task<Void, Never>?

    /// Pressing "previous" within this many seconds goes to the previous track;
    /// after it, it restarts the current one.
    private let restartThreshold: TimeInterval = 4

    /// Consecutive load failures. Skipping a bad track is right, but a backend
    /// that fails everything — expired session, server down, exhausted quota —
    /// would otherwise skip forever while autoplay keeps refilling the queue.
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5

    /// Last elapsed value pushed to the system. The now-playing centre
    /// extrapolates position from elapsed + rate, so pushing on every tick
    /// is wasted work and makes the CarPlay scrubber jitter.
    private var lastPushedElapsed: TimeInterval = -.greatestFiniteMagnitude
    private let nowPlayingPushInterval: TimeInterval = 5

    // MARK: - Init

    init(source: MusicSource) {
        self.source = source
        AudioSessionManager.shared.configure()
        wireRemoteCommands()
    }

    func updateSource(_ newSource: MusicSource) {
        source = newSource
        prefetched = nil
    }

    // MARK: - Public transport

    /// Start a fresh context (album, playlist, shelf row) at `index`.
    func play(tracks: [Track], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        // An explicit choice is a fresh start, not a continuation of a cascade.
        consecutiveFailures = 0
        queue.replace(with: tracks, startingAt: index)
        loadCurrent(autoPlay: true)
        refillContinuationIfNeeded()
    }

    func play(track: Track) {
        play(tracks: [track], startingAt: 0)
    }

    func playNext(_ tracks: [Track]) {
        let wasEmpty = queue.current == nil
        queue.playNext(tracks)
        if wasEmpty { loadCurrent(autoPlay: true) } else { refreshRemoteCommandAvailability() }
    }

    func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.current == nil
        queue.addToQueue(tracks)
        if wasEmpty { loadCurrent(autoPlay: true) } else { refreshRemoteCommandAvailability() }
    }

    func resume() {
        guard queue.current != nil else { return }
        AudioSessionManager.shared.activate()
        activeEngine?.play()
    }

    func pause() {
        activeEngine?.pause()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func next() {
        guard queue.canGoForward else {
            pause()
            return
        }
        queue.advance(userInitiated: true)
        loadCurrent(autoPlay: true)
        refillContinuationIfNeeded()
    }

    /// Mirrors YouTube Music: restart the track unless we're near the beginning.
    func previous() {
        if elapsed > restartThreshold {
            seek(to: 0)
            return
        }
        guard queue.canGoBack else {
            seek(to: 0)
            return
        }
        queue.goBack()
        loadCurrent(autoPlay: true)
    }

    func seek(to time: TimeInterval) {
        activeEngine?.seek(to: time)
    }

    // MARK: - Queue editing

    func jump(to entryID: QueueEntry.ID) {
        queue.jump(to: entryID)
        loadCurrent(autoPlay: true)
        refillContinuationIfNeeded()
    }

    func removeFromQueue(_ entryID: QueueEntry.ID) {
        queue.remove(entryID)
        prefetchUpcoming()
        refreshRemoteCommandAvailability()
    }

    func movePending(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.movePending(fromOffsets: offsets, toOffset: destination)
        prefetchUpcoming()
    }

    func clearUpNext() {
        queue.clearUpNext()
        refreshRemoteCommandAvailability()
    }

    func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
        refreshRemoteCommandAvailability()
    }

    func toggleShuffle() {
        queue.setShuffled(!queue.isShuffled)
        prefetchUpcoming()
    }

    // MARK: - Loading

    private func loadCurrent(autoPlay: Bool) {
        loadGeneration += 1
        let generation = loadGeneration

        guard let entry = queue.current else {
            activeEngine?.teardown()
            activeEngine = nil
            isPlaying = false
            isLoading = false
            elapsed = 0
            duration = nil
            pushNowPlaying()
            return
        }

        // Reset immediately so the UI never shows the previous track's position.
        elapsed = 0
        duration = entry.track.duration
        isLoading = true
        lastError = nil
        pushNowPlaying(force: true)
        refreshRemoteCommandAvailability()

        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.resolveRequest(for: entry.track)
                guard generation == self.loadGeneration else { return }
                self.start(request, autoPlay: autoPlay)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.handleLoadFailure(error, for: entry)
            }
        }
    }

    private func resolveRequest(for track: Track) async throws -> PlaybackRequest {
        if let prefetched, prefetched.trackID == track.id, !prefetched.request.isStale {
            self.prefetched = nil
            return prefetched.request
        }
        return try await source.playbackRequest(for: track)
    }

    private func start(_ request: PlaybackRequest, autoPlay: Bool) {
        let engine = engine(for: request)

        // Switching engines must silence the old one, or two players run at once.
        if activeEngine !== engine {
            activeEngine?.teardown()
            activeEngine = engine
        }

        engine.load(request, autoPlay: autoPlay)
        pushNowPlaying(force: true)
        prefetchUpcoming()
    }

    private func engine(for request: PlaybackRequest) -> PlaybackEngine {
        switch request {
        case .streamURL: return avEngine
        case .youTubeVideo: return youTubeEngine
        }
    }

    private func handleLoadFailure(_ error: Error, for entry: QueueEntry) {
        log.error("Failed to load \(entry.track.title, privacy: .public): \(error.localizedDescription)")
        isLoading = false
        consecutiveFailures += 1

        // One bad track should be skipped, not stall the queue. But a backend
        // failing everything must stop, or autoplay refills faster than we skip
        // and playback spins forever.
        guard consecutiveFailures < maxConsecutiveFailures else {
            log.error("Giving up after \(self.maxConsecutiveFailures) consecutive failures")
            lastError = "Couldn't play anything — \(error.localizedDescription)"
            isPlaying = false
            pause()
            return
        }

        if queue.canGoForward {
            lastError = "Skipped “\(entry.track.title)” — \(error.localizedDescription)"
            next()
        } else {
            lastError = error.localizedDescription
            isPlaying = false
            pause()
        }
    }

    // MARK: - Prefetch & continuation

    /// Resolve the next track's stream early so transitions don't stall on a
    /// network round trip. Only URL-backed sources can be resolved ahead.
    private func prefetchUpcoming() {
        guard let upcoming = queue.upcoming, upcoming.id != queue.current?.id else { return }
        guard prefetched?.trackID != upcoming.track.id else { return }

        let track = upcoming.track
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.source.playbackRequest(for: track)
                guard request.isPrefetchable else { return }
                guard self.queue.upcoming?.track.id == track.id else { return }
                self.prefetched = (track.id, request)
            } catch {
                // Prefetch is best-effort; the real load will surface any error.
                self.log.debug("Prefetch failed for \(track.title, privacy: .public)")
            }
        }
    }

    /// Keep an endless tail of similar tracks behind the user's own queue, so
    /// music never just stops — the behaviour people expect from YouTube Music.
    private func refillContinuationIfNeeded() {
        prefetchUpcoming()

        guard let seed = queue.current?.track else { return }
        guard queue.repeatMode == .off else { return }
        // Only top up when the runway is short.
        guard queue.pending.count < 3 else { return }

        continuationTask?.cancel()
        continuationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let known = self.queue.knownTrackIDs
                let tracks = try await self.source.continuation(seededBy: seed, excluding: known)
                guard !Task.isCancelled, !tracks.isEmpty else { return }
                guard self.queue.current?.track.id == seed.id else { return }

                let fresh = tracks.filter { !self.queue.knownTrackIDs.contains($0.id) }
                guard !fresh.isEmpty else { return }
                self.queue.appendToAutoQueue(fresh)
                self.prefetchUpcoming()
                self.refreshRemoteCommandAvailability()
            } catch {
                self.log.debug("Continuation unavailable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Now playing bridge

    private func wireRemoteCommands() {
        nowPlaying.setHandlers(.init(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] time in self?.seek(to: time) }
        ))
    }

    /// Push metadata to the lock screen, Control Center and CarPlay.
    ///
    /// Throttled unless `force`: the system extrapolates position from elapsed
    /// plus rate, so a push every half second is wasted and visibly jitters the
    /// CarPlay scrubber.
    private func pushNowPlaying(force: Bool = false) {
        if !force, abs(elapsed - lastPushedElapsed) < nowPlayingPushInterval { return }
        lastPushedElapsed = elapsed

        nowPlaying.update(
            track: currentTrack,
            elapsed: elapsed,
            duration: duration,
            rate: isPlaying ? 1 : 0
        )
        refreshRemoteCommandAvailability()
    }

    private func refreshRemoteCommandAvailability() {
        nowPlaying.setCommandsEnabled(
            canGoNext: queue.canGoForward,
            canGoPrevious: queue.canGoBack || elapsed > restartThreshold
        )
    }
}

// MARK: - PlaybackEngineDelegate

extension PlayerController: PlaybackEngineDelegate {

    func engineDidBecomeReady(_ engine: PlaybackEngine) {
        guard engine === activeEngine else { return }
        isLoading = false
        if let engineDuration = engine.duration { duration = engineDuration }
        pushNowPlaying(force: true)
    }

    func engineDidReachEnd(_ engine: PlaybackEngine) {
        guard engine === activeEngine else { return }

        if queue.repeatMode == .one {
            engine.seek(to: 0)
            engine.play()
            return
        }

        if queue.canGoForward {
            queue.advance(userInitiated: false)
            loadCurrent(autoPlay: true)
            refillContinuationIfNeeded()
        } else {
            queue.advance(userInitiated: false)
            isPlaying = false
            elapsed = 0
            loadCurrent(autoPlay: false)
        }
    }

    func engineDidFail(_ engine: PlaybackEngine, error: Error) {
        guard engine === activeEngine, let entry = queue.current else { return }
        handleLoadFailure(error, for: entry)
    }

    func engineDidUpdateTime(_ engine: PlaybackEngine) {
        guard engine === activeEngine else { return }
        elapsed = engine.elapsed
        if let engineDuration = engine.duration { duration = engineDuration }
        pushNowPlaying()
    }

    func engineDidChangePlaybackState(_ engine: PlaybackEngine, isPlaying playing: Bool) {
        guard engine === activeEngine else { return }
        isPlaying = playing
        if playing {
            isLoading = false
            // Something played, so the backend is healthy again.
            consecutiveFailures = 0
        }
        pushNowPlaying(force: true)
    }
}

private extension PlaybackRequest {
    /// A resolved stream URL can expire; an embed request never does.
    var isStale: Bool {
        switch self {
        case .streamURL(let asset): return asset.isExpired
        case .youTubeVideo: return false
        }
    }
}
