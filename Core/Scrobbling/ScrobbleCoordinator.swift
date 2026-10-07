import Combine
import Foundation
#if canImport(os)
import os
#endif

/// Watches playback and submits plays to every enabled scrobbler.
///
/// Deliberately thin: all the "did this count as a play" logic lives in
/// `ScrobbleTracker`, which is pure and tested. This layer only observes
/// `PlayerController`, so the player needs no knowledge that scrobbling exists.
@MainActor
final class ScrobbleCoordinator: ObservableObject {

    @Published private(set) var scrobblers: [AudioScrobblerService] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?
    /// Nudged on each submission so views can refresh counts.
    @Published private(set) var lastSubmission: Date?

    private var tracker = ScrobbleTracker()
    private let queue: ScrobbleQueue
    private var cancellables = Set<AnyCancellable>()
    private var flushTask: Task<Void, Never>?

    #if canImport(os)
    private let log = Logger(subsystem: "com.example.aura", category: "scrobble")
    #endif

    init(queue: ScrobbleQueue = ScrobbleQueue()) {
        self.queue = queue
    }

    // MARK: - Configuration

    func setAccounts(_ accounts: [ScrobblerAccount]) {
        scrobblers = accounts
            .filter { $0.isEnabled && $0.sessionKey?.isEmpty == false }
            .map { AudioScrobblerService(account: $0) }
        // Newly added credentials may unblock a backlog.
        Task { await drain() }
    }

    var hasActiveScrobbler: Bool { !scrobblers.isEmpty }

    // MARK: - Observation

    /// Begin following a player. Call once at launch.
    func observe(_ player: PlayerController) {
        cancellables.removeAll()

        // Track changes bound the play sessions.
        player.$queue
            .map { queue -> (Track, Bool)? in
                guard let entry = queue.current else { return nil }
                return (entry.track, entry.origin != .autoplay)
            }
            .removeDuplicates { $0?.0.id == $1?.0.id }
            .sink { [weak self] value in
                guard let self else { return }
                guard let (track, chosenByUser) = value else {
                    self.handleStop()
                    return
                }
                self.handleTrackChange(to: track, chosenByUser: chosenByUser)
            }
            .store(in: &cancellables)

        // Position drives accumulation; the player already publishes it twice
        // a second, which is ample.
        player.$elapsed
            .sink { [weak self] elapsed in
                guard let self else { return }
                self.handleProgress(elapsed: elapsed, isPlaying: player.isPlaying)
            }
            .store(in: &cancellables)

        Task { await refreshPendingCount() }
    }

    // MARK: - Events

    private func handleTrackChange(to track: Track, chosenByUser: Bool) {
        if let completed = tracker.begin(track: track, at: Date(), chosenByUser: chosenByUser) {
            submit(completed)
        }
        announceNowPlaying()
    }

    private func handleProgress(elapsed: TimeInterval, isPlaying: Bool) {
        if let replay = tracker.update(elapsed: elapsed, isPlaying: isPlaying, now: Date()) {
            // A repeat or a seek back to the top counts as a second play.
            submit(replay)
            announceNowPlaying()
        }
    }

    private func handleStop() {
        if let completed = tracker.flush() {
            submit(completed)
        }
    }

    /// Flush whatever is in progress — on backgrounding, or at termination.
    func flushNow() {
        handleStop()
        Task { await drain() }
    }

    private func announceNowPlaying() {
        guard hasActiveScrobbler, tracker.needsAnnouncement else { return }
        guard let update = tracker.announcement else { return }
        tracker.markAnnounced()

        // Best-effort: a failed announcement is not worth retrying, because by
        // the time a retry landed the track would have moved on.
        for scrobbler in scrobblers {
            Task {
                do {
                    try await scrobbler.updateNowPlaying(update)
                } catch {
                    #if canImport(os)
                    self.log.debug("Now-playing update failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    // MARK: - Submission

    private func submit(_ scrobble: Scrobble) {
        Task {
            // Always queue first, then drain. That way a crash or a dead
            // network between the two loses nothing.
            await queue.enqueue(scrobble)
            await refreshPendingCount()
            await drain()
        }
    }

    /// Send as much of the backlog as the services will take.
    func drain() async {
        guard hasActiveScrobbler else { return }

        // One drain at a time, or a burst of track changes would submit
        // overlapping batches and double-count.
        if let flushTask {
            await flushTask.value
            return
        }

        let task = Task { await performDrain() }
        flushTask = task
        await task.value
        flushTask = nil
    }

    private func performDrain() async {
        var batch = await queue.nextBatch()
        guard !batch.isEmpty else { return }

        while !batch.isEmpty {
            let ids = batch.map(\.id)
            var allSucceeded = true

            for scrobbler in scrobblers {
                do {
                    _ = try await scrobbler.scrobble(batch)
                } catch let error as ScrobbleError {
                    allSucceeded = false
                    lastError = error.localizedDescription

                    if error.isRetryable {
                        // Keep the batch and stop; try again on the next play.
                        await queue.recordFailure(ids: ids)
                        await refreshPendingCount()
                        return
                    }

                    if error == .sessionExpired {
                        // Credentials are dead — stop pestering the service.
                        scrobblers.removeAll { $0.identifier == scrobbler.identifier }
                        await queue.recordFailure(ids: ids)
                        await refreshPendingCount()
                        return
                    }

                    let abandoned = await queue.recordFailure(ids: ids)
                    if !abandoned.isEmpty {
                        lastError = "Gave up on \(abandoned.count) play(s) after repeated failures."
                    }
                    await refreshPendingCount()
                    return
                } catch {
                    allSucceeded = false
                    lastError = error.localizedDescription
                    await queue.recordFailure(ids: ids)
                    await refreshPendingCount()
                    return
                }
            }

            if allSucceeded {
                await queue.remove(ids: ids)
                lastError = nil
                lastSubmission = Date()
            }

            await refreshPendingCount()
            batch = await queue.nextBatch()
        }
    }

    private func refreshPendingCount() async {
        pendingCount = await queue.count
    }

    // MARK: - Diagnostics

    /// Progress toward the current play qualifying, for the UI.
    var currentPlayProgress: (played: TimeInterval, remaining: TimeInterval?)? {
        guard tracker.session != nil else { return nil }
        return (tracker.playedTime, tracker.remainingToQualify)
    }

    func clearQueue() async {
        await queue.removeAll()
        await refreshPendingCount()
    }
}
