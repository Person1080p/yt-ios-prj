import Foundation
import Security

/// Server address and login for the self-hosted backend.
///
/// The host lives in `UserDefaults` (not secret, and handy to inspect); the
/// password goes in the Keychain so it survives backup/restore without ending
/// up in a plist.
final class SubsonicCredentials: @unchecked Sendable {

    static let shared = SubsonicCredentials()

    private let hostKey = "subsonic.host"
    private let userKey = "subsonic.username"
    private let keychainAccount = "subsonic.password"
    private let keychainService = "com.example.aura"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var host: URL? {
        get {
            guard let raw = defaults.string(forKey: hostKey) else { return nil }
            return URL(string: raw)
        }
        set { defaults.set(newValue?.absoluteString, forKey: hostKey) }
    }

    var username: String? {
        get { defaults.string(forKey: userKey) }
        set { defaults.set(newValue, forKey: userKey) }
    }

    var password: String? {
        get { readKeychain() }
        set { writeKeychain(newValue) }
    }

    func clear() {
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: userKey)
        password = nil
    }

    /// Accepts "myserver.local:4533" as well as a full URL, since typing a
    /// scheme on a phone keyboard is tedious.
    static func normalizeHost(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else { return nil }
        // Strip a trailing slash so appendingPathComponent doesn't double up.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }

    // MARK: - Keychain

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(base as CFDictionary)
            return
        }

        // Update in place if it exists, otherwise insert.
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            // Needs to be readable while the device is locked, because CarPlay
            // can connect and start playback before the phone is unlocked.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
