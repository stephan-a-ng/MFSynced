import XCTest
@testable import MFSynced

final class CRMSyncHeartbeatTests: XCTestCase {
    func testHeartbeatBodyIncludesOwnerEmailWhenSet() {
        var config = CRMConfig()
        config.ownerEmail = "owner@moonfive.tech"

        let body = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )

        XCTAssertEqual(body["owner_email"] as? String, "owner@moonfive.tech")
    }

    func testHeartbeatBodyOmitsOwnerEmailWhenBlank() {
        var config = CRMConfig()
        config.ownerEmail = "   "

        let body = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )

        XCTAssertNil(body["owner_email"])

        config.ownerEmail = ""
        let emptyBody = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )
        XCTAssertNil(emptyBody["owner_email"])
    }
}
