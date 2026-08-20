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
}
