import XCTest
@testable import MFSynced

final class SyncQueueDatabaseTests: XCTestCase {
    var db: SyncQueueDatabase!
    var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "test_sync_\(UUID().uuidString).db"
        db = SyncQueueDatabase(path: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    func testEnqueueAndFetch() throws {
        try db.enqueue(direction: "inbound", messageGuid: "msg-1", phone: "+1555", payload: "{}")
        try db.enqueue(direction: "inbound", messageGuid: "msg-2", phone: "+1555", payload: "{}")
        let pending = try db.fetchPending(direction: "inbound", limit: 10)
        XCTAssertEqual(pending.count, 2)
    }

    func testRemoveByGuid() throws {
        try db.enqueue(direction: "inbound", messageGuid: "msg-1", phone: "+1555", payload: "{}")
        try db.remove(messageGuid: "msg-1")
        XCTAssertEqual(try db.fetchPending(direction: "inbound", limit: 10).count, 0)
    }

    func testDuplicateGuidIgnored() throws {
        try db.enqueue(direction: "inbound", messageGuid: "msg-1", phone: "+1555", payload: "{}")
        try db.enqueue(direction: "inbound", messageGuid: "msg-1", phone: "+1555", payload: "{}")
        XCTAssertEqual(try db.fetchPending(direction: "inbound", limit: 10).count, 1)
    }

    func testIncrementRetry() throws {
        try db.enqueue(direction: "inbound", messageGuid: "msg-1", phone: "+1555", payload: "{}")
        try db.incrementRetry(messageGuid: "msg-1", nextRetryIn: -10.0)
        let pending = try db.fetchPending(direction: "inbound", limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].retryCount, 1)
    }

    // MARK: - Staged cursors (S3)

    func testStagedCursorMissingByDefault() throws {
        XCTAssertNil(try db.stagedCursor(for: "+1555"))
    }

    func testStagedCursorRoundTrip() throws {
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 42, oldestRowID: 1, backfilledCount: 42, backfillDone: true
        )
        let cursor = try db.stagedCursor(for: "+1555")
        XCTAssertEqual(cursor?.lastRowID, 42)
        XCTAssertEqual(cursor?.oldestRowID, 1)
        XCTAssertEqual(cursor?.backfilledCount, 42)
        XCTAssertEqual(cursor?.backfillDone, true)
    }

    func testStagedCursorUpsertOverwritesPreviousValue() throws {
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 10, oldestRowID: 1, backfilledCount: 10, backfillDone: true
        )
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 25, oldestRowID: 1, backfilledCount: 25, backfillDone: true
        )
        let cursor = try db.stagedCursor(for: "+1555")
        XCTAssertEqual(cursor?.lastRowID, 25)
    }

    func testStagedCursorRoundTripPreservesInProgressBackfillFields() throws {
        // A continuation-in-progress cursor: backfillDone is false, and
        // oldestRowID/backfilledCount are the fields stagedRowsPlan needs to
        // resume the backfill window correctly next tick.
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 300, oldestRowID: 250, backfilledCount: 50, backfillDone: false
        )
        let cursor = try db.stagedCursor(for: "+1555")
        XCTAssertEqual(cursor?.lastRowID, 300)
        XCTAssertEqual(cursor?.oldestRowID, 250)
        XCTAssertEqual(cursor?.backfilledCount, 50)
        XCTAssertEqual(cursor?.backfillDone, false)
    }

    func testAllStagedCursorsReturnsEveryChat() throws {
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 5, oldestRowID: 1, backfilledCount: 5, backfillDone: true
        )
        try db.setStagedCursor(
            chatIdentifier: "+1666", lastRowID: 9, oldestRowID: 1, backfilledCount: 9, backfillDone: false
        )
        let all = try db.allStagedCursors()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["+1555"]?.lastRowID, 5)
        XCTAssertEqual(all["+1666"]?.lastRowID, 9)
        XCTAssertEqual(all["+1666"]?.backfillDone, false)
    }

    func testResetAllStagedCursorsKeepsOtherQueueState() throws {
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 5, oldestRowID: 1,
            backfilledCount: 5, backfillDone: true
        )
        try db.setState(key: "unrelated", value: "kept")

        try db.resetAllStagedCursors()

        XCTAssertTrue(try db.allStagedCursors().isEmpty)
        XCTAssertEqual(try db.getState(key: "unrelated"), "kept")
    }

    func testPrepareReactionBackfillResetsAndMarksExactlyOnce() throws {
        try db.setStagedCursor(
            chatIdentifier: "+1555", lastRowID: 5, oldestRowID: 1,
            backfilledCount: 5, backfillDone: true
        )
        try db.setState(key: "unrelated", value: "kept")

        XCTAssertTrue(try db.prepareReactionBackfill(markerKey: "reaction-repair"))
        XCTAssertTrue(try db.allStagedCursors().isEmpty)
        XCTAssertEqual(try db.getState(key: "reaction-repair"), "1")

        try db.setStagedCursor(
            chatIdentifier: "+1666", lastRowID: 9, oldestRowID: 1,
            backfilledCount: 9, backfillDone: true
        )
        XCTAssertFalse(try db.prepareReactionBackfill(markerKey: "reaction-repair"))
        XCTAssertEqual(try db.stagedCursor(for: "+1666")?.lastRowID, 9)
        XCTAssertEqual(try db.getState(key: "unrelated"), "kept")
    }

    // MARK: - kv_state (S5 — contact-updates poll cursor)

    func testGetStateMissingByDefault() throws {
        XCTAssertNil(try db.getState(key: "contact_updates_cursor"))
    }

    func testSetStateAndGetStateRoundTrip() throws {
        try db.setState(key: "contact_updates_cursor", value: "42")
        XCTAssertEqual(try db.getState(key: "contact_updates_cursor"), "42")
    }

    func testSetStateUpsertOverwritesPreviousValue() throws {
        try db.setState(key: "contact_updates_cursor", value: "1")
        try db.setState(key: "contact_updates_cursor", value: "99")
        XCTAssertEqual(try db.getState(key: "contact_updates_cursor"), "99")
    }

    func testSetStateKeysAreIndependent() throws {
        try db.setState(key: "contact_updates_cursor", value: "5")
        try db.setState(key: "some_other_key", value: "unrelated")
        XCTAssertEqual(try db.getState(key: "contact_updates_cursor"), "5")
        XCTAssertEqual(try db.getState(key: "some_other_key"), "unrelated")
    }
}
