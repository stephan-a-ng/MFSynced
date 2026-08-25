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
        return CRMSyncService(
            config: config,
            authService: .legacyCompatibilityFixture()
        )
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

    // MARK: - S4: 404-aware wire reality (nexus has no /contacts route)

    func test404MarksPushedWithoutRetry() async {
        // The nexus doesn't implement /contacts — catalog + share-time copy
        // (S2) already delivers the photo. A 404 must mark the phone pushed
        // so the route is attempted at most once per launch, not hammered
        // every poll tick forever.
        let service = makeService(synced: ["+15005550004"])
        service.contactInfoProvider = { _ in ("Nexus Contact", nil) }
        service.contactPushStatusOverride = { _ in 404 }
        await service.pushContactInfo()
        XCTAssertTrue(service.pushedContactPhones.contains("+15005550004"))

        // Next poll tick must not re-attempt the (nonexistent) route at all.
        var callCount = 0
        service.contactPushStatusOverride = { _ in
            callCount += 1
            return 404
        }
        await service.pushContactInfo()
        XCTAssertEqual(callCount, 0, "an already-pushed phone must not be re-POSTed")
    }

    func test500StillRetries() async {
        // A real (legacy) backend outage — 5xx — must still retry every
        // poll, unlike the permanent-404 nexus case.
        let service = makeService(synced: ["+15005550005"])
        service.contactInfoProvider = { _ in ("Legacy Contact", nil) }
        service.contactPushStatusOverride = { _ in 500 }
        await service.pushContactInfo()
        XCTAssertFalse(service.pushedContactPhones.contains("+15005550005"))
    }

    func test200MarksPushed() async {
        // Existing behavior unchanged: a successful push marks the phone
        // pushed for the rest of this launch.
        let service = makeService(synced: ["+15005550006"])
        service.contactInfoProvider = { _ in ("OK Contact", nil) }
        service.contactPushStatusOverride = { _ in 200 }
        await service.pushContactInfo()
        XCTAssertTrue(service.pushedContactPhones.contains("+15005550006"))
    }
}
