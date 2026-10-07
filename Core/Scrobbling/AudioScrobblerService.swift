import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a scrobbler lives and who we are on it.
///
/// Last.fm, Libre.fm and self-hosted GNU FM instances all implement
/// AudioScrobbler 2.0, so the only thing that differs is the endpoint and the
/// credentials — which is what makes custom scrobblers a configuration
/// question rather than a code one.
struct ScrobblerAccount: Codable, Hashable, Identifiable, Sendable {

    var id: String
    var displayName: String
    var endpoint: URL
    var apiKey: String
    var apiSecret: String
    var username: String?
    /// Obtained from `auth.getMobileSession`. Stored in the Keychain, not here.
    var sessionKey: String?
    var isEnabled: Bool

    init(
        id: String,
        displayName: String,
        endpoint: URL,
        apiKey: String,
        apiSecret: String,
        username: String? = nil,
        sessionKey: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.username = username
        self.sessionKey = sessionKey
        self.isEnabled = isEnabled
    }

    // MARK: Presets

    /// Needs your own API key from <https://www.last.fm/api/account/create>.
    static func lastFM(apiKey: String, apiSecret: String) -> ScrobblerAccount {
        ScrobblerAccount(
            id: "lastfm",
            displayName: "Last.fm",
            endpoint: URL(string: "https://ws.audioscrobbler.com/2.0/")!,
            apiKey: apiKey,
            apiSecret: apiSecret
        )
    }

    /// Libre.fm runs GNU FM, which implements the same API. It does not issue
    /// API keys — any non-empty value is accepted — so the defaults below are
    /// fine as-is.
    static func libreFM(apiKey: String = "aura", apiSecret: String = "aura") -> ScrobblerAccount {
        ScrobblerAccount(
            id: "librefm",
            displayName: "Libre.fm",
            endpoint: URL(string: "https://libre.fm/2.0/")!,
            apiKey: apiKey,
            apiSecret: apiSecret
        )
    }

    /// Any other GNU FM instance. `host` may be a bare hostname.
    static func custom(
        id: String,
        displayName: String,
        host: String,
        apiKey: String = "aura",
        apiSecret: String = "aura"
    ) -> ScrobblerAccount? {
        guard let endpoint = normalizeEndpoint(host) else { return nil }
        return ScrobblerAccount(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            apiKey: apiKey,
            apiSecret: apiSecret
        )
    }

    /// Accepts "fm.example.com", "https://fm.example.com" or a full
    /// ".../2.0/" URL, and always lands on the API root.
    static func normalizeEndpoint(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.host?.isEmpty == false else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/2.0") { path += "/2.0" }
        components.path = path + "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// AudioScrobbler 2.0 client.
///
/// Works against Last.fm, Libre.fm and any GNU FM instance. Request signing is
/// the fiddly part: `api_sig` is the MD5 of every parameter sorted by name and
/// concatenated as name+value, with the shared secret appended — and `format`
/// and `callback` are excluded from the signature even though they are sent.
final class AudioScrobblerService: Scrobbler, @unchecked Sendable {

    /// Both the batch cap and the parameter-array format come from the spec.
    static let maximumBatchSize = 50

    private(set) var account: ScrobblerAccount
    private let session: URLSession

    var identifier: String { account.id }
    var displayName: String { account.displayName }
    var isAuthenticated: Bool { account.sessionKey?.isEmpty == false }

    init(account: ScrobblerAccount, session: URLSession? = nil) {
        self.account = account
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Authentication

    /// `auth.getMobileSession`. Exchanges a username and password for a session
    /// key that is stored instead of the password.
    @discardableResult
    func authenticate(username: String, password: String) async throws -> String {
        let response: AuthResponse = try await post([
            "method": "auth.getMobileSession",
            "username": username,
            "password": password
        ], signed: true)

        guard let key = response.session?.key, !key.isEmpty else {
            throw ScrobbleError.malformedResponse("no session key in auth response")
        }
        account.sessionKey = key
        account.username = response.session?.name ?? username
        return key
    }

    func signOut() {
        account.sessionKey = nil
        account.username = nil
    }

    // MARK: - Scrobbler

    func updateNowPlaying(_ update: NowPlayingUpdate) async throws {
        guard let sessionKey = account.sessionKey else { throw ScrobbleError.notConfigured }

        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "artist": update.artist,
            "track": update.track,
            "sk": sessionKey
        ]
        if let album = update.album { params["album"] = album }
        if let albumArtist = update.albumArtist { params["albumArtist"] = albumArtist }
        if let duration = update.duration, duration > 0 {
            params["duration"] = String(Int(duration.rounded()))
        }

        let _: NowPlayingResponse = try await post(params, signed: true)
    }

    func scrobble(_ plays: [Scrobble]) async throws -> ScrobbleResult {
        guard let sessionKey = account.sessionKey else { throw ScrobbleError.notConfigured }
        guard !plays.isEmpty else { return .empty }

        let batch = Array(plays.prefix(Self.maximumBatchSize))
        var params: [String: String] = [
            "method": "track.scrobble",
            "sk": sessionKey
        ]
        // Batched entries are indexed parameters: artist[0], track[0], ...
        for (index, play) in batch.enumerated() {
            params["artist[\(index)]"] = play.artist
            params["track[\(index)]"] = play.track
            params["timestamp[\(index)]"] = String(Int(play.startedAt.timeIntervalSince1970))
            if let album = play.album { params["album[\(index)]"] = album }
            if let albumArtist = play.albumArtist { params["albumArtist[\(index)]"] = albumArtist }
            if let duration = play.duration, duration > 0 {
                params["duration[\(index)]"] = String(Int(duration.rounded()))
            }
            // Only send it when false; the default is true.
            if !play.chosenByUser { params["chosenByUser[\(index)]"] = "0" }
        }

        let response: ScrobbleResponse = try await post(params, signed: true)
        return ScrobbleResult(
            accepted: response.scrobbles?.attributes?.accepted ?? 0,
            ignored: response.scrobbles?.attributes?.ignored ?? 0,
            rejectedIDs: []
        )
    }

    // MARK: - Signing

    /// MD5 of name+value for every parameter sorted by name, with the shared
    /// secret appended. `format` and `callback` are excluded by the spec.
    static func signature(for params: [String: String], secret: String) -> String {
        let excluded: Set<String> = ["format", "callback", "api_sig"]
        let joined = params
            .filter { !excluded.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        return MD5.hex(joined + secret)
    }

    /// The exact body sent for a request, including the signature. Separated
    /// out so it can be asserted on in tests without a network call.
    static func formBody(for params: [String: String], account: ScrobblerAccount, signed: Bool) -> String {
        var all = params
        all["api_key"] = account.apiKey
        if signed {
            all["api_sig"] = signature(for: all, secret: account.apiSecret)
        }
        all["format"] = "json"

        return all
            .sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded`: percent-encode, then spaces as `+`.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Transport

    private func post<T: Decodable>(_ params: [String: String], signed: Bool) async throws -> T {
        var request = URLRequest(url: account.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(for: params, account: account, signed: signed).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ScrobbleError.transport(error.localizedDescription)
        }

        // Errors come back as a JSON body, sometimes with a non-2xx status and
        // sometimes with 200, so the body is checked either way.
        if let apiError = try? JSONDecoder().decode(APIError.self, from: data), apiError.error != 0 {
            throw Self.mapError(code: apiError.error, message: apiError.message ?? "Unknown error")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScrobbleError.service(code: http.statusCode, message: "HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ScrobbleError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// Documented AudioScrobbler error codes that need distinct handling.
    static func mapError(code: Int, message: String) -> ScrobbleError {
        switch code {
        case 4, 9, 14:
            // Authentication failed / invalid session key / token not authorised.
            return .sessionExpired
        case 11:
            return .serviceUnavailable
        case 16:
            return .serviceUnavailable
        case 29:
            return .rateLimited
        default:
            return .service(code: code, message: message)
        }
    }
}

// MARK: - Wire format

struct APIError: Decodable {
    let error: Int
    let message: String?
}

struct AuthResponse: Decodable {
    struct Session: Decodable {
        let name: String?
        let key: String?
        let subscriber: Int?
    }
    let session: Session?
}

struct NowPlayingResponse: Decodable {
    // The body is not useful on success; decoding it only proves it parsed.
    let nowplaying: Nowplaying?
    struct Nowplaying: Decodable {}
}

struct ScrobbleResponse: Decodable {

    struct Scrobbles: Decodable {
        let attributes: Attributes?

        private enum CodingKeys: String, CodingKey {
            // The service uses "@attr" for this.
            case attributes = "@attr"
        }
    }

    struct Attributes: Decodable {
        let accepted: Int?
        let ignored: Int?

        /// These arrive as numbers from Last.fm but as strings from some GNU FM
        /// builds, so both are accepted.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            accepted = try Attributes.flexibleInt(container, .accepted)
            ignored = try Attributes.flexibleInt(container, .ignored)
        }

        private enum Keys: String, CodingKey { case accepted, ignored }

        private static func flexibleInt(
            _ container: KeyedDecodingContainer<Keys>,
            _ key: Keys
        ) throws -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) }
            return nil
        }
    }

    let scrobbles: Scrobbles?
}
