import Foundation

/// A content backend. Everything above this protocol — the home feed, the queue,
/// the player, CarPlay — is source-agnostic, so adding a backend means writing
/// one conformance and nothing else.
protocol MusicSource: AnyObject, Sendable {

    /// Stable identifier used to scope persisted queues and caches.
    var identifier: String { get }

    /// Shown in Settings.
    var displayName: String { get }

    /// True once the source has whatever credentials/permissions it needs.
    var isConfigured: Bool { get }

    /// The homepage feed, top to bottom.
    func homeFeed() async throws -> [Shelf]

    func search(_ query: String) async throws -> SearchResults

    /// Expand an album/playlist/artist/mix into its tracks.
    func tracks(in container: Container) async throws -> [Track]

    /// Resolve how to play this track. Called immediately before playback, and
    /// again whenever a previously resolved asset has expired.
    ///
    /// Most sources return `.streamURL`. A source whose player is itself the
    /// playback mechanism returns the matching case instead — see `PlaybackRequest`.
    func playbackRequest(for track: Track) async throws -> PlaybackRequest

    /// Tracks to append to the auto-queue once the explicit queue runs dry —
    /// this is what makes playback continue indefinitely like a YouTube Music radio.
    /// Return `[]` if the source has no notion of similar tracks.
    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track]
}

extension MusicSource {
    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] { [] }
}
