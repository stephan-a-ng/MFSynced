import Foundation
import Security

/// Small synchronous seam around Security.framework. Production uses the
/// live operations; tests inject status/data responses without touching a
/// user's Keychain or requiring signing entitlements.
struct KeychainOperations {
    let update: ([String: Any], [String: Any]) -> OSStatus
    let add: ([String: Any]) -> OSStatus
    let copy: ([String: Any]) -> (status: OSStatus, data: Data?)
    let delete: ([String: Any]) -> OSStatus

    static let live = KeychainOperations(
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { query in
            SecItemAdd(query as CFDictionary, nil)
        },
        copy: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

/// Persists the OIDC (OpenID Connect) `TokenSet` as JSON in one keychain
/// generic-password item (service `tech.moonfive.MFSynced.oidc`). Tests use
/// injected KeychainOperations, so unit runs cover routing/error behavior
/// without touching the real system keychain. Kept small on purpose: no
/// caching, no migration, just one JSON blob in and out.
///
/// Keychain flavor: the modern data-protection keychain is preferred (an
/// ad-hoc re-sign otherwise re-prompts for access; see deploy.md) — but it
/// returns errSecMissingEntitlement (-34018) for a Developer ID app that
/// carries no keychain-access-groups entitlement, which is exactly how the
/// notarized Phone Sync build ships. Saving therefore tries the
/// data-protection keychain first and falls back to the legacy file-based
/// login keychain when the entitlement is missing. Reads must also check the
/// legacy keychain when the preferred query returns `errSecItemNotFound`:
/// on a Developer ID build the write can fall back while a later read reports
/// an ordinary miss instead of repeating `errSecMissingEntitlement`. Clearing
/// always targets both locations so sign-out cannot leave a usable legacy
/// token behind.
struct KeychainTokenStore: TokenStore {
    private let service = "tech.moonfive.MFSynced.oidc"
    private let account = "phonesync"
    private let operations: KeychainOperations

    init(operations: KeychainOperations = .live) {
        self.operations = operations
    }

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
            let updateStatus = operations.update(
                baseQuery(dataProtection: dataProtection),
                attributes
            )
            if updateStatus == errSecItemNotFound {
                var addQuery = baseQuery(dataProtection: dataProtection)
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = operations.add(addQuery)
                guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
            } else if updateStatus != errSecSuccess {
                throw KeychainError.unhandled(updateStatus)
            }
        }
    }

    func load() throws -> TokenSet? {
        do {
            if let tokenSet = try load(dataProtection: true) {
                return tokenSet
            }
        } catch KeychainError.unhandled(let status) where status == errSecMissingEntitlement {
            // Expected for Developer ID builds without a keychain access group.
        }
        return try load(dataProtection: false)
    }

    func clear() throws {
        var firstError: Error?
        for dataProtection in [true, false] {
            do {
                try clear(dataProtection: dataProtection)
            } catch KeychainError.unhandled(let status)
                where dataProtection && status == errSecMissingEntitlement {
                continue
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func clear(ifMatching tokenSet: TokenSet) throws {
        guard try load() == tokenSet else { return }
        try clear()
    }

    private func load(dataProtection: Bool) throws -> TokenSet? {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.copy(query)
        switch status {
        case errSecSuccess:
            guard let data else { return nil }
            return try JSONDecoder().decode(TokenSet.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private func clear(dataProtection: Bool) throws {
        let status = operations.delete(baseQuery(dataProtection: dataProtection))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
