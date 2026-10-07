import XCTest
@testable import Aura

/// Request signing is where this protocol bites: `api_sig` is the MD5 of every
/// parameter sorted by name and concatenated as name+value with the secret
/// appended, and `format` is sent but excluded from the signature. A wrong
/// signature fails as an opaque auth error, so the rules are pinned here.
final class AudioScrobblerServiceTests: XCTestCase {

    private let account = ScrobblerAccount(
        id: "test",
        displayName: "Test",
        endpoint: URL(string: "https://example.com/2.0/")!,
        apiKey: "KEY",
        apiSecret: "SECRET",
        sessionKey: "SK"
    )

    // MARK: - Signature

    func testSignatureSortsByNameAndAppendsSecret() {
        let params = ["b": "2", "a": "1", "c": "3"]
        // a1b2c3 + SECRET
        XCTAssertEqual(
            AudioScrobblerService.signature(for: params, secret: "SECRET"),
            MD5.hex("a1b2c3SECRET")
        )
    }

    func testSignatureIsIndependentOfInsertionOrder() {
        let first = AudioScrobblerService.signature(
            for: ["track": "T", "artist": "A", "method": "M"], secret: "S")
        let second = AudioScrobblerService.signature(
            for: ["method": "M", "artist": "A", "track": "T"], secret: "S")
        XCTAssertEqual(first, second)
    }

    func testFormatIsExcludedFromTheSignature() {
        let withFormat = AudioScrobblerService.signature(
            for: ["a": "1", "format": "json"], secret: "S")
        let without = AudioScrobblerService.signature(for: ["a": "1"], secret: "S")
        XCTAssertEqual(withFormat, without, "format must not be signed")
    }

    func testCallbackAndExistingSignatureAreExcluded() {
        let base = AudioScrobblerService.signature(for: ["a": "1"], secret: "S")
        XCTAssertEqual(
            AudioScrobblerService.signature(
                for: ["a": "1", "callback": "cb", "api_sig": "stale"], secret: "S"),
            base
        )
    }

    func testSignatureCoversMultiByteValues() {
        // The digest is over UTF-8 bytes; a wrong encoding here fails auth only
        // for tracks with accents, which is a miserable bug to find.
        XCTAssertEqual(
            AudioScrobblerService.signature(for: ["artist": "Björk"], secret: "S"),
            MD5.hex("artistBjörkS")
        )
    }

    // MARK: - Request body

    func testBodyIncludesApiKeyAndFormat() {
        let body = AudioScrobblerService.formBody(
            for: ["method": "track.scrobble"], account: account, signed: true)

        XCTAssertTrue(body.contains("api_key=KEY"))
        XCTAssertTrue(body.contains("format=json"))
        XCTAssertTrue(body.contains("api_sig="))
    }

    func testBodySignsTheApiKeyItSends() {
        let body = AudioScrobblerService.formBody(
            for: ["method": "auth.getMobileSession"], account: account, signed: true)

        // The signature must cover api_key, so recompute including it.
        let expected = AudioScrobblerService.signature(
            for: ["method": "auth.getMobileSession", "api_key": "KEY"],
            secret: "SECRET"
        )
        XCTAssertTrue(body.contains("api_sig=\(expected)"))
    }

    func testUnsignedBodyOmitsSignature() {
        let body = AudioScrobblerService.formBody(
            for: ["method": "x"], account: account, signed: false)
        XCTAssertFalse(body.contains("api_sig="))
    }

    func testBodyPercentEncodesReservedCharacters() {
        let body = AudioScrobblerService.formBody(
            for: ["track": "Rock & Roll / Part 2"], account: account, signed: false)

        XCTAssertTrue(body.contains("Rock%20%26%20Roll%20%2F%20Part%202"), body)
        XCTAssertFalse(body.contains("Rock & Roll"))
    }

    // MARK: - Endpoint normalisation

    func testNormalizeAddsSchemeAndApiPath() {
        XCTAssertEqual(
            ScrobblerAccount.normalizeEndpoint("fm.example.com")?.absoluteString,
            "https://fm.example.com/2.0/"
        )
    }

    func testNormalizeKeepsAnExplicitApiPath() {
        XCTAssertEqual(
            ScrobblerAccount.normalizeEndpoint("https://libre.fm/2.0/")?.absoluteString,
            "https://libre.fm/2.0/"
        )
    }

    func testNormalizeHandlesTrailingSlashesAndSubpaths() {
        XCTAssertEqual(
            ScrobblerAccount.normalizeEndpoint("https://fm.example.com/gnufm///")?.absoluteString,
            "https://fm.example.com/gnufm/2.0/"
        )
    }

    func testNormalizeStripsQueryAndFragment() {
        XCTAssertEqual(
            ScrobblerAccount.normalizeEndpoint("https://fm.example.com/2.0/?x=1#y")?.absoluteString,
            "https://fm.example.com/2.0/"
        )
    }

    func testNormalizeRejectsBlankAndHostlessInput() {
        XCTAssertNil(ScrobblerAccount.normalizeEndpoint("   "))
        XCTAssertNil(ScrobblerAccount.normalizeEndpoint("not a url"))
    }

    func testPresetEndpoints() {
        XCTAssertEqual(
            ScrobblerAccount.lastFM(apiKey: "k", apiSecret: "s").endpoint.absoluteString,
            "https://ws.audioscrobbler.com/2.0/"
        )
        XCTAssertEqual(
            ScrobblerAccount.libreFM().endpoint.absoluteString,
            "https://libre.fm/2.0/"
        )
    }

    func testCustomAccountNormalisesItsHost() {
        let account = ScrobblerAccount.custom(
            id: "mine", displayName: "Mine", host: "fm.lan:8080")
        XCTAssertEqual(account?.endpoint.absoluteString, "https://fm.lan:8080/2.0/")
    }

    // MARK: - Error mapping

    func testAuthErrorsBecomeSessionExpired() {
        // 4, 9 and 14 all mean the stored credential is unusable.
        for code in [4, 9, 14] {
            XCTAssertEqual(
                AudioScrobblerService.mapError(code: code, message: "x"),
                .sessionExpired,
                "code \(code)"
            )
        }
        XCTAssertFalse(ScrobbleError.sessionExpired.isRetryable)
    }

    func testTransientErrorsAreRetryable() {
        XCTAssertEqual(AudioScrobblerService.mapError(code: 11, message: "x"), .serviceUnavailable)
        XCTAssertEqual(AudioScrobblerService.mapError(code: 16, message: "x"), .serviceUnavailable)
        XCTAssertEqual(AudioScrobblerService.mapError(code: 29, message: "x"), .rateLimited)

        XCTAssertTrue(ScrobbleError.serviceUnavailable.isRetryable)
        XCTAssertTrue(ScrobbleError.rateLimited.isRetryable)
        XCTAssertTrue(ScrobbleError.transport("offline").isRetryable)
    }

    func testUnknownCodeIsPreserved() {
        XCTAssertEqual(
            AudioScrobblerService.mapError(code: 6, message: "Invalid parameters"),
            .service(code: 6, message: "Invalid parameters")
        )
    }

    // MARK: - Response decoding

    func testScrobbleResponseDecodesAttrCounts() throws {
        let json = """
        {"scrobbles":{"@attr":{"accepted":2,"ignored":0},"scrobble":[]}}
        """
        let decoded = try JSONDecoder().decode(ScrobbleResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.scrobbles?.attributes?.accepted, 2)
        XCTAssertEqual(decoded.scrobbles?.attributes?.ignored, 0)
    }

    func testScrobbleResponseAcceptsStringCounts() throws {
        // Last.fm sends numbers; some GNU FM builds send strings.
        let json = """
        {"scrobbles":{"@attr":{"accepted":"1","ignored":"0"}}}
        """
        let decoded = try JSONDecoder().decode(ScrobbleResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.scrobbles?.attributes?.accepted, 1)
    }

    func testApiErrorDecodes() throws {
        let json = """
        {"error":9,"message":"Invalid session key - Please re-authenticate"}
        """
        let decoded = try JSONDecoder().decode(APIError.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.error, 9)
        XCTAssertEqual(AudioScrobblerService.mapError(code: decoded.error, message: ""), .sessionExpired)
    }

    func testAuthResponseDecodesSessionKey() throws {
        let json = """
        {"session":{"name":"someone","key":"abc123","subscriber":0}}
        """
        let decoded = try JSONDecoder().decode(AuthResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.session?.key, "abc123")
        XCTAssertEqual(decoded.session?.name, "someone")
    }

    // MARK: - Batching

    func testAuthenticationStateFollowsTheSessionKey() {
        var unauthenticated = account
        unauthenticated.sessionKey = nil
        XCTAssertFalse(AudioScrobblerService(account: unauthenticated).isAuthenticated)
        XCTAssertTrue(AudioScrobblerService(account: account).isAuthenticated)
    }

    func testScrobblingWithoutASessionThrows() async {
        var unauthenticated = account
        unauthenticated.sessionKey = nil
        let service = AudioScrobblerService(account: unauthenticated)

        do {
            _ = try await service.scrobble([
                Scrobble(artist: "A", track: "T", startedAt: Date())
            ])
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? ScrobbleError, .notConfigured)
        }
    }

    func testEmptyBatchIsANoOp() async throws {
        let result = try await AudioScrobblerService(account: account).scrobble([])
        XCTAssertEqual(result.accepted, 0)
    }
}
