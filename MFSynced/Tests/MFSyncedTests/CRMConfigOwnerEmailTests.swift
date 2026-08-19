import XCTest
@testable import MFSynced

final class CRMConfigOwnerEmailTests: XCTestCase {
    private let defaultsKey = "mfsynced_crm_config"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testCRMConfigOwnerEmailRoundTripsThroughSaveLoad() {
        var config = CRMConfig()
        config.apiEndpoint = "https://example.com"
        config.apiKey = "key123"
        config.ownerEmail = "owner@moonfive.tech"
        config.save()

        let loaded = CRMConfig.load()
        XCTAssertEqual(loaded.ownerEmail, "owner@moonfive.tech")
        XCTAssertEqual(loaded.apiEndpoint, "https://example.com")
        XCTAssertEqual(loaded.apiKey, "key123")
    }

    func testCRMConfigDecodesLegacyJSONWithoutOwnerEmail() throws {
        // Simulates a config JSON persisted by an older build that predates
        // the ownerEmail field entirely — the key is absent, not empty.
        let legacyJSON = """
        {
            "isEnabled": true,
            "apiEndpoint": "https://example.com",
            "apiKey": "key123",
            "pollIntervalSeconds": 5,
            "syncedPhoneNumbers": ["+15551234567"],
            "mirrorApiEndpoint": "",
            "mirrorApiKey": ""
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CRMConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.ownerEmail, "")
        // Decoding a missing key must not fall back to a blank config —
        // every other field from the legacy payload must survive intact.
        XCTAssertEqual(decoded.isEnabled, true)
        XCTAssertEqual(decoded.apiEndpoint, "https://example.com")
        XCTAssertEqual(decoded.apiKey, "key123")
        XCTAssertEqual(decoded.syncedPhoneNumbers, ["+15551234567"])
    }
}
