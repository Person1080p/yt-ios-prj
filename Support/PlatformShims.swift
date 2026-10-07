import Foundation

// Stand-ins so the source layer can be built and tested off an Apple platform.
//
// This file is compiled ONLY by the `AuraCore` SwiftPM test harness — it is not
// in the iOS app target (see `project.yml`, which lists App/, Core/, UI/ and
// CarPlay/). On macOS the real frameworks are used and most of this compiles to
// nothing.

#if !canImport(os)
/// Matches the small slice of `os.Logger` the source layer uses.
///
/// The interpolation type exists so call sites can keep their `privacy:`
/// specifiers — those are a real correctness concern on Apple platforms, where
/// an interpolated string is redacted unless marked `.public`, so the shim
/// absorbs them rather than making the source drop them.
struct OSLogPrivacy {
    static let `public` = OSLogPrivacy()
    static let `private` = OSLogPrivacy()
}

struct LogMessage: ExpressibleByStringInterpolation {

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(_ value: T) { text += "\(value)" }
        mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) { text += "\(value)" }
    }

    let text: String
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

struct Logger {
    init(subsystem: String, category: String) {}
    func debug(_ message: LogMessage) {}
    func info(_ message: LogMessage) {}
    func error(_ message: LogMessage) {}
}
#endif

/// Test stand-in for the Keychain-backed credential store.
///
/// Always used in this package, on every platform: the real one
/// (`Core/Util/SubsonicCredentials.swift`) talks to the Keychain, which is not
/// what these tests are for. `SubsonicSource` only reads these three values.
final class SubsonicCredentials: @unchecked Sendable {

    static let shared = SubsonicCredentials()

    var host: URL?
    var username: String?
    var password: String?

    init(host: URL? = nil, username: String? = nil, password: String? = nil) {
        self.host = host
        self.username = username
        self.password = password
    }

    static func normalizeHost(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }
}
