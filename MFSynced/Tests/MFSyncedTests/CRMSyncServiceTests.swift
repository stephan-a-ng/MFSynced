import XCTest
@testable import MFSynced

final class CRMSyncServiceTests: XCTestCase {
    func testQueueInboundOnlyForSyncedContacts() throws {
        var config = CRMConfig()
        config.syncedPhoneNumbers = ["+15551234567"]
        let tempPath = NSTemporaryDirectory() + "test_crm_\(UUID().uuidString).db"
        let queue = SyncQueueDatabase(path: tempPath)
        let service = CRMSyncService(config: config, syncQueue: queue)

        let synced = Message(
            id: 1, guid: "guid-1", text: "hello", attributedBody: nil,
            isFromMe: false, date: Date(), dateEdited: nil,
            associatedMessageType: 0, associatedMessageEmoji: nil,
            cacheHasAttachments: false, service: "iMessage",
            senderID: "+15551234567", chatIdentifier: "+15551234567",
            chatDisplayName: nil, chatStyle: 45,
            attachmentNames: nil, attachmentTypes: nil
        )
        service.queueInbound(message: synced)
        XCTAssertEqual(try queue.fetchPending(direction: "inbound", limit: 10).count, 1)

        let unsynced = Message(
            id: 2, guid: "guid-2", text: "hello", attributedBody: nil,
            isFromMe: false, date: Date(), dateEdited: nil,
            associatedMessageType: 0, associatedMessageEmoji: nil,
            cacheHasAttachments: false, service: "iMessage",
            senderID: "+19999999999", chatIdentifier: "+19999999999",
            chatDisplayName: nil, chatStyle: 45,
            attachmentNames: nil, attachmentTypes: nil
        )
        service.queueInbound(message: unsynced)
        XCTAssertEqual(try queue.fetchPending(direction: "inbound", limit: 10).count, 1)

        try? FileManager.default.removeItem(atPath: tempPath)
    }
}
