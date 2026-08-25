import Security
import XCTest
@testable import MFSynced

private final class KeychainOperationsRecorder {
    var updateResponses: [OSStatus] = []
    var addResponses: [OSStatus] = []
    var copyResponses: [(OSStatus, Data?)] = []
    var deleteResponses: [OSStatus] = []
    private(set) var updatedDataProtectionFlags: [Bool] = []
    private(set) var addedDataProtectionFlags: [Bool] = []
    private(set) var copiedDataProtectionFlags: [Bool] = []
    private(set) var deletedDataProtectionFlags: [Bool] = []

    var operations: KeychainOperations {
        KeychainOperations(
            update: { [weak self] query, _ in
                guard let self else { return errSecItemNotFound }
                updatedDataProtectionFlags.append(
                    query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
                )
                return updateResponses.isEmpty ? errSecSuccess : updateResponses.removeFirst()
            },
            add: { [weak self] query in
                guard let self else { return errSecItemNotFound }
                addedDataProtectionFlags.append(
                    query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
                )
                return addResponses.isEmpty ? errSecSuccess : addResponses.removeFirst()
            },
            copy: { [weak self] query in
                guard let self else { return (errSecItemNotFound, nil) }
                copiedDataProtectionFlags.append(
                    query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
                )
                return copyResponses.removeFirst()
            },
            delete: { [weak self] query in
                guard let self else { return errSecItemNotFound }
                deletedDataProtectionFlags.append(
                    query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
                )
                return deleteResponses.removeFirst()
            }
        )
    }
}

final class KeychainTokenStoreTests: XCTestCase {
    private let tokenSet = TokenSet(
        accessToken: "synthetic-access",
        refreshToken: "synthetic-refresh",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    func testLoadFallsBackToLegacyKeychainAfterPreferredMiss() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.copyResponses = [
            (errSecItemNotFound, nil),
            (errSecSuccess, try JSONEncoder().encode(tokenSet)),
        ]
        let store = KeychainTokenStore(operations: recorder.operations)

        XCTAssertEqual(try store.load(), tokenSet)
        XCTAssertEqual(recorder.copiedDataProtectionFlags, [true, false])
    }

    func testSaveFallsBackToLegacyKeychainAfterPreferredMissingEntitlement() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.updateResponses = [errSecMissingEntitlement, errSecSuccess]
        let store = KeychainTokenStore(operations: recorder.operations)

        try store.save(tokenSet)

        XCTAssertEqual(recorder.updatedDataProtectionFlags, [true, false])
        XCTAssertTrue(recorder.addedDataProtectionFlags.isEmpty)
    }

    func testSaveAddsOnSameKeychainVariantAfterUpdateMiss() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.updateResponses = [errSecItemNotFound]
        recorder.addResponses = [errSecSuccess]
        let store = KeychainTokenStore(operations: recorder.operations)

        try store.save(tokenSet)

        XCTAssertEqual(recorder.updatedDataProtectionFlags, [true])
        XCTAssertEqual(recorder.addedDataProtectionFlags, [true])
    }

    func testLoadFallsBackAfterPreferredMissingEntitlement() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.copyResponses = [
            (errSecMissingEntitlement, nil),
            (errSecSuccess, try JSONEncoder().encode(tokenSet)),
        ]
        let store = KeychainTokenStore(operations: recorder.operations)

        XCTAssertEqual(try store.load(), tokenSet)
        XCTAssertEqual(recorder.copiedDataProtectionFlags, [true, false])
    }

    func testClearAlwaysAttemptsBothKeychainVariants() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.deleteResponses = [errSecItemNotFound, errSecSuccess]
        let store = KeychainTokenStore(operations: recorder.operations)

        try store.clear()

        XCTAssertEqual(recorder.deletedDataProtectionFlags, [true, false])
    }

    func testClearIgnoresPreferredMissingEntitlementAndClearsLegacy() throws {
        let recorder = KeychainOperationsRecorder()
        recorder.deleteResponses = [errSecMissingEntitlement, errSecSuccess]
        let store = KeychainTokenStore(operations: recorder.operations)

        try store.clear()

        XCTAssertEqual(recorder.deletedDataProtectionFlags, [true, false])
    }

    func testClearReportsLegacyFailureAfterAttemptingBothVariants() {
        let recorder = KeychainOperationsRecorder()
        recorder.deleteResponses = [errSecSuccess, errSecAuthFailed]
        let store = KeychainTokenStore(operations: recorder.operations)

        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(recorder.deletedDataProtectionFlags, [true, false])
    }
}
