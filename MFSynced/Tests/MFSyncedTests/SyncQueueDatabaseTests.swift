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
}
