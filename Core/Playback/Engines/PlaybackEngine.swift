import Foundation

/// What a source needs in order to be played.
///
/// Sources that resolve to a file or HTTP stream return `.streamURL` and are
/// played by `AVPlayerEngine`. A source whose player *is* the playback
/// mechanism — YouTube's embedded IFrame player — returns `.youTubeVideo`, and
/// there is no URL to hand to AVPlayer at all.
enum PlaybackRequest: Sendable {
    case streamURL(StreamAsset)
    case youTubeVideo(id: String)

    /// Only URL-backed requests can be resolved ahead of time.
    var isPrefetchable: Bool {
        switch self {
        case .streamURL: return true
        case .youTubeVideo: return false
        }
    }
}

/// Something that can play one `PlaybackRequest` at a time.
///
/// `PlayerController` owns the queue and the now-playing metadata; an engine
/// only has to move audio and report back.
@MainActor
protocol PlaybackEngine: AnyObject {

    var delegate: PlaybackEngineDelegate? { get set }

    /// Current position, in seconds.
    var elapsed: TimeInterval { get }

    /// Known duration, once the engine has discovered it.
    var duration: TimeInterval? { get }

    func canHandle(_ request: PlaybackRequest) -> Bool

    func load(_ request: PlaybackRequest, autoPlay: Bool)

    func play()
    func pause()
    func seek(to time: TimeInterval)

    /// Stop and release resources. Called when switching engines.
    func teardown()
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {

    /// The engine has enough data to play; `duration` may now be available.
    func engineDidBecomeReady(_ engine: PlaybackEngine)

    /// The current item finished on its own.
    func engineDidReachEnd(_ engine: PlaybackEngine)

    func engineDidFail(_ engine: PlaybackEngine, error: Error)

    /// Position moved. Fired often; keep handling cheap.
    func engineDidUpdateTime(_ engine: PlaybackEngine)

    /// Playback started or stopped for any reason, including ones the app did
    /// not initiate (buffering, an ad starting, the engine being interrupted).
    func engineDidChangePlaybackState(_ engine: PlaybackEngine, isPlaying: Bool)
}

enum PlaybackEngineError: LocalizedError {
    case unsupportedRequest
    case embedUnavailable(String)
    case youTubePlayer(code: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedRequest:
            return "This track can't be played by the current playback engine."
        case .embedUnavailable(let detail):
            return detail
        case .youTubePlayer(let code):
            // Codes defined by the IFrame player API.
            switch code {
            case 2: return "YouTube rejected the video ID."
            case 5: return "The HTML5 player could not play this video."
            case 100: return "This video has been removed or made private."
            case 101, 150: return "The owner of this video does not allow it to be played in embedded players."
            default: return "The YouTube player reported error \(code)."
            }
        }
    }
}
