import XCTest
@testable import MFSynced

final class CRMSyncContactUpdatesTests: XCTestCase {

    // MARK: - parseContactUpdates (pure, no network)

    func testParseContactUpdatesHappyPath() {
        let json = """
        {
            "cursor": 42,
            "updates": [
                {"phones": ["+14085551234"], "display_name": "Alexandra Chen", "photo_thumb": "aGVsbG8="},
                {"phones": ["+14085555678", "+14085559999"], "display_name": "Cher", "photo_thumb": null}
            ]
        }
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.cursor, 42)
        XCTAssertEqual(result?.updates.count, 2)

        let first = result?.updates[0]
        XCTAssertEqual(first?.phones, ["+14085551234"])
        XCTAssertEqual(first?.displayName, "Alexandra Chen")
        XCTAssertEqual(first?.photoJPEG, Data(base64Encoded: "aGVsbG8="))

        let second = result?.updates[1]
        XCTAssertEqual(second?.phones, ["+14085555678", "+14085559999"])
        XCTAssertEqual(second?.displayName, "Cher")
        XCTAssertNil(second?.photoJPEG)
    }

    func testParseContactUpdatesEmptyUpdatesArray() {
        let json = """
        {"cursor": 7, "updates": []}
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.cursor, 7)
        XCTAssertEqual(result?.updates.count, 0)
    }

    func testParseContactUpdatesMissingUpdatesKeyDefaultsToEmpty() {
        // The server may omit "updates" entirely rather than sending [] —
        // both must parse to zero updates, not a nil (malformed) result.
        let json = """
        {"cursor": 3}
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.cursor, 3)
        XCTAssertEqual(result?.updates.count, 0)
    }

    func testParseContactUpdatesMissingCursorFailsWholeParse() {
        // No top-level cursor at all: pullContactUpdates must treat this
        // the same as a network error (cursor untouched), so the whole
        // parse fails rather than defaulting to 0 and silently reprocessing
        // from the start.
        let json = """
        {"updates": [{"phones": ["+1555"], "display_name": "X", "photo_thumb": null}]}
        """.data(using: .utf8)!

        XCTAssertNil(CRMSyncService.parseContactUpdates(json: json))
    }

    func testParseContactUpdatesRowMissingPhonesIsDropped() {
        // A row with no phones can't be matched to any local contact — it
        // must be dropped, not crash the whole batch parse.
        let json = """
        {
            "cursor": 10,
            "updates": [
                {"display_name": "No Phones Here", "photo_thumb": null},
                {"phones": ["+1555"], "display_name": "Has Phone", "photo_thumb": null}
            ]
        }
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.cursor, 10)
        XCTAssertEqual(result?.updates.count, 1)
        XCTAssertEqual(result?.updates.first?.displayName, "Has Phone")
    }

    func testParseContactUpdatesRowMissingDisplayNameIsNil() {
        let json = """
        {"cursor": 1, "updates": [{"phones": ["+1555"], "photo_thumb": null}]}
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.updates.count, 1)
        XCTAssertNil(result?.updates.first?.displayName)
    }

    func testParseContactUpdatesInvalidBase64PhotoSkipsPhotoButKeepsName() {
        let json = """
        {"cursor": 1, "updates": [{"phones": ["+1555"], "display_name": "Bad Photo", "photo_thumb": "not-valid-base64!!!"}]}
        """.data(using: .utf8)!

        let result = CRMSyncService.parseContactUpdates(json: json)

        XCTAssertEqual(result?.updates.count, 1)
        XCTAssertEqual(result?.updates.first?.displayName, "Bad Photo")
        XCTAssertNil(result?.updates.first?.photoJPEG)
    }

    func testParseContactUpdatesMalformedJSONReturnsNil() {
        let json = "not json at all".data(using: .utf8)!
        XCTAssertNil(CRMSyncService.parseContactUpdates(json: json))
    }

    // MARK: - pullContactUpdates() wiring (real async path — same DI +
    // fast-fail-endpoint conventions as CRMSyncContactPushTests /
    // CRMSyncCatalogTests / CRMSyncStagedTests).

    private func makeService(
        // NEVER default to SyncQueueDatabase() here: the no-path init opens
        // the user's REAL Application Support database — see the warning in
        // CRMSyncStagedTests.makeService.
        syncQueue: SyncQueueDatabase = SyncQueueDatabase(
            path: NSTemporaryDirectory() + "test_contact_updates_\(UUID().uuidString).db"
        )
    ) -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        // Fast-fail endpoint: connection refused immediately, no network wait.
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        return CRMSyncService(config: config, syncQueue: syncQueue)
    }

    func testPullContactUpdatesNoOpWithoutApplier() async {
        let service = makeService()
        // No contactUpdateApplier injected — must be a no-op, not a crash.
        await service.pullContactUpdates()
    }

    func testPullContactUpdatesApplierCalledOncePerUpdate() async {
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db")
        let service = makeService(syncQueue: syncQueue)
        let responseJSON = """
        {
            "cursor": 5,
            "updates": [
                {"phones": ["+14085551111"], "display_name": "First Person", "photo_thumb": null},
                {"phones": ["+14085552222"], "display_name": "Second Person", "photo_thumb": null}
            ]
        }
        """.data(using: .utf8)!
        service.contactUpdatesFetchOverride = { _ in (200, responseJSON) }

        var appliedCalls: [(phones: [String], name: String?)] = []
        service.contactUpdateApplier = { phones, displayName, _ in
            appliedCalls.append((phones, displayName))
            return true
        }

        await service.pullContactUpdates()

        XCTAssertEqual(appliedCalls.count, 2)
        XCTAssertEqual(appliedCalls[0].phones, ["+14085551111"])
        XCTAssertEqual(appliedCalls[0].name, "First Person")
        XCTAssertEqual(appliedCalls[1].phones, ["+14085552222"])
        XCTAssertEqual(appliedCalls[1].name, "Second Person")
    }

    func testPullContactUpdatesAdvancesCursorAfterFullBatchIncludingFalseAppliers() async {
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db")
        let service = makeService(syncQueue: syncQueue)
        let responseJSON = """
        {"cursor": 99, "updates": [{"phones": ["+1555"], "display_name": "Nobody Local", "photo_thumb": null}]}
        """.data(using: .utf8)!
        service.contactUpdatesFetchOverride = { _ in (200, responseJSON) }
        // Applier returns false (no local match) — the batch is still a
        // FULL SUCCESS from the poll's point of view, so the cursor must
        // still advance.
        service.contactUpdateApplier = { _, _, _ in false }

        await service.pullContactUpdates()

        XCTAssertEqual(try syncQueue.getState(key: CRMSyncService.contactUpdatesCursorKey), "99")
    }

    func testPullContactUpdatesCursorPersistedAcrossServiceInstances() async {
        let path = NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db"
        let responseJSON = """
        {"cursor": 17, "updates": []}
        """.data(using: .utf8)!

        let service1 = makeService(syncQueue: SyncQueueDatabase(path: path))
        service1.contactUpdatesFetchOverride = { _ in (200, responseJSON) }
        service1.contactUpdateApplier = { _, _, _ in true }
        await service1.pullContactUpdates()

        // A fresh service (simulating relaunch) backed by the SAME database
        // file must send the persisted cursor as `after=17`, not restart
        // from 0.
        let service2 = makeService(syncQueue: SyncQueueDatabase(path: path))
        var capturedURL: URL?
        service2.contactUpdatesFetchOverride = { request in
            capturedURL = request.url
            return (200, """
            {"cursor": 17, "updates": []}
            """.data(using: .utf8)!)
        }
        service2.contactUpdateApplier = { _, _, _ in true }
        await service2.pullContactUpdates()

        XCTAssertEqual(capturedURL?.query, "after=17")
    }

    func testPullContactUpdatesNetworkErrorDoesNotAdvanceCursor() async {
        // Real network path (no override): a fast-fail (connection-refused)
        // endpoint proves a genuine network error leaves the cursor
        // untouched, so the same batch is retried next tick.
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db")
        let service = makeService(syncQueue: syncQueue)
        service.contactUpdateApplier = { _, _, _ in
            XCTFail("applier must never be called when the fetch itself failed")
            return true
        }

        await service.pullContactUpdates()

        XCTAssertNil(try syncQueue.getState(key: CRMSyncService.contactUpdatesCursorKey))
    }

    func testPullContactUpdatesMalformedResponseDoesNotAdvanceCursor() async {
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db")
        let service = makeService(syncQueue: syncQueue)
        service.contactUpdatesFetchOverride = { _ in (200, "not json".data(using: .utf8)!) }
        service.contactUpdateApplier = { _, _, _ in
            XCTFail("applier must never be called for a malformed body")
            return true
        }

        await service.pullContactUpdates()

        XCTAssertNil(try syncQueue.getState(key: CRMSyncService.contactUpdatesCursorKey))
    }

    func testPullContactUpdates404DegradesSilently() async {
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_cu_\(UUID().uuidString).db")
        let service = makeService(syncQueue: syncQueue)
        service.contactUpdatesFetchOverride = { _ in (404, Data()) }
        service.contactUpdateApplier = { _, _, _ in
            XCTFail("applier must never be called on a 404 (legacy backend)")
            return true
        }

        await service.pullContactUpdates()

        XCTAssertNil(try syncQueue.getState(key: CRMSyncService.contactUpdatesCursorKey))
    }

    func testPullContactUpdatesRespectsSixtySecondFloorAcrossCalls() async {
        let service = makeService()
        var callCount = 0
        service.contactUpdatesFetchOverride = { _ in
            callCount += 1
            return (200, """
            {"cursor": 1, "updates": []}
            """.data(using: .utf8)!)
        }
        service.contactUpdateApplier = { _, _, _ in true }

        await service.pullContactUpdates()
        XCTAssertEqual(callCount, 1)
        let firstAttempt = service.lastContactUpdatesPollAt
        XCTAssertNotNil(firstAttempt)

        // Immediately calling again must be a no-op: still inside the 60s
        // minInterval, so the fetch never fires and the gate timestamp
        // must not move.
        await service.pullContactUpdates()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(service.lastContactUpdatesPollAt, firstAttempt)
    }

    func testPullContactUpdatesSkipsNetworkEntirelyWhenNoApplier() async {
        let service = makeService()
        var overrideCalled = false
        service.contactUpdatesFetchOverride = { _ in
            overrideCalled = true
            return (200, Data())
        }
        // No contactUpdateApplier injected.
        await service.pullContactUpdates()
        XCTAssertFalse(overrideCalled)
        XCTAssertNil(service.lastContactUpdatesPollAt)
    }
}
