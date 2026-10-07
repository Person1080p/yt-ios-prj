import XCTest
@testable import Aura

/// Covers the pure logic in the YouTube adapter: duration parsing, title
/// cleanup, playlist-ID extraction and response decoding.
final class YouTubeSourceTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - ISO 8601 durations

    func testParsesMinutesAndSeconds() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT4M13S"), 253)
    }

    func testParsesHours() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT1H2M30S"), 3750)
    }

    func testParsesSecondsOnly() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT45S"), 45)
    }

    func testParsesMinutesOnly() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT3M"), 180)
    }

    func testParsesHoursOnly() {
        XCTAssertEqual(ISO8601Duration.seconds(from: "PT2H"), 7200)
    }

    func testZeroDurationIsTreatedAsUnknown() {
        // A live stream reports PT0S; nil keeps the scrubber disabled rather
        // than showing a zero-length track.
        XCTAssertNil(ISO8601Duration.seconds(from: "PT0S"))
    }

    func testRejectsNonDurationStrings() {
        XCTAssertNil(ISO8601Duration.seconds(from: "4:13"))
        XCTAssertNil(ISO8601Duration.seconds(from: ""))
    }

    // MARK: - Title cleanup

    func testStripsOfficialVideoDecoration() {
        XCTAssertEqual("Song Name (Official Video)".cleanedTrackTitle, "Song Name")
        XCTAssertEqual("Song Name [Official Music Video]".cleanedTrackTitle, "Song Name")
        XCTAssertEqual("Song Name (Official Audio)".cleanedTrackTitle, "Song Name")
        XCTAssertEqual("Song Name (Lyrics)".cleanedTrackTitle, "Song Name")
        XCTAssertEqual("Song Name (Lyric Video)".cleanedTrackTitle, "Song Name")
    }

    func testCleanupIsCaseInsensitive() {
        XCTAssertEqual("Song Name (OFFICIAL VIDEO)".cleanedTrackTitle, "Song Name")
        XCTAssertEqual("Song Name (official audio)".cleanedTrackTitle, "Song Name")
    }

    func testCleanupPreservesMeaningfulParentheses() {
        // Removing these would change the actual song name.
        XCTAssertEqual("Song Name (Remix)".cleanedTrackTitle, "Song Name (Remix)")
        XCTAssertEqual("Song (feat. Someone)".cleanedTrackTitle, "Song (feat. Someone)")
        XCTAssertEqual("Song Name (Live at Wembley)".cleanedTrackTitle, "Song Name (Live at Wembley)")
    }

    func testCleanupLeavesPlainTitlesAlone() {
        XCTAssertEqual("Just A Title".cleanedTrackTitle, "Just A Title")
    }

    // MARK: - Playlist IDs

    func testExtractsPlaylistIDFromURL() {
        XCTAssertEqual(
            YouTubeConfiguration.extractPlaylistID("https://www.youtube.com/playlist?list=PL1234abcd"),
            "PL1234abcd"
        )
    }

    func testExtractsPlaylistIDFromWatchURL() {
        XCTAssertEqual(
            YouTubeConfiguration.extractPlaylistID("https://www.youtube.com/watch?v=xyz&list=PLabc"),
            "PLabc"
        )
    }

    func testAcceptsBarePlaylistID() {
        XCTAssertEqual(YouTubeConfiguration.extractPlaylistID("PLbareID"), "PLbareID")
    }

    func testRejectsBlankAndMalformedInput() {
        XCTAssertNil(YouTubeConfiguration.extractPlaylistID("   "))
        XCTAssertNil(YouTubeConfiguration.extractPlaylistID("https://example.com/no/list/here"))
    }

    // MARK: - Decoding

    func testVideoListDecodesWithDuration() throws {
        let json = """
        {"items":[{"id":"vid123","snippet":{"title":"Track (Official Video)",
        "channelTitle":"A Label","channelId":"UC123",
        "thumbnails":{"high":{"url":"https://i.ytimg.com/vi/vid123/hq.jpg"}}},
        "contentDetails":{"duration":"PT3M21S"}}]}
        """
        let track = try XCTUnwrap(decode(json, as: VideoListResponse.self).items.first?.asTrack())

        XCTAssertEqual(track.id, "vid123")
        XCTAssertEqual(track.title, "Track", "decoration should be stripped")
        XCTAssertEqual(track.artist, "A Label")
        XCTAssertEqual(track.duration, 201)
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://i.ytimg.com/vi/vid123/hq.jpg")
        XCTAssertEqual(track.sourceToken, "UC123", "channel ID drives continuation")
    }

    func testThumbnailPicksLargestAvailable() throws {
        let json = """
        {"items":[{"id":"v","snippet":{"title":"T","channelTitle":"C","channelId":"UC",
        "thumbnails":{"default":{"url":"https://x/d.jpg"},"medium":{"url":"https://x/m.jpg"},
        "maxres":{"url":"https://x/max.jpg"}}}}]}
        """
        let track = try XCTUnwrap(decode(json, as: VideoListResponse.self).items.first?.asTrack())
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://x/max.jpg")
    }

    func testSearchResultDecodesNestedVideoID() throws {
        let json = """
        {"items":[{"id":{"kind":"youtube#video","videoId":"abc987"},
        "snippet":{"title":"Found Song","channelTitle":"Artist","channelId":"UCx",
        "thumbnails":{"medium":{"url":"https://x/m.jpg"}}}}]}
        """
        let track = try XCTUnwrap(decode(json, as: SearchListResponse.self).items.first?.asTrack())

        XCTAssertEqual(track.id, "abc987")
        XCTAssertNil(track.duration, "search.list returns no duration")
    }

    func testSearchResultSkipsNonVideoKinds() throws {
        // A channel result has no videoId and must not become a track.
        let json = """
        {"items":[{"id":{"kind":"youtube#channel","channelId":"UCy"},
        "snippet":{"title":"A Channel","channelTitle":"A Channel"}}]}
        """
        let items = try decode(json, as: SearchListResponse.self).items
        XCTAssertNil(items.first?.asTrack())
    }

    func testPlaylistItemPrefersContentDetailsVideoID() throws {
        let json = """
        {"items":[{"snippet":{"title":"Song","channelTitle":"Chan","channelId":"UC1",
        "resourceId":{"videoId":"fromResource"},
        "thumbnails":{"high":{"url":"https://x/h.jpg"}}},
        "contentDetails":{"videoId":"fromDetails"}}]}
        """
        let track = try XCTUnwrap(decode(json, as: PlaylistItemListResponse.self).items.first?.asTrack())
        XCTAssertEqual(track.id, "fromDetails")
    }

    func testPlaylistItemFallsBackToResourceID() throws {
        let json = """
        {"items":[{"snippet":{"title":"Song","channelTitle":"Chan","channelId":"UC1",
        "resourceId":{"videoId":"fromResource"}}}]}
        """
        let track = try XCTUnwrap(decode(json, as: PlaylistItemListResponse.self).items.first?.asTrack())
        XCTAssertEqual(track.id, "fromResource")
    }

    func testPlaylistItemDropsDeletedAndPrivateEntries() throws {
        // Both keep a placeholder entry in the playlist but cannot be played.
        let json = """
        {"items":[
        {"snippet":{"title":"Deleted video","resourceId":{"videoId":"a"}}},
        {"snippet":{"title":"Private video","resourceId":{"videoId":"b"}}},
        {"snippet":{"title":"Real Song","channelTitle":"C","resourceId":{"videoId":"c"}}}]}
        """
        let tracks = try decode(json, as: PlaylistItemListResponse.self).items.compactMap { $0.asTrack() }

        XCTAssertEqual(tracks.map(\.id), ["c"])
    }

    func testApiErrorEnvelopeDecodes() throws {
        // What a quota-exceeded response looks like.
        let json = """
        {"error":{"code":403,"message":"The request cannot be completed because you have exceeded your quota.","errors":[{"reason":"quotaExceeded"}]}}
        """
        let envelope = try decode(json, as: YouTubeErrorEnvelope.self)

        XCTAssertEqual(envelope.error.code, 403)
        XCTAssertTrue(envelope.error.message.contains("quota"))
    }

    func testMissingOptionalSnippetFieldsStillDecode() throws {
        let json = """
        {"items":[{"id":"v1","snippet":{"title":"Bare"}}]}
        """
        let track = try XCTUnwrap(decode(json, as: VideoListResponse.self).items.first?.asTrack())

        XCTAssertEqual(track.artist, "Unknown")
        XCTAssertNil(track.artworkURL)
        XCTAssertNil(track.sourceToken)
    }
}
