import Foundation
#if canImport(Security)
import Security
#endif

/// Persists scrobbler accounts.
///
/// Endpoints and API keys go in `UserDefaults` — they are not secrets, and an
/// API key is public by design. Session keys go in the Keychain, because a
/// session key is a bearer credential for the user's account.
final class ScrobblerAccountStore: @unchecked Sendable {

    static let shared = ScrobblerAccountStore()

    private let accountsKey = "scrobblers.accounts"
    private let keychainService = "com.example.aura.scrobbler"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Accounts

    /// Accounts with their session keys rehydrated from the Keychain.
    func accounts() -> [ScrobblerAccount] {
        guard let data = defaults.data(forKey: accountsKey),
              let stored = try? JSONDecoder().decode([ScrobblerAccount].self, from: data) else {
            return []
        }
        return stored.map { account in
            var hydrated = account
            hydrated.sessionKey = sessionKey(for: account.id)
            return hydrated
        }
    }

    /// Stores the account, keeping the session key out of `UserDefaults`.
    func save(_ account: ScrobblerAccount) {
        var all = accounts()
        if let index = all.firstIndex(where: { $0.id == account.id }) {
            all[index] = account
        } else {
            all.append(account)
        }
        write(all)
        setSessionKey(account.sessionKey, for: account.id)
    }

    func remove(id: String) {
        write(accounts().filter { $0.id != id })
        setSessionKey(nil, for: id)
    }

    func setEnabled(_ isEnabled: Bool, for id: String) {
        var all = accounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].isEnabled = isEnabled
        write(all)
    }

    private func write(_ accounts: [ScrobblerAccount]) {
        // Strip session keys before they can reach the plist.
        let sanitized = accounts.map { account -> ScrobblerAccount in
            var copy = account
            copy.sessionKey = nil
            return copy
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: accountsKey)
    }

    // MARK: - Keychain

    func sessionKey(for id: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    func setSessionKey(_ key: String?, for id: String) {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]

        guard let key, let data = key.data(using: .utf8) else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            // Readable while locked, because CarPlay can scrobble before the
            // phone has been unlocked.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
        #endif
    }
}
