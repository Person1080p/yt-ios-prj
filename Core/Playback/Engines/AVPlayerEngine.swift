import AVFoundation
import Combine
import Foundation

/// Plays HTTP streams and local files. The engine for every source that can
/// resolve a track to a URL.
@MainActor
final class AVPlayerEngine: NSObject, PlaybackEngine {

    weak var delegate: PlaybackEngineDelegate?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: AnyCancellable?

    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        observe()
    }

    func canHandle(_ request: PlaybackRequest) -> Bool {
        if case .streamURL = request { return true }
        return false
    }

    func load(_ request: PlaybackRequest, autoPlay: Bool) {
        guard case .streamURL(let asset) = request else {
            delegate?.engineDidFail(self, error: PlaybackEngineError.unsupportedRequest)
            return
        }

        elapsed = 0
        duration = nil

        let options: [String: Any] = asset.headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": asset.headers]

        let urlAsset = AVURLAsset(url: asset.url, options: options)
        let item = AVPlayerItem(asset: urlAsset)
        // A modest forward buffer keeps playback smooth over cellular without
        // pulling the whole file up front.
        item.preferredForwardBufferDuration = 10

        player.replaceCurrentItem(with: item)
        observeItem(item)

        if autoPlay { play() }
    }

    func play() {
        AudioSessionManager.shared.activate()
        player.play()
        delegate?.engineDidChangePlaybackState(self, isPlaying: true)
    }

    func pause() {
        player.pause()
        delegate?.engineDidChangePlaybackState(self, isPlaying: false)
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = max(0, time)
                self.delegate?.engineDidUpdateTime(self)
            }
        }
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        elapsed = 0
        duration = nil
    }

    // MARK: - Observation

    private func observe() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                self.delegate?.engineDidUpdateTime(self)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Guard against a stale item's notification arriving late.
                guard (notification.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.delegate?.engineDidReachEnd(self)
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        statusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    self.delegate?.engineDidBecomeReady(self)
                case .failed:
                    let error = item.error ?? MusicSourceError.malformedResponse("playback failed")
                    self.delegate?.engineDidFail(self, error: error)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}
