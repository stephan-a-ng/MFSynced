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

    func testFetchCatalogExcludesGroupChats() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        // fetchConversations()'s existing convention (Conversation.isGroup /
        // Message.isGroup) is chat.style == 43 for a group; fetchCatalog()
        // reuses that same convention (WHERE c.style != 43) so it must never
        // return a chat fetchConversations() itself flags as a group.
        let groupIDs = Set(
            try db.fetchConversations().filter { $0.isGroup }.map(\.id)
        )
        guard !groupIDs.isEmpty else {
            throw XCTSkip("no group chats on this Mac to assert exclusion against")
        }
        let catalog = try db.fetchCatalog()
        let catalogIDs = Set(catalog.map(\.chatIdentifier))
        XCTAssertTrue(
            catalogIDs.isDisjoint(with: groupIDs),
            "fetchCatalog() must exclude every chat.style == 43 group chat"
        )
    }

    func testFetchCatalogIncludesMessageCount() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let catalog = try db.fetchCatalog()
        guard !catalog.isEmpty else { throw XCTSkip("no 1:1 conversations on this Mac") }
        for entry in catalog {
            // Every row in the catalog passed HAVING last_message_date IS NOT
            // NULL, i.e. it has at least one message.
            XCTAssertGreaterThan(
                entry.messageCount, 0,
                "chat \(entry.chatIdentifier) has a last-activity date but a zero message_count"
            )
        }
    }

    func testServiceForChatReturnsKnownService() throws {
        guard db != nil else { throw XCTSkip("chat.db not available") }
        let conversations = try db.fetchConversations()
        guard let first = conversations.first else { throw XCTSkip("no chats") }
        let service = db.serviceForChat(identifier: first.id)
        // Every real chat row carries a service name; unknown identifiers get nil.
        XCTAssertNotNil(service)
        XCTAssertNil(db.serviceForChat(identifier: "+10000000000-nonexistent"))
    }
}
