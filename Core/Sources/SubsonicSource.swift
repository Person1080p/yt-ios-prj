import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module on non-Apple platforms.
import FoundationNetworking
#endif

/// Adapter for the Subsonic API, which Navidrome, Airsonic, Gonic and Jellyfin
/// (via its Subsonic endpoint) all speak. This is the reference backend: it has
/// real stream URLs, real recommendations, and no advertising of any kind.
///
/// Credentials live in `SubsonicCredentials` (Keychain-backed).
final class SubsonicSource: MusicSource, @unchecked Sendable {

    let identifier = "subsonic"
    var displayName: String { "Self-hosted (\(credentials.host?.host() ?? "not set"))" }

    private let credentials: SubsonicCredentials
    private let session: URLSession
    private let decoder = JSONDecoder()

    /// Subsonic protocol version we target, and a client name the server logs.
    private let apiVersion = "1.16.1"
    private let clientName = "aura"

    init(credentials: SubsonicCredentials = .shared) {
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        #if !os(Linux)
        // Get-only in swift-corelibs-foundation.
        config.waitsForConnectivity = true
        #endif
        self.session = URLSession(configuration: config)
    }

    var isConfigured: Bool {
        credentials.host != nil && credentials.username != nil && credentials.password != nil
    }

    // MARK: - Request building

    /// Subsonic auth: send a random salt and the MD5 of password+salt, so the
    /// password itself never goes over the wire. MD5 is what the protocol
    /// mandates here — it is not our choice of hash.
    private func url(_ method: String, _ params: [String: String] = [:]) throws -> URL {
        guard let host = credentials.host,
              let username = credentials.username,
              let password = credentials.password else {
            throw MusicSourceError.notConfigured("Add your server address and login in Settings.")
        }

        let salt = Self.randomSalt()
        let token = MD5.hex(password + salt)

        var components = URLComponents(
            url: host.appendingPathComponent("rest").appendingPathComponent(method),
            resolvingAgainstBaseURL: false
        )

        var query = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        query.append(contentsOf: [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ])
        components?.queryItems = query

        guard let url = components?.url else {
            throw MusicSourceError.malformedResponse("could not build URL for \(method)")
        }
        return url
    }

    private static func randomSalt() -> String {
        // 16 hex chars of entropy is ample and keeps the URL short.
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    private func get<T: Decodable>(_ method: String, _ params: [String: String] = [:], as: T.Type) async throws -> T {
        let (data, response) = try await session.data(from: try url(method, params))

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MusicSourceError.server(status: http.statusCode, message: nil)
        }

        let envelope = try decoder.decode(SubsonicEnvelope<T>.self, from: data)
        if let error = envelope.response.error {
            throw MusicSourceError.server(status: error.code, message: error.message)
        }
        guard let payload = envelope.response.payload else {
            throw MusicSourceError.malformedResponse("empty \(method) response")
        }
        return payload
    }

    // MARK: - Connection test

    /// Used by Settings to validate credentials before saving.
    func ping() async throws {
        _ = try await session.data(from: try url("ping"))
    }

    // MARK: - MusicSource

    func homeFeed() async throws -> [Shelf] {
        // Fetch the shelves concurrently; the home screen is the one place where
        // serial requests would be plainly visible as lag.
        async let recent    = albumList(type: "recent", size: 20)
        async let frequent  = albumList(type: "frequent", size: 20)
        async let newest    = albumList(type: "newest", size: 20)
        async let random    = randomSongs(size: 24)
        async let starred   = starredTracks()

        var shelves: [Shelf] = []

        // Mirrors YouTube Music's layout: a track grid first, then card rows.
        if let picks = try? await random, !picks.isEmpty {
            shelves.append(Shelf(id: "quick", title: "Quick picks", subtitle: nil,
                                 style: .quickPicks, items: picks.map { .track($0) }))
        }
        if let items = try? await recent, !items.isEmpty {
            shelves.append(Shelf(id: "recent", title: "Listen again", subtitle: nil,
                                 style: .cards, items: items.map { .container($0) }))
        }
        if let items = try? await starred, !items.isEmpty {
            shelves.append(Shelf(id: "starred", title: "Your favourites", subtitle: nil,
                                 style: .quickPicks, items: items.map { .track($0) }))
        }
        if let items = try? await frequent, !items.isEmpty {
            shelves.append(Shelf(id: "frequent", title: "On repeat", subtitle: nil,
                                 style: .cards, items: items.map { .container($0) }))
        }
        if let items = try? await newest, !items.isEmpty {
            shelves.append(Shelf(id: "newest", title: "Recently added", subtitle: nil,
                                 style: .cards, items: items.map { .container($0) }))
        }

        guard !shelves.isEmpty else {
            throw MusicSourceError.malformedResponse("the server returned no content")
        }
        return shelves
    }

    private func albumList(type: String, size: Int) async throws -> [Container] {
        let result = try await get("getAlbumList2",
                                   ["type": type, "size": String(size)],
                                   as: AlbumList2.self)
        return (result.album ?? []).map { $0.asContainer(artworkURL: coverArtURL(for: $0.coverArt)) }
    }

    private func randomSongs(size: Int) async throws -> [Track] {
        let result = try await get("getRandomSongs", ["size": String(size)], as: RandomSongs.self)
        return (result.song ?? []).map(convert)
    }

    private func starredTracks() async throws -> [Track] {
        let result = try await get("getStarred2", as: Starred2.self)
        return (result.song ?? []).prefix(24).map(convert)
    }

    func search(_ query: String) async throws -> SearchResults {
        let result = try await get("search3",
                                   ["query": query, "songCount": "40", "albumCount": "20", "artistCount": "20"],
                                   as: SearchResult3.self)
        return SearchResults(
            tracks: (result.song ?? []).map(convert),
            albums: (result.album ?? []).map { $0.asContainer(artworkURL: coverArtURL(for: $0.coverArt)) },
            artists: (result.artist ?? []).map {
                Container(id: $0.id, kind: .artist, title: $0.name, subtitle: nil,
                          artworkURL: coverArtURL(for: $0.coverArt), trackCount: nil)
            }
        )
    }

    func tracks(in container: Container) async throws -> [Track] {
        switch container.kind {
        case .album:
            let result = try await get("getAlbum", ["id": container.id], as: AlbumDetail.self)
            return (result.song ?? []).map(convert)

        case .playlist:
            let result = try await get("getPlaylist", ["id": container.id], as: PlaylistDetail.self)
            return (result.entry ?? []).map(convert)

        case .artist, .mix:
            // Artists expand to their albums' tracks, in album order.
            let detail = try await get("getArtist", ["id": container.id], as: ArtistDetail.self)
            var all: [Track] = []
            for album in (detail.album ?? []) {
                let albumDetail = try await get("getAlbum", ["id": album.id], as: AlbumDetail.self)
                all.append(contentsOf: (albumDetail.song ?? []).map(convert))
            }
            return all
        }
    }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        // Ask the server to transcode to a consistent format. Raw `stream` also
        // works, but pinning the container keeps AVPlayer from choking on FLAC.
        let url = try url("stream", [
            "id": track.id,
            "format": "mp3",
            "maxBitRate": "320",
            "estimateContentLength": "true"
        ])
        return .streamURL(StreamAsset(url: url))
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        // getSimilarSongs2 is what gives the endless-radio feel. Fall back to
        // random songs on servers that don't implement it.
        if let similar = try? await get("getSimilarSongs2",
                                        ["id": track.id, "count": "30"],
                                        as: SimilarSongs2.self),
           let songs = similar.song, !songs.isEmpty {
            return songs.map(convert).filter { !knownIDs.contains($0.id) }
        }
        return (try await randomSongs(size: 30)).filter { !knownIDs.contains($0.id) }
    }

    // MARK: - Conversion

    private func convert(_ song: SubsonicSong) -> Track {
        Track(
            id: song.id,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            album: song.album,
            duration: song.duration.map(TimeInterval.init),
            artworkURL: coverArtURL(for: song.coverArt),
            sourceToken: nil
        )
    }

    private func coverArtURL(for coverArt: String?) -> URL? {
        guard let coverArt else { return nil }
        return try? url("getCoverArt", ["id": coverArt, "size": "512"])
    }
}

// MARK: - Wire format

/// Subsonic wraps every response in `subsonic-response`, and uses a different
/// payload key per method, so the envelope is generic over the payload and each
/// concrete type declares its own key.
struct SubsonicEnvelope<T: Decodable>: Decodable {
    struct Response: Decodable {
        struct APIError: Decodable {
            let code: Int
            let message: String?
        }
        let error: APIError?
        let payload: T?

        private enum CodingKeys: String, CodingKey {
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decodeIfPresent(APIError.self, forKey: .error)
            // Payload types know their own key; decode from the same container.
            payload = try? T(from: decoder)
        }
    }

    let response: Response

    private enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct SubsonicSong: Decodable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
}

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let artist: String?
    let songCount: Int?
    let coverArt: String?

    func asContainer(artworkURL: URL?) -> Container {
        Container(id: id, kind: .album, title: name, subtitle: artist,
                  artworkURL: artworkURL, trackCount: songCount)
    }
}

struct SubsonicArtist: Decodable {
    let id: String
    let name: String
    let coverArt: String?
}

struct AlbumList2: Decodable {
    let album: [SubsonicAlbum]?
    private enum Outer: String, CodingKey { case albumList2 }
    private enum Inner: String, CodingKey { case album }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .albumList2)
        album = try inner.decodeIfPresent([SubsonicAlbum].self, forKey: .album)
    }
}

struct RandomSongs: Decodable {
    let song: [SubsonicSong]?
    private enum Outer: String, CodingKey { case randomSongs }
    private enum Inner: String, CodingKey { case song }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .randomSongs)
        song = try inner.decodeIfPresent([SubsonicSong].self, forKey: .song)
    }
}

struct Starred2: Decodable {
    let song: [SubsonicSong]?
    private enum Outer: String, CodingKey { case starred2 }
    private enum Inner: String, CodingKey { case song }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .starred2)
        song = try inner.decodeIfPresent([SubsonicSong].self, forKey: .song)
    }
}

struct SimilarSongs2: Decodable {
    let song: [SubsonicSong]?
    private enum Outer: String, CodingKey { case similarSongs2 }
    private enum Inner: String, CodingKey { case song }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .similarSongs2)
        song = try inner.decodeIfPresent([SubsonicSong].self, forKey: .song)
    }
}

struct SearchResult3: Decodable {
    let song: [SubsonicSong]?
    let album: [SubsonicAlbum]?
    let artist: [SubsonicArtist]?
    private enum Outer: String, CodingKey { case searchResult3 }
    private enum Inner: String, CodingKey { case song, album, artist }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .searchResult3)
        song = try inner.decodeIfPresent([SubsonicSong].self, forKey: .song)
        album = try inner.decodeIfPresent([SubsonicAlbum].self, forKey: .album)
        artist = try inner.decodeIfPresent([SubsonicArtist].self, forKey: .artist)
    }
}

struct AlbumDetail: Decodable {
    let song: [SubsonicSong]?
    private enum Outer: String, CodingKey { case album }
    private enum Inner: String, CodingKey { case song }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .album)
        song = try inner.decodeIfPresent([SubsonicSong].self, forKey: .song)
    }
}

struct PlaylistDetail: Decodable {
    let entry: [SubsonicSong]?
    private enum Outer: String, CodingKey { case playlist }
    private enum Inner: String, CodingKey { case entry }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .playlist)
        entry = try inner.decodeIfPresent([SubsonicSong].self, forKey: .entry)
    }
}

struct ArtistDetail: Decodable {
    let album: [SubsonicAlbum]?
    private enum Outer: String, CodingKey { case artist }
    private enum Inner: String, CodingKey { case album }
    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .artist)
        album = try inner.decodeIfPresent([SubsonicAlbum].self, forKey: .album)
    }
}
