import XCTest
@testable import Aura

/// A stub backend that serves a fixed catalogue and counts the calls it gets,
/// so the tests can assert on caching and quota-saving behaviour.
private final class FakeSource: MusicSource, @unchecked Sendable {

    let identifier: String
    var displayName: String { identifier }
    var isConfigured = true

    var tracks: [Track] = []
    var shelves: [Shelf] = []
    var containerTracks: [String: [Track]] = [:]
    var continuationTracks: [Track] = []

    /// Call counters.
    var searchCount = 0
    var homeFeedCount = 0
    private(set) var searchQueries: [String] = []

    init(identifier: String) {
        self.identifier = identifier
    }

    func homeFeed() async throws -> [Shelf] {
        homeFeedCount += 1
        return shelves
    }

    func search(_ query: String) async throws -> SearchResults {
        searchCount += 1
        searchQueries.append(query)
        // Match on any shared token, leaving the scoring to TrackMatcher.
        let wanted = Set(query.split(separator: " ").map(String.init))
        let hits = tracks.filter { track in
            let haystack = Set(
                TrackMatcher.normalize("\(track.title) \(track.artist)")
                    .split(separator: " ").map(String.init)
            )
            return !haystack.intersection(wanted).isEmpty
        }
        return SearchResults(tracks: hits)
    }

    func tracks(in container: Container) async throws -> [Track] {
        containerTracks[container.id] ?? []
    }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        .streamURL(StreamAsset(url: URL(string: "https://\(identifier)/\(track.id)")!))
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        continuationTracks.filter { !knownIDs.contains($0.id) }
    }
}

final class MatchingSourceTests: XCTestCase {

    private var discovery: FakeSource!
    private var playback: FakeSource!

    override func setUp() {
        super.setUp()
        discovery = FakeSource(identifier: "discovery")
        playback = FakeSource(identifier: "playback")
    }

    /// The same recording as each backend describes it.
    private func youTubeStyle(_ title: String, _ channel: String, id: String) -> Track {
        Track(id: id, title: title, artist: channel)
    }

    private func libraryStyle(_ title: String, _ artist: String, id: String) -> Track {
        Track(id: id, title: title, artist: artist)
    }

    private func makeSource(
        fallback: MatchingSource.Fallback = .hideUnmatched
    ) -> MatchingSource {
        MatchingSource(discovery: discovery, playback: playback, fallback: fallback)
    }

    // MARK: - Matching through the home feed

    func testMatchedTrackIsReplacedByTheLibraryEntry() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "Trending", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Sinnerman (Official Audio)", "Nina Simone - Topic", id: "yt1"))])
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        let shelves = try await makeSource().homeFeed()
        let items = try XCTUnwrap(shelves.first?.items)

        guard case .track(let track) = try XCTUnwrap(items.first) else {
            return XCTFail("expected a track")
        }
        // The library's own metadata wins, since that is what actually plays.
        XCTAssertEqual(track.title, "Sinnerman")
        XCTAssertEqual(track.id, "p:lib1")
    }

    func testUnmatchedTrackIsHiddenByDefault() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "Trending", subtitle: nil, style: .quickPicks,
                  items: [
                    .track(youTubeStyle("Sinnerman", "Nina Simone - Topic", id: "yt1")),
                    .track(youTubeStyle("Not In My Library", "Someone Else", id: "yt2"))
                  ])
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        let shelves = try await makeSource().homeFeed()
        XCTAssertEqual(shelves.first?.items.count, 1)
    }

    func testUnmatchedTrackFallsThroughWhenConfigured() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "Trending", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Not In My Library", "Someone Else", id: "yt2"))])
        ]
        playback.tracks = []

        let shelves = try await makeSource(fallback: .useDiscovery).homeFeed()
        guard case .track(let track) = try XCTUnwrap(shelves.first?.items.first) else {
            return XCTFail("expected a track")
        }
        XCTAssertEqual(track.id, "d:yt2", "should stay tagged to the discovery backend")
    }

    func testShelfWithNoMatchesIsDroppedEntirely() async throws {
        discovery.shelves = [
            Shelf(id: "keep", title: "Keep", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Sinnerman", "Nina Simone", id: "yt1"))]),
            Shelf(id: "drop", title: "Drop", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Unknown Song", "Nobody", id: "yt9"))])
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        let shelves = try await makeSource().homeFeed()
        XCTAssertEqual(shelves.map(\.id), ["keep"])
    }

    func testHomeFeedThrowsWhenNothingMatches() async {
        discovery.shelves = [
            Shelf(id: "s", title: "T", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Unknown Song", "Nobody", id: "yt9"))])
        ]
        playback.tracks = []

        do {
            _ = try await makeSource().homeFeed()
            XCTFail("expected an error")
        } catch {
            // The message should point at the fallback setting.
            XCTAssertTrue(error.localizedDescription.contains("Stream the rest"))
        }
    }

    func testShelfOrderIsPreserved() async throws {
        let wanted = (1...4).map { youTubeStyle("Song \($0)", "Artist", id: "yt\($0)") }
        discovery.shelves = [
            Shelf(id: "s", title: "T", subtitle: nil, style: .quickPicks, items: wanted.map { .track($0) })
        ]
        playback.tracks = (1...4).map { libraryStyle("Song \($0)", "Artist", id: "lib\($0)") }

        let shelves = try await makeSource().homeFeed()
        let ids = shelves.first?.items.map(\.id)

        // Concurrent matching must not reorder the shelf.
        XCTAssertEqual(ids, ["t:p:lib1", "t:p:lib2", "t:p:lib3", "t:p:lib4"])
    }

    // MARK: - Namespacing

    func testPlaybackRequestRoutesMatchedTrackToTheLibrary() async throws {
        let source = makeSource()
        let request = try await source.playbackRequest(
            for: Track(id: "p:lib1", title: "T", artist: "A")
        )

        guard case .streamURL(let asset) = request else { return XCTFail("expected a stream URL") }
        XCTAssertEqual(asset.url.absoluteString, "https://playback/lib1",
                       "namespace must be stripped before delegating")
    }

    func testPlaybackRequestRoutesUnmatchedTrackToDiscovery() async throws {
        let source = makeSource(fallback: .useDiscovery)
        let request = try await source.playbackRequest(
            for: Track(id: "d:yt2", title: "T", artist: "A")
        )

        guard case .streamURL(let asset) = request else { return XCTFail("expected a stream URL") }
        XCTAssertEqual(asset.url.absoluteString, "https://discovery/yt2")
    }

    func testPlaybackRequestRejectsAnUnnamespacedTrack() async {
        let source = makeSource()
        do {
            _ = try await source.playbackRequest(for: Track(id: "bare", title: "T", artist: "A"))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unrecognised"))
        }
    }

    // MARK: - Containers

    func testLibraryContainerTracksArePassedThroughTagged() async throws {
        playback.containerTracks["album1"] = [libraryStyle("One", "A", id: "lib1")]

        let container = Container(id: "p:album1", kind: .album, title: "Album")
        let tracks = try await makeSource().tracks(in: container)

        XCTAssertEqual(tracks.map(\.id), ["p:lib1"])
    }

    func testDiscoveryContainerTracksAreMatched() async throws {
        discovery.containerTracks["ytlist"] = [
            youTubeStyle("Sinnerman (Official Video)", "Nina Simone - Topic", id: "yt1")
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        let container = Container(id: "d:ytlist", kind: .playlist, title: "List")
        let tracks = try await makeSource().tracks(in: container)

        XCTAssertEqual(tracks.map(\.id), ["p:lib1"])
    }

    func testContainerShelvesAreTaggedForLaterResolution() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "Albums", subtitle: nil, style: .cards,
                  items: [.container(Container(id: "alb1", kind: .album, title: "Album"))])
        ]

        let shelves = try await makeSource().homeFeed()
        guard case .container(let container) = try XCTUnwrap(shelves.first?.items.first) else {
            return XCTFail("expected a container")
        }
        XCTAssertEqual(container.id, "d:alb1")
    }

    // MARK: - Search

    func testSearchSkipsDiscoveryWhenTheLibraryHasEnoughResults() async throws {
        playback.tracks = (1...6).map { libraryStyle("Song \($0)", "Artist", id: "lib\($0)") }

        _ = try await makeSource().search("song")

        // A YouTube search costs 100 quota units, so it must not run here.
        XCTAssertEqual(discovery.searchCount, 0)
    }

    func testSearchConsultsDiscoveryWhenTheLibraryIsThin() async throws {
        playback.tracks = [libraryStyle("Song 1", "Artist", id: "lib1")]
        discovery.tracks = [youTubeStyle("Song 2", "Artist", id: "yt2")]

        _ = try await makeSource().search("song")

        XCTAssertEqual(discovery.searchCount, 1)
    }

    func testSearchTagsLibraryResults() async throws {
        playback.tracks = (1...6).map { libraryStyle("Song \($0)", "Artist", id: "lib\($0)") }

        let results = try await makeSource().search("song")
        XCTAssertTrue(results.tracks.allSatisfy { $0.id.hasPrefix("p:") })
    }

    // MARK: - Caching

    func testMatchesAreCachedAcrossCalls() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "T", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Sinnerman", "Nina Simone", id: "yt1"))])
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        let source = makeSource()
        _ = try await source.homeFeed()
        let afterFirst = playback.searchCount
        _ = try await source.homeFeed()

        XCTAssertEqual(playback.searchCount, afterFirst,
                       "a second refresh must not re-search the backend")
    }

    func testMissesAreCachedToo() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "T", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Nothing Here", "Nobody", id: "yt9"))])
        ]
        playback.tracks = []

        let source = makeSource(fallback: .useDiscovery)
        _ = try await source.homeFeed()
        let afterFirst = playback.searchCount
        _ = try await source.homeFeed()

        XCTAssertEqual(playback.searchCount, afterFirst,
                       "an absent track must not be re-searched on every refresh")
    }

    func testSearchQuerySentToTheLibraryIsNormalised() async throws {
        discovery.shelves = [
            Shelf(id: "s", title: "T", subtitle: nil, style: .quickPicks,
                  items: [.track(youTubeStyle("Sinnerman (Official Video) [HD]", "Nina Simone - Topic", id: "yt1"))])
        ]
        playback.tracks = [libraryStyle("Sinnerman", "Nina Simone", id: "lib1")]

        _ = try await makeSource().homeFeed()

        XCTAssertEqual(playback.searchQueries, ["sinnerman nina simone"])
    }

    // MARK: - Continuation

    func testContinuationFromALibraryTrackStaysInTheLibrary() async throws {
        playback.continuationTracks = [libraryStyle("Next", "A", id: "lib2")]

        let tracks = try await makeSource().continuation(
            seededBy: Track(id: "p:lib1", title: "T", artist: "A"),
            excluding: ["p:lib1"]
        )
        XCTAssertEqual(tracks.map(\.id), ["p:lib2"])
    }

    func testContinuationExclusionsAreUnnamespaced() async throws {
        // The backend filters on its own IDs, so "p:lib2" must reach it as "lib2".
        playback.continuationTracks = [
            libraryStyle("A", "A", id: "lib2"),
            libraryStyle("B", "B", id: "lib3")
        ]

        let tracks = try await makeSource().continuation(
            seededBy: Track(id: "p:lib1", title: "T", artist: "A"),
            excluding: ["p:lib1", "p:lib2"]
        )
        XCTAssertEqual(tracks.map(\.id), ["p:lib3"])
    }

    func testContinuationFromAnUnnamespacedTrackIsEmpty() async throws {
        let tracks = try await makeSource().continuation(
            seededBy: Track(id: "bare", title: "T", artist: "A"),
            excluding: []
        )
        XCTAssertTrue(tracks.isEmpty)
    }

    // MARK: - Configuration

    func testIsConfiguredRequiresBothBackends() {
        playback.isConfigured = false
        XCTAssertFalse(makeSource().isConfigured)

        playback.isConfigured = true
        XCTAssertTrue(makeSource().isConfigured)
    }
}
