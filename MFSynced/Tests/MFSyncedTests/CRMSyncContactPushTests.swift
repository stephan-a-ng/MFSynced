import XCTest
@testable import MFSynced

final class CRMSyncContactPushTests: XCTestCase {
    private func makeService(synced: Set<String>) -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        // Fast-fail endpoint: connection refused immediately, no network wait.
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        config.syncedPhoneNumbers = synced
        return CRMSyncService(config: config)
    }

    func testUnresolvedContactIsRetriedNextPoll() async {
        // Regression: an unresolved contact (ContactStore still building its
        // phone map / waiting on the permission dialog) must NOT be marked
        // pushed — a later poll retries once the provider can resolve it.
        let service = makeService(synced: ["+15005550001"])
        service.contactInfoProvider = { _ in (nil, nil) }
        await service.pushContactInfo()
        XCTAssertTrue(service.pushedContactPhones.isEmpty)
    }

    func testFailedPushIsRetriedNextPoll() async {
        // A resolved contact whose upload fails (endpoint unreachable) is
        // un-marked so the next poll retries.
        let service = makeService(synced: ["+15005550002"])
        service.contactInfoProvider = { _ in ("Vince Tester", nil) }
        await service.pushContactInfo()
        XCTAssertFalse(service.pushedContactPhones.contains("+15005550002"))
    }

    func testNoProviderMeansNoTracking() async {
        let service = makeService(synced: ["+15005550003"])
        await service.pushContactInfo()
        XCTAssertTrue(service.pushedContactPhones.isEmpty)
    }
}
