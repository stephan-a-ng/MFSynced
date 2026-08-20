import XCTest
@testable import MFSynced

final class SyncTargetsTests: XCTestCase {

    // MARK: - Default targets (prod + staging)

    func testCRMConfigDefaultTargetsAreProdThenStaging() {
        let config = CRMConfig()

        XCTAssertEqual(config.targets.count, 2)
        XCTAssertEqual(config.targets.map(\.url.absoluteString), [
            "https://message.moonfive.tech/v1/agent",
            "https://message-api-staging-435877221234.us-west1.run.app/v1/agent",
        ])
        XCTAssertEqual(config.targets.map(\.name), ["prod", "staging"])
    }

    // MARK: - Legacy decode (pre-dual-target payload)

    func testCRMConfigDecodesLegacyShapeAndPreservesCoreFields() throws {
        // Exactly the pre-Slice-A on-disk shape (apiEndpoint/apiKey/mirror*/
        // ownerEmail/isEnabled/pollIntervalSeconds/syncedPhoneNumbers) — no
        // "targets" key at all, since it predates dual-target sync entirely.
        let legacyJSON = """
        {
            "apiEndpoint": "https://example.com",
            "apiKey": "key123",
            "mirrorApiEndpoint": "",
            "mirrorApiKey": "",
            "ownerEmail": "owner@moonfive.tech",
            "isEnabled": true,
            "pollIntervalSeconds": 5,
            "syncedPhoneNumbers": ["+15551234567"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CRMConfig.self, from: legacyJSON)

        // Must decode cleanly — a missing "targets" key must never take down
        // the rest of a legacy payload (same discipline as the existing
        // ownerEmail-less legacy fixture in CRMConfigOwnerEmailTests).
        XCTAssertEqual(decoded.ownerEmail, "owner@moonfive.tech")
        XCTAssertEqual(decoded.isEnabled, true)
        XCTAssertEqual(decoded.pollIntervalSeconds, 5)
        XCTAssertEqual(decoded.syncedPhoneNumbers, ["+15551234567"])

        // A legacy payload has no "targets" key — must fall back to the new
        // [prod, staging] defaults, not decode to an empty/missing list.
        XCTAssertEqual(decoded.targets.map(\.name), ["prod", "staging"])
    }

    // MARK: - Legacy target migration at runtime (CRMConfig.load(), P1-2)
    //
    // The RAW decode shape above is pinned to [prod, staging] regardless —
    // these tests instead pin `CRMConfig.load()`'s behavior (the layer
    // EVERY real call site actually uses), which runs the legacy-endpoint
    // migration on top of that raw decode. See
    // `CRMConfig.applyLegacyTargetMigrationIfNeeded`.

    private let defaultsKey = "mfsynced_crm_config"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testLoadMigratesLegacySingleEndpointToOneTarget() throws {
        let legacyJSON = """
        {
            "apiEndpoint": "https://example.com/v1/agent",
            "apiKey": "prod-key-123",
            "mirrorApiEndpoint": "",
            "mirrorApiKey": "",
            "ownerEmail": "",
            "isEnabled": true,
            "pollIntervalSeconds": 5,
            "syncedPhoneNumbers": []
        }
        """.data(using: .utf8)!
        UserDefaults.standard.set(legacyJSON, forKey: defaultsKey)

        let loaded = CRMConfig.load()

        XCTAssertEqual(loaded.targets.count, 1, "no mirror configured — exactly ONE derived target")
        let primary = try XCTUnwrap(loaded.targets.first)
        XCTAssertEqual(primary.url.absoluteString, "https://example.com/v1/agent")
        XCTAssertEqual(primary.legacyKey, "prod-key-123")
    }

    func testLoadMigratesLegacyMirrorEndpointToTwoTargetsWithSeparateKeys() throws {
        let legacyJSON = """
        {
            "apiEndpoint": "https://prod.example.com/v1/agent",
            "apiKey": "prod-key-123",
            "mirrorApiEndpoint": "https://staging.example.com/v1/agent",
            "mirrorApiKey": "staging-key-456",
            "ownerEmail": "",
            "isEnabled": true,
            "pollIntervalSeconds": 5,
            "syncedPhoneNumbers": []
        }
        """.data(using: .utf8)!
        UserDefaults.standard.set(legacyJSON, forKey: defaultsKey)

        let loaded = CRMConfig.load()

        XCTAssertEqual(loaded.targets.count, 2, "both legacy endpoints configured — TWO derived targets")
        let primary = try XCTUnwrap(loaded.targets.first)
        let mirror = try XCTUnwrap(loaded.targets.last)

        XCTAssertEqual(primary.url.absoluteString, "https://prod.example.com/v1/agent")
        XCTAssertEqual(mirror.url.absoluteString, "https://staging.example.com/v1/agent")

        // The whole point of the fix: each target carries ONLY its OWN
        // legacy key — the prod key must never end up attached to the
        // staging URL (or vice versa).
        XCTAssertEqual(primary.legacyKey, "prod-key-123")
        XCTAssertEqual(mirror.legacyKey, "staging-key-456")
        XCTAssertNotEqual(
            primary.legacyKey, mirror.legacyKey,
            "prod's key must never be attached to the staging (mirror) target"
        )
    }

    func testLoadDoesNotMigrateWhenMirrorFieldsArePartiallyEmpty() throws {
        // mirrorApiEndpoint set but mirrorApiKey NOT — must not synthesize
        // a keyless mirror target from a half-configured legacy pair.
        let legacyJSON = """
        {
            "apiEndpoint": "https://example.com/v1/agent",
            "apiKey": "prod-key-123",
            "mirrorApiEndpoint": "https://staging.example.com/v1/agent",
            "mirrorApiKey": "",
            "ownerEmail": "",
            "isEnabled": true,
            "pollIntervalSeconds": 5,
            "syncedPhoneNumbers": []
        }
        """.data(using: .utf8)!
        UserDefaults.standard.set(legacyJSON, forKey: defaultsKey)

        let loaded = CRMConfig.load()

        XCTAssertEqual(loaded.targets.count, 1)
    }

    func testLoadOfFreshOIDCOnlyConfigKeepsDefaultTargets() {
        // A fresh sign-in-only install has no "targets" key on disk EITHER
        // (never saved yet) but ALSO no legacy apiEndpoint — must keep the
        // [prod, staging] defaults, not attempt a migration with nothing
        // to migrate.
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey))
        let loaded = CRMConfig.load()
        XCTAssertEqual(loaded.targets.map(\.name), ["prod", "staging"])
    }
}
