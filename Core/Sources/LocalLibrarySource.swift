import Foundation
import MediaPlayer

/// Plays music already synced to the device via the MediaPlayer framework.
///
/// Requires `NSAppleMusicUsageDescription` and user authorization. Note that
/// Apple Music *streaming* items have no `assetURL` and so cannot be played
/// through `AVPlayer` — only DRM-free local files are playable this way, which
/// is a platform restriction, not a limitation of this adapter.
final class LocalLibrarySource: MusicSource, @unchecked Sendable {

    let identifier = "local"
    let displayName = "On This iPhone"

    var isConfigured: Bool {
        MPMediaLibrary.authorizationStatus() == .authorized
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - MusicSource

    func homeFeed() async throws -> [Shelf] {
        try ensureAuthorized()

        let songs = playableSongs()
        guard !songs.isEmpty else {
            throw MusicSourceError.malformedResponse("no playable songs found on this device")
        }

        var shelves: [Shelf] = [
            Shelf(id: "local.random", title: "Quick picks", subtitle: "From your library",
                  style: .quickPicks, items: songs.shuffled().prefix(24).map { .track(track(from: $0)) })
        ]

        let albums = MPMediaQuery.albums()
        if let collections = albums.collections, !collections.isEmpty {
            shelves.append(Shelf(
                id: "local.albums", title: "Albums", subtitle: nil, style: .cards,
                items: collections.prefix(40).compactMap { collection in
                    guard let item = collection.representativeItem else { return nil }
                    return .container(Container(
                        id: String(item.albumPersistentID),
                        kind: .album,
                        title: item.albumTitle ?? "Unknown Album",
                        subtitle: item.albumArtist ?? item.artist,
                        artworkURL: nil,
                        trackCount: collection.count
                    ))
                }
            ))
        }

        let artists = MPMediaQuery.artists()
        if let collections = artists.collections, !collections.isEmpty {
            shelves.append(Shelf(
                id: "local.artists", title: "Artists", subtitle: nil, style: .circles,
                items: collections.prefix(40).compactMap { collection in
                    guard let item = collection.representativeItem else { return nil }
                    return .container(Container(
                        id: String(item.artistPersistentID),
                        kind: .artist,
                        title: item.artist ?? "Unknown Artist",
                        subtitle: nil,
                        artworkURL: nil,
                        trackCount: collection.count
                    ))
                }
            ))
        }

        return shelves
    }

    func search(_ query: String) async throws -> SearchResults {
        try ensureAuthorized()
        let needle = query.lowercased()
        let matches = playableSongs().filter {
            ($0.title ?? "").lowercased().contains(needle)
                || ($0.artist ?? "").lowercased().contains(needle)
                || ($0.albumTitle ?? "").lowercased().contains(needle)
        }
        return SearchResults(tracks: matches.prefix(60).map(track(from:)))
    }

    func tracks(in container: Container) async throws -> [Track] {
        try ensureAuthorized()
        guard let id = UInt64(container.id) else { return [] }

        let property: String
        switch container.kind {
        case .album: property = MPMediaItemPropertyAlbumPersistentID
        case .artist: property = MPMediaItemPropertyArtistPersistentID
        case .playlist, .mix: property = MPMediaPlaylistPropertyPersistentID
        }

        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: property))
        return (query.items ?? []).filter { $0.assetURL != nil }.map(track(from:))
    }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        guard let token = track.sourceToken, let url = URL(string: token) else {
            throw MusicSourceError.unsupported(
                "“\(track.title)” is an Apple Music streaming item, which iOS does not expose a playable file for."
            )
        }
        return .streamURL(StreamAsset(url: url))
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        // No recommendation engine locally, so keep playing the same artist
        // first and fall back to anything else in the library.
        let all = playableSongs().map(track(from:))
        let sameArtist = all.filter { $0.artist == track.artist && !knownIDs.contains($0.id) }
        if !sameArtist.isEmpty { return sameArtist.shuffled() }
        return all.filter { !knownIDs.contains($0.id) }.shuffled().prefix(30).map { $0 }
    }

    // MARK: - Helpers

    private func ensureAuthorized() throws {
        guard isConfigured else {
            throw MusicSourceError.notConfigured("Allow access to your music library in Settings.")
        }
    }

    /// Only DRM-free items have an `assetURL`, and only those can go through AVPlayer.
    private func playableSongs() -> [MPMediaItem] {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: false, forProperty: MPMediaItemPropertyIsCloudItem
        ))
        return (query.items ?? []).filter { $0.assetURL != nil }
    }

    private func track(from item: MPMediaItem) -> Track {
        Track(
            id: String(item.persistentID),
            title: item.title ?? "Unknown",
            artist: item.artist ?? "Unknown Artist",
            album: item.albumTitle,
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
            artworkURL: nil,
            sourceToken: item.assetURL?.absoluteString
        )
    }
}
