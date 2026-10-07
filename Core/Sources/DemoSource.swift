import Foundation

/// Offline catalogue so the app is fully usable on a fresh install and in the
/// simulator, before any backend is configured.
///
/// Streams are the SoundHelix algorithmic-music demos — a long-standing public
/// demo host, royalty-free, and stable enough to hard-code. Durations are left
/// `nil` deliberately: `AVPlayer` reports the real value once the asset loads,
/// so there is nothing here to go stale.
final class DemoSource: MusicSource, @unchecked Sendable {

    let identifier = "demo"
    let displayName = "Demo Catalogue"
    var isConfigured: Bool { true }

    private static let albums = [
        "Generative I": [1, 2, 3],
        "Generative II": [4, 5, 6],
        "Generative III": [7, 8]
    ]

    private var allTracks: [Track] {
        Self.albums
            .sorted { $0.key < $1.key }
            .flatMap { album, numbers in
                numbers.map { number in
                    Track(
                        id: "demo-\(number)",
                        title: "Song \(number)",
                        artist: "SoundHelix",
                        album: album,
                        duration: nil,
                        artworkURL: nil,
                        sourceToken: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-\(number).mp3"
                    )
                }
            }
    }

    func homeFeed() async throws -> [Shelf] {
        let tracks = allTracks
        return [
            Shelf(id: "quick", title: "Quick picks", subtitle: "Demo catalogue",
                  style: .quickPicks, items: tracks.map { .track($0) }),
            Shelf(id: "albums", title: "Albums", subtitle: nil, style: .cards,
                  items: Self.albums.keys.sorted().map { name in
                      .container(Container(id: "alb:\(name)", kind: .album, title: name,
                                           subtitle: "SoundHelix", artworkURL: nil,
                                           trackCount: Self.albums[name]?.count))
                  })
        ]
    }

    func search(_ query: String) async throws -> SearchResults {
        let needle = query.lowercased()
        return SearchResults(tracks: allTracks.filter {
            $0.title.lowercased().contains(needle)
                || $0.artist.lowercased().contains(needle)
                || ($0.album ?? "").lowercased().contains(needle)
        })
    }

    func tracks(in container: Container) async throws -> [Track] {
        let name = String(container.id.dropFirst("alb:".count))
        return allTracks.filter { $0.album == name }
    }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        guard let token = track.sourceToken, let url = URL(string: token) else {
            throw MusicSourceError.malformedResponse("missing stream URL for \(track.id)")
        }
        return .streamURL(StreamAsset(url: url))
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        allTracks.filter { !knownIDs.contains($0.id) }.shuffled()
    }
}
