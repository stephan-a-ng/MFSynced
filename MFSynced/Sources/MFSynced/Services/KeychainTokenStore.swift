import Foundation
import Security

/// Persists the OIDC (OpenID Connect) `TokenSet` as JSON in one keychain
/// generic-password item (service `tech.moonfive.MFSynced.oidc`). Untested
/// by the suite — every AuthService/CRMSyncService test rides on
/// `InMemoryTokenStore` instead, so a unit test run never touches the real
/// system keychain. Kept small on purpose: no caching, no migration, just
/// one JSON blob in and out.
///
/// Keychain flavor: the modern data-protection keychain is preferred (an
/// ad-hoc re-sign otherwise re-prompts for access; see deploy.md) — but it
/// returns errSecMissingEntitlement (-34018) for a Developer ID app that
/// carries no keychain-access-groups entitlement, which is exactly how the
/// notarized Phone Sync build ships. Every operation therefore tries the
/// data-protection keychain first and falls back to the legacy file-based
/// login keychain when the entitlement is missing. (This bit for real:
/// sign-in completed its whole OIDC flow, then died persisting the token.)
struct KeychainTokenStore: TokenStore {
    private let service = "tech.moonfive.MFSynced.oidc"
    private let account = "phonesync"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain operation failed (OSStatus \(status): \(detail))"
            }
        }
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Runs `operation` against the data-protection keychain first, falling
    /// back to the file-based login keychain when the process lacks the
    /// entitlement the modern keychain demands.
    private func withFallback<T>(_ operation: (_ dataProtection: Bool) throws -> T) rethrows -> T {
        do {
            return try operation(true)
        } catch KeychainError.unhandled(let status) where status == errSecMissingEntitlement {
            return try operation(false)
        }
    }

    func save(_ tokenSet: TokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)
        try withFallback { dataProtection in
            // Upsert: try update first (the common case — a rotated token
            // replacing the last one); fall back to add for the first-ever
            // sign-in on this Mac. Accessibility is (re-)asserted on BOTH
            // paths, not just add.
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(dataProtection: dataProtection) as CFDictionary,
                attributes as CFDictionary
            )
            if updateStatus == errSecItemNotFound {
                var addQuery = baseQuery(dataProtection: dataProtection)
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
            } else if updateStatus != errSecSuccess {
                throw KeychainError.unhandled(updateStatus)
            }
        }
    }

    func load() throws -> TokenSet? {
        try withFallback { dataProtection in
            var query = baseQuery(dataProtection: dataProtection)
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
    }

    func clear() throws {
        try withFallback { dataProtection in
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unhandled(status)
            }
        }
    }
}
