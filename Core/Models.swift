import Foundation

// MARK: - Track

/// A single playable item. `id` is source-scoped, not globally unique across sources.
struct Track: Identifiable, Hashable, Codable, Sendable {
    /// Scoped to its source. `var` so a composing source can namespace it —
    /// see `MatchingSource`.
    var id: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    var artworkURL: URL?

    /// Opaque, source-specific payload the source needs to resolve a stream later.
    /// Kept as a string so `Track` stays `Codable` for queue persistence.
    var sourceToken: String?

    init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        artworkURL: URL? = nil,
        sourceToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.sourceToken = sourceToken
    }
}

// MARK: - Container

/// An album, playlist, artist or auto-generated mix — anything that resolves to a track list.
struct Container: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album, playlist, artist, mix
    }

    /// Scoped to its source; see the note on `Track.id`.
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var trackCount: Int?
}

// MARK: - Home feed

/// One horizontal row on the homepage. The YouTube Music feed is a vertical
/// stack of these, and CarPlay renders the same array as list sections.
struct Shelf: Identifiable, Hashable, Sendable {
    enum Style: String, Sendable {
        /// 2-row grid of individual tracks, tappable to play immediately ("Quick picks").
        case quickPicks
        /// Horizontally scrolling square cards (albums, playlists).
        case cards
        /// Horizontally scrolling circles (artists).
        case circles
    }

    let id: String
    var title: String
    var subtitle: String?
    var style: Style
    var items: [ShelfItem]
}

enum ShelfItem: Identifiable, Hashable, Sendable {
    case track(Track)
    case container(Container)

    var id: String {
        switch self {
        case .track(let t): return "t:\(t.id)"
        case .container(let c): return "c:\(c.id)"
        }
    }

    var title: String {
        switch self {
        case .track(let t): return t.title
        case .container(let c): return c.title
        }
    }

    var subtitle: String? {
        switch self {
        case .track(let t): return t.artist
        case .container(let c): return c.subtitle
        }
    }

    var artworkURL: URL? {
        switch self {
        case .track(let t): return t.artworkURL
        case .container(let c): return c.artworkURL
        }
    }
}

// MARK: - Search

struct SearchResults: Sendable {
    var tracks: [Track] = []
    var albums: [Container] = []
    var artists: [Container] = []
    var playlists: [Container] = []

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }
}

// MARK: - Stream

/// Everything `AVPlayer` needs to start playing one track.
struct StreamAsset: Sendable {
    let url: URL
    /// Applied via `AVURLAssetHTTPHeaderFieldsKey`; use for bearer tokens etc.
    var headers: [String: String] = [:]
    /// When set, the resolved URL must not be reused past this point.
    var expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

// MARK: - Errors

enum MusicSourceError: LocalizedError {
    case notConfigured(String)
    case unsupported(String)
    case server(status: Int, message: String?)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail):
            return "This music source isn't set up yet. \(detail)"
        case .unsupported(let detail):
            return detail
        case .server(let status, let message):
            return message ?? "The server responded with HTTP \(status)."
        case .malformedResponse(let detail):
            return "Unexpected response from the server: \(detail)"
        }
    }
}
