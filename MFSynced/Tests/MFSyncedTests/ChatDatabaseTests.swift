import XCTest
@testable import MFSynced

final class ChatDatabaseTests: XCTestCase {
    var db: ChatDatabase!

    override func setUp() {
        super.setUp()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent("Library/Messages/chat.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        db = ChatDatabase(path: dbPath)
    }

    func testGetMaxRowID() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let maxID = try db.getMaxRowID()
        XCTAssertGreaterThan(maxID, 0)
    }

    func testFetchNewMessages() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let maxID = try db.getMaxRowID()
        let messages = try db.fetchMessages(afterRowID: maxID - 5)
        XCTAssertFalse(messages.isEmpty)
        for msg in messages {
            XCTAssertGreaterThan(msg.date, Date(timeIntervalSince1970: 0))
        }
    }

    func testFetchConversations() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let conversations = try db.fetchConversations()
        XCTAssertFalse(conversations.isEmpty)
        for conv in conversations {
            XCTAssertFalse(conv.id.isEmpty)
        }
    }

    func testFetchMessagesForChat() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let conversations = try db.fetchConversations()
        guard let first = conversations.first else { throw XCTSkip("No conversations") }
        let messages = try db.fetchMessages(forChat: first.id, limit: 50)
        XCTAssertFalse(messages.isEmpty)
    }

    func testSearchMessages() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let results = try db.searchMessages(query: "the", limit: 10)
        XCTAssertFalse(results.isEmpty)
    }
}
