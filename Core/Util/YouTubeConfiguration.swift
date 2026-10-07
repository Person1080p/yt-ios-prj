import Foundation

/// Settings for the YouTube source: a Data API key for metadata, plus the
/// playlists to show on the homepage.
///
/// The Data API offers no personalised feed without OAuth, so the homepage is
/// trending music plus whatever playlists you name here. Playlist reads cost 1
/// quota unit each, which is what makes this affordable — see `YouTubeSource`.
final class YouTubeConfiguration: @unchecked Sendable {

    static let shared = YouTubeConfiguration()

    private let apiKeyKey = "youtube.apiKey"
    private let playlistsKey = "youtube.playlists"
    private let regionKey = "youtube.region"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var apiKey: String? {
        get { defaults.string(forKey: apiKeyKey)?.nilIfBlank }
        set { defaults.set(newValue, forKey: apiKeyKey) }
    }

    /// Playlist IDs shown as homepage shelves, in order.
    var playlistIDs: [String] {
        get { defaults.stringArray(forKey: playlistsKey) ?? [] }
        set { defaults.set(newValue, forKey: playlistsKey) }
    }

    /// Region for the trending chart; defaults to the device's.
    var regionCode: String {
        get {
            defaults.string(forKey: regionKey)?.nilIfBlank
                ?? Locale.current.region?.identifier
                ?? "US"
        }
        set { defaults.set(newValue, forKey: regionKey) }
    }

    func addPlaylist(_ raw: String) {
        guard let id = Self.extractPlaylistID(raw) else { return }
        var ids = playlistIDs
        guard !ids.contains(id) else { return }
        ids.append(id)
        playlistIDs = ids
    }

    func removePlaylist(_ id: String) {
        playlistIDs = playlistIDs.filter { $0 != id }
    }

    func clear() {
        defaults.removeObject(forKey: apiKeyKey)
        defaults.removeObject(forKey: playlistsKey)
        defaults.removeObject(forKey: regionKey)
    }

    /// Accepts a bare ID or a full YouTube URL, since pasting a link is easier
    /// than digging the ID out of it.
    static func extractPlaylistID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let listItem = components.queryItems?.first(where: { $0.name == "list" }),
           let value = listItem.value?.nilIfBlank {
            return value
        }

        // A bare ID: no scheme, no path separators.
        guard !trimmed.contains("/"), !trimmed.contains("?") else { return nil }
        return trimmed
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
