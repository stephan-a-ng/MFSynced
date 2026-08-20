import Foundation
import Security

/// Persists the OIDC (OpenID Connect) `TokenSet` as JSON in one login-keychain generic
/// password item (service `tech.moonfive.MFSynced.oidc`). Untested by the
/// suite — every AuthService/CRMSyncService test rides on
/// `InMemoryTokenStore` instead, so a unit test run never touches the real
/// system keychain. Kept small on purpose: no caching, no migration, just
/// one JSON blob in and out.
struct KeychainTokenStore: TokenStore {
    private let service = "tech.moonfive.MFSynced.oidc"
    private let account = "phonesync"

    enum KeychainError: Error {
        case unhandled(OSStatus)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Modern data-protection keychain, not the legacy file-based
            // one — required for a sandboxed/ad-hoc-signed app to get
            // consistent Keychain behavior across builds (an ad-hoc
            // re-sign otherwise re-prompts for access; see deploy.md).
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func save(_ tokenSet: TokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)

        // Upsert: try update first (the common case — a rotated token
        // replacing the last one); fall back to add for the first-ever
        // sign-in on this Mac. Accessibility is (re-)asserted on BOTH
        // paths, not just add: an item that predates this attribute being
        // set correctly (or one restored some other way) must not be left
        // with whatever default accessibility the system assigned it.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    func load() throws -> TokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(TokenSet.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
