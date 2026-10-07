import XCTest
@testable import Aura

/// The Subsonic wire format nests each payload under `subsonic-response` and
/// then under a per-method key, and reports errors in-band with HTTP 200. Both
/// are easy to get subtly wrong, so they're pinned here against response bodies
/// shaped like the real thing.
final class SubsonicDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> SubsonicEnvelope<T> {
        try JSONDecoder().decode(SubsonicEnvelope<T>.self, from: Data(json.utf8))
    }

    // MARK: - Errors

    func testInBandErrorIsSurfaced() throws {
        // Subsonic reports auth failures with HTTP 200 and an error object, so
        // the status code alone is not enough to detect failure.
        let json = """
        {"subsonic-response":{"status":"failed","version":"1.16.1",
        "error":{"code":40,"message":"Wrong username or password"}}}
        """
        let envelope = try decode(json, as: AlbumList2.self)

        XCTAssertEqual(envelope.response.error?.code, 40)
        XCTAssertEqual(envelope.response.error?.message, "Wrong username or password")
        XCTAssertNil(envelope.response.payload?.album)
    }

    func testSuccessfulResponseHasNoError() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
        "albumList2":{"album":[]}}}
        """
        let envelope = try decode(json, as: AlbumList2.self)

        XCTAssertNil(envelope.response.error)
        XCTAssertEqual(envelope.response.payload?.album?.count, 0)
    }

    // MARK: - Album list

    func testAlbumListDecodesThroughBothNestingLevels() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[
        {"id":"al-1","name":"Kind of Blue","artist":"Miles Davis","songCount":5,
         "duration":2580,"coverArt":"al-1","year":1959},
        {"id":"al-2","name":"Blue Train","artist":"John Coltrane","songCount":6,
         "duration":2200,"coverArt":"al-2"}]}}}
        """
        let albums = try XCTUnwrap(decode(json, as: AlbumList2.self).response.payload?.album)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].id, "al-1")
        XCTAssertEqual(albums[0].name, "Kind of Blue")
        XCTAssertEqual(albums[0].artist, "Miles Davis")
        XCTAssertEqual(albums[0].songCount, 5)
        XCTAssertEqual(albums[1].coverArt, "al-2")
    }

    func testAlbumConvertsToContainer() throws {
        let json = """
        {"subsonic-response":{"albumList2":{"album":[
        {"id":"al-9","name":"Album","artist":"Artist","songCount":3,"coverArt":"c-9"}]}}}
        """
        let album = try XCTUnwrap(decode(json, as: AlbumList2.self).response.payload?.album?.first)
        let container = album.asContainer(artworkURL: URL(string: "https://example.com/art"))

        XCTAssertEqual(container.kind, .album)
        XCTAssertEqual(container.id, "al-9")
        XCTAssertEqual(container.title, "Album")
        XCTAssertEqual(container.subtitle, "Artist")
        XCTAssertEqual(container.trackCount, 3)
    }

    // MARK: - Missing and partial data

    func testMissingArrayDecodesAsNilRatherThanThrowing() throws {
        // An empty library omits the array entirely instead of sending [].
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{}}}
        """
        XCTAssertNil(try decode(json, as: AlbumList2.self).response.payload?.album)
    }

    func testSongWithoutOptionalFieldsStillDecodes() throws {
        // Only id and title are reliably present across servers.
        let json = """
        {"subsonic-response":{"randomSongs":{"song":[{"id":"s-1","title":"Untitled"}]}}}
        """
        let song = try XCTUnwrap(decode(json, as: RandomSongs.self).response.payload?.song?.first)

        XCTAssertEqual(song.id, "s-1")
        XCTAssertEqual(song.title, "Untitled")
        XCTAssertNil(song.artist)
        XCTAssertNil(song.duration)
        XCTAssertNil(song.coverArt)
    }

    // MARK: - Other methods

    func testSearchResultDecodesAllThreeCategories() throws {
        let json = """
        {"subsonic-response":{"status":"ok","searchResult3":{
        "artist":[{"id":"ar-1","name":"Nina Simone","coverArt":"ar-1"}],
        "album":[{"id":"al-1","name":"Pastel Blues","artist":"Nina Simone"}],
        "song":[{"id":"s-1","title":"Sinnerman","artist":"Nina Simone","duration":603}]}}}
        """
        let result = try XCTUnwrap(decode(json, as: SearchResult3.self).response.payload)

        XCTAssertEqual(result.artist?.first?.name, "Nina Simone")
        XCTAssertEqual(result.album?.first?.id, "al-1")
        XCTAssertEqual(result.song?.first?.duration, 603)
    }

    func testAlbumDetailDecodesTrackList() throws {
        let json = """
        {"subsonic-response":{"status":"ok","album":{"id":"al-1","name":"Album","song":[
        {"id":"s-1","title":"One","artist":"A","album":"Album","duration":100,"coverArt":"c"},
        {"id":"s-2","title":"Two","artist":"A","album":"Album","duration":200,"coverArt":"c"}]}}}
        """
        let songs = try XCTUnwrap(decode(json, as: AlbumDetail.self).response.payload?.song)

        XCTAssertEqual(songs.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(songs[1].duration, 200)
    }

    func testPlaylistUsesEntryRatherThanSong() throws {
        // getPlaylist nests its tracks under "entry", unlike every other method.
        let json = """
        {"subsonic-response":{"status":"ok","playlist":{"id":"p-1","name":"Mix","entry":[
        {"id":"s-1","title":"Track","artist":"A"}]}}}
        """
        let entries = try XCTUnwrap(decode(json, as: PlaylistDetail.self).response.payload?.entry)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Track")
    }

    func testSimilarSongsDecodesForContinuation() throws {
        let json = """
        {"subsonic-response":{"status":"ok","similarSongs2":{"song":[
        {"id":"s-7","title":"Similar","artist":"B","duration":180}]}}}
        """
        let songs = try XCTUnwrap(decode(json, as: SimilarSongs2.self).response.payload?.song)

        XCTAssertEqual(songs.first?.id, "s-7")
    }

    func testArtistDetailDecodesAlbums() throws {
        let json = """
        {"subsonic-response":{"status":"ok","artist":{"id":"ar-1","name":"A","album":[
        {"id":"al-1","name":"First","artist":"A"},{"id":"al-2","name":"Second","artist":"A"}]}}}
        """
        let albums = try XCTUnwrap(decode(json, as: ArtistDetail.self).response.payload?.album)

        XCTAssertEqual(albums.map(\.name), ["First", "Second"])
    }

    func testStarredDecodesFavourites() throws {
        let json = """
        {"subsonic-response":{"status":"ok","starred2":{"song":[
        {"id":"s-1","title":"Loved","artist":"A"}]}}}
        """
        XCTAssertEqual(
            try decode(json, as: Starred2.self).response.payload?.song?.first?.title,
            "Loved"
        )
    }
}
