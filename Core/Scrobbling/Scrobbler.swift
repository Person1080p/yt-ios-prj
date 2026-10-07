import Foundation

/// One completed play, ready to submit.
struct Scrobble: Identifiable, Hashable, Codable, Sendable {

    let id: UUID
    var artist: String
    var track: String
    var album: String?
    var albumArtist: String?
    /// When playback **started**, which is what the protocol wants — not when
    /// it finished.
    var startedAt: Date
    var duration: TimeInterval?
    /// False for autoplay/radio picks, per the AudioScrobbler spec.
    var chosenByUser: Bool

    /// Submission attempts so far; used to give up on permanently bad entries.
    var attempts: Int

    init(
        id: UUID = UUID(),
        artist: String,
        track: String,
        album: String? = nil,
        albumArtist: String? = nil,
        startedAt: Date,
        duration: TimeInterval? = nil,
        chosenByUser: Bool = true,
        attempts: Int = 0
    ) {
        self.id = id
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.startedAt = startedAt
        self.duration = duration
        self.chosenByUser = chosenByUser
        self.attempts = attempts
    }
}

/// A "listening now" announcement. Not persisted — it is worthless once stale.
struct NowPlayingUpdate: Hashable, Sendable {
    var artist: String
    var track: String
    var album: String?
    var albumArtist: String?
    var duration: TimeInterval?
}

/// Outcome of a batch submission.
struct ScrobbleResult: Sendable {
    var accepted: Int
    var ignored: Int
    /// Entries the service rejected permanently; drop them rather than retry.
    var rejectedIDs: [Scrobble.ID]

    static let empty = ScrobbleResult(accepted: 0, ignored: 0, rejectedIDs: [])
}

/// A listening-history service.
///
/// Last.fm, Libre.fm and self-hosted GNU FM instances all speak the same
/// AudioScrobbler 2.0 API, so `AudioScrobblerService` covers all three and this
/// protocol exists so several can run at once, or none.
protocol Scrobbler: AnyObject, Sendable {

    var identifier: String { get }
    var displayName: String { get }

    /// False until a session key has been obtained.
    var isAuthenticated: Bool { get }

    /// Best-effort announcement that a track has started. Failures are not
    /// worth retrying — by the time a retry lands the track has moved on.
    func updateNowPlaying(_ update: NowPlayingUpdate) async throws

    /// Submit completed plays. Implementations should accept backdated entries
    /// so an offline queue can be drained later.
    func scrobble(_ plays: [Scrobble]) async throws -> ScrobbleResult
}

enum ScrobbleError: LocalizedError, Equatable {

    case notConfigured
    /// The stored session key is no longer valid; the user must sign in again.
    case sessionExpired
    case rateLimited
    case serviceUnavailable
    case service(code: Int, message: String)
    case transport(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This scrobbler isn't signed in yet."
        case .sessionExpired:
            return "The session expired. Sign in again to keep scrobbling."
        case .rateLimited:
            return "The service is rate limiting us. Plays are queued and will be sent later."
        case .serviceUnavailable:
            return "The service is temporarily unavailable. Plays are queued."
        case .service(let code, let message):
            return "\(message) (error \(code))"
        case .transport(let detail):
            return detail
        case .malformedResponse(let detail):
            return "Unexpected response: \(detail)"
        }
    }

    /// Whether the queue should hold onto the plays and try again.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable, .transport:
            return true
        case .notConfigured, .sessionExpired, .malformedResponse:
            return false
        case .service(let code, _):
            // 11 and 16 are the service's own "try again later" codes.
            return code == 11 || code == 16 || code == 29
        }
    }
}
