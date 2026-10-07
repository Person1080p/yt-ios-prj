import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Metadata from the official YouTube Data API v3; playback through the
/// embedded IFrame player (`YouTubeEmbedEngine`).
///
/// Read this before relying on it:
///
/// - **Ads still play.** The embed serves whatever YouTube serves. Sign in with
///   a Premium account in Settings for ad-free playback.
/// - **Background and audio-only playback violate the YouTube API Services
///   Terms**, so this source cannot ship on the App Store. It is for a personal,
///   self-signed build.
/// - **Quota.** A Data API project gets 10,000 units/day by default. A search
///   costs 100 units, so roughly 100 searches a day. Trending and playlist
///   reads cost 1 unit each, which is why the homepage is built from those.
/// - **No personalised feed.** The API exposes none without OAuth, and
///   `relatedToVideoId` was removed in August 2023, so there is no "related
///   videos" call either. The homepage is the trending music chart plus
///   playlists you name, and continuation searches the current track's channel.
final class YouTubeSource: MusicSource, @unchecked Sendable {

    let identifier = "youtube"
    let displayName = "YouTube"

    private let configuration: YouTubeConfiguration
    private let session: URLSession
    private let decoder = JSONDecoder()

    private let base = URL(string: "https://www.googleapis.com/youtube/v3/")!
    /// Category 10 is Music.
    private let musicCategoryID = "10"

    init(configuration: YouTubeConfiguration = .shared) {
        self.configuration = configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    var isConfigured: Bool { configuration.apiKey != nil }

    // MARK: - Requests

    private func url(_ path: String, _ params: [String: String]) throws -> URL {
        guard let apiKey = configuration.apiKey else {
            throw MusicSourceError.notConfigured("Add a YouTube Data API key in Settings.")
        }
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        var query = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        query.append(URLQueryItem(name: "key", value: apiKey))
        components?.queryItems = query

        guard let url = components?.url else {
            throw MusicSourceError.malformedResponse("could not build URL for \(path)")
        }
        return url
    }

    private func get<T: Decodable>(_ path: String, _ params: [String: String], as: T.Type) async throws -> T {
        let (data, response) = try await session.data(from: try url(path, params))

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The API reports quota exhaustion as 403; worth naming explicitly
            // because it is the failure users will actually hit.
            let apiError = try? decoder.decode(YouTubeErrorEnvelope.self, from: data)
            let message = http.statusCode == 403
                ? (apiError?.error.message ?? "Quota exceeded or the API key is not authorised.")
                : apiError?.error.message
            throw MusicSourceError.server(status: http.statusCode, message: message)
        }

        return try decoder.decode(T.self, from: data)
    }

    // MARK: - MusicSource

    func homeFeed() async throws -> [Shelf] {
        var shelves: [Shelf] = []

        // Trending costs 1 unit, so it leads.
        if let trending = try? await trendingTracks(), !trending.isEmpty {
            shelves.append(Shelf(id: "yt.trending", title: "Trending music",
                                 subtitle: configuration.regionCode,
                                 style: .quickPicks, items: trending.map { .track($0) }))
        }

        // Each saved playlist becomes a shelf; 1 unit apiece.
        for id in configuration.playlistIDs {
            guard let playlist = try? await playlistShelf(id: id) else { continue }
            shelves.append(playlist)
        }

        guard !shelves.isEmpty else {
            throw MusicSourceError.malformedResponse(
                "Nothing loaded. Check the API key, and add a playlist in Settings."
            )
        }
        return shelves
    }

    private func trendingTracks() async throws -> [Track] {
        let response = try await get("videos", [
            "part": "snippet,contentDetails",
            "chart": "mostPopular",
            "videoCategoryId": musicCategoryID,
            "regionCode": configuration.regionCode,
            "maxResults": "25"
        ], as: VideoListResponse.self)

        return response.items.compactMap { $0.asTrack() }
    }

    private func playlistShelf(id: String) async throws -> Shelf {
        let details = try? await get("playlists", [
            "part": "snippet",
            "id": id,
            "maxResults": "1"
        ], as: PlaylistListResponse.self)

        let title = details?.items.first?.snippet.title ?? "Playlist"
        let tracks = try await playlistTracks(id: id)

        return Shelf(id: "yt.playlist.\(id)", title: title, subtitle: nil,
                     style: .quickPicks, items: tracks.map { .track($0) })
    }

    private func playlistTracks(id: String) async throws -> [Track] {
        let response = try await get("playlistItems", [
            "part": "snippet,contentDetails",
            "playlistId": id,
            "maxResults": "50"
        ], as: PlaylistItemListResponse.self)

        return response.items.compactMap { $0.asTrack() }
    }

    func search(_ query: String) async throws -> SearchResults {
        // 100 quota units per call — the debounce in SearchView matters here.
        let response = try await get("search", [
            "part": "snippet",
            "q": query,
            "type": "video",
            "videoCategoryId": musicCategoryID,
            "maxResults": "25"
        ], as: SearchListResponse.self)

        return SearchResults(tracks: response.items.compactMap { $0.asTrack() })
    }

    func tracks(in container: Container) async throws -> [Track] {
        switch container.kind {
        case .playlist, .mix, .album:
            return try await playlistTracks(id: container.id)
        case .artist:
            // "Artist" here is a channel.
            let response = try await get("search", [
                "part": "snippet",
                "channelId": container.id,
                "type": "video",
                "order": "viewCount",
                "maxResults": "25"
            ], as: SearchListResponse.self)
            return response.items.compactMap { $0.asTrack() }
        }
    }

    /// The video ID is the track ID, so there is nothing to resolve.
    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        .youTubeVideo(id: track.id)
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        // `relatedToVideoId` was removed from the API in August 2023, so the
        // nearest available thing is more from the same channel.
        guard let channelID = track.sourceToken else { return [] }

        let response = try await get("search", [
            "part": "snippet",
            "channelId": channelID,
            "type": "video",
            "order": "relevance",
            "maxResults": "25"
        ], as: SearchListResponse.self)

        return response.items
            .compactMap { $0.asTrack() }
            .filter { !knownIDs.contains($0.id) }
    }
}

// MARK: - Wire format

struct YouTubeErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: Int
        let message: String
    }
    let error: APIError
}

struct YouTubeThumbnails: Decodable {
    struct Thumbnail: Decodable {
        let url: String
    }
    let `default`: Thumbnail?
    let medium: Thumbnail?
    let high: Thumbnail?
    let standard: Thumbnail?
    let maxres: Thumbnail?

    /// Largest available, since the same artwork feeds the CarPlay display.
    var bestURL: URL? {
        let candidate = maxres ?? standard ?? high ?? medium ?? `default`
        return candidate.flatMap { URL(string: $0.url) }
    }
}

struct YouTubeSnippet: Decodable {
    let title: String
    let channelTitle: String?
    let channelId: String?
    let thumbnails: YouTubeThumbnails?
    let resourceId: ResourceID?

    struct ResourceID: Decodable {
        let videoId: String?
    }
}

/// `videos.list`
struct VideoListResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let snippet: YouTubeSnippet
        let contentDetails: ContentDetails?

        struct ContentDetails: Decodable {
            let duration: String?
        }

        func asTrack() -> Track? {
            Track(
                id: id,
                title: snippet.title.cleanedTrackTitle,
                artist: snippet.channelTitle ?? "Unknown",
                album: nil,
                duration: contentDetails?.duration.flatMap(ISO8601Duration.seconds(from:)),
                artworkURL: snippet.thumbnails?.bestURL,
                // Channel ID is what continuation searches on.
                sourceToken: snippet.channelId
            )
        }
    }
    let items: [Item]
}

/// `search.list`
struct SearchListResponse: Decodable {
    struct Item: Decodable {
        struct ID: Decodable {
            let videoId: String?
        }
        let id: ID
        let snippet: YouTubeSnippet

        func asTrack() -> Track? {
            guard let videoID = id.videoId else { return nil }
            return Track(
                id: videoID,
                title: snippet.title.cleanedTrackTitle,
                artist: snippet.channelTitle ?? "Unknown",
                album: nil,
                // search.list does not return durations; the player reports it.
                duration: nil,
                artworkURL: snippet.thumbnails?.bestURL,
                sourceToken: snippet.channelId
            )
        }
    }
    let items: [Item]
}

/// `playlistItems.list`
struct PlaylistItemListResponse: Decodable {
    struct Item: Decodable {
        let snippet: YouTubeSnippet
        let contentDetails: ContentDetails?

        struct ContentDetails: Decodable {
            let videoId: String?
        }

        func asTrack() -> Track? {
            guard let videoID = contentDetails?.videoId ?? snippet.resourceId?.videoId else { return nil }
            // Deleted and private entries keep a placeholder title; drop them
            // rather than queueing tracks that cannot play.
            guard !["Deleted video", "Private video"].contains(snippet.title) else { return nil }

            return Track(
                id: videoID,
                title: snippet.title.cleanedTrackTitle,
                artist: snippet.channelTitle ?? "Unknown",
                album: nil,
                duration: nil,
                artworkURL: snippet.thumbnails?.bestURL,
                sourceToken: snippet.channelId
            )
        }
    }
    let items: [Item]
}

/// `playlists.list`
struct PlaylistListResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let snippet: YouTubeSnippet
    }
    let items: [Item]
}

// MARK: - Helpers

enum ISO8601Duration {
    /// Parses the `PT#H#M#S` form `contentDetails.duration` uses.
    static func seconds(from value: String) -> TimeInterval? {
        guard value.hasPrefix("PT") || value.hasPrefix("P") else { return nil }

        var total: TimeInterval = 0
        var number = ""
        var sawTimeMarker = false

        for character in value.dropFirst() {
            switch character {
            case "T":
                sawTimeMarker = true
                number = ""
            case "0"..."9":
                number.append(character)
            case "H":
                total += (Double(number) ?? 0) * 3600
                number = ""
            case "M":
                // Before the T marker, M means months; YouTube never emits that
                // for a video, but guard anyway.
                if sawTimeMarker { total += (Double(number) ?? 0) * 60 }
                number = ""
            case "S":
                total += Double(number) ?? 0
                number = ""
            default:
                number = ""
            }
        }
        return total > 0 ? total : nil
    }
}

extension String {
    /// YouTube titles carry a lot of noise. Strip the most common decorations
    /// so rows stay readable at a glance, which matters more in the car.
    var cleanedTrackTitle: String {
        var result = self
        let patterns = [
            #"\s*[\(\[]\s*(official\s*)?(music\s*)?(video|audio|lyric[s]?(\s*video)?|visualizer|hd|hq|4k)\s*[\)\]]"#,
            #"\s*[\(\[]\s*official\s*[\)\]]"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
