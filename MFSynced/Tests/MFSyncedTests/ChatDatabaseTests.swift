import XCTest
import SQLite3
@testable import MFSynced

final class ChatDatabaseTests: XCTestCase {
    var db: ChatDatabase!
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFSynced-ChatDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )

        let dbURL = fixtureDirectory.appendingPathComponent("chat.db")
        try Self.createFixture(at: dbURL.path)
        db = ChatDatabase(path: dbURL.path)
    }

    override func tearDownWithError() throws {
        db = nil
        if let fixtureDirectory {
            try FileManager.default.removeItem(at: fixtureDirectory)
        }
        try super.tearDownWithError()
    }

    func testGetMaxRowID() throws {
        let maxID = try db.getMaxRowID()
        XCTAssertGreaterThan(maxID, 0)
    }

    func testFetchNewMessages() throws {
        let maxID = try db.getMaxRowID()
        let messages = try db.fetchMessages(afterRowID: maxID - 5)
        XCTAssertFalse(messages.isEmpty)
        for msg in messages {
            XCTAssertGreaterThan(msg.date, Date(timeIntervalSince1970: 0))
        }
    }

    func testFetchConversations() throws {
        let conversations = try db.fetchConversations()
        XCTAssertFalse(conversations.isEmpty)
        for conv in conversations {
            XCTAssertFalse(conv.id.isEmpty)
        }
    }

    func testFetchMessagesForChat() throws {
        let conversations = try db.fetchConversations()
        let first = try XCTUnwrap(conversations.first)
        let messages = try db.fetchMessages(forChat: first.id, limit: 50)
        XCTAssertFalse(messages.isEmpty)
    }

    func testFetchTapbackCarriesNormalizedTargetGUID() throws {
        let messages = try db.fetchMessages(forChat: "+15550000001", limit: 50)
        let reaction = try XCTUnwrap(messages.first { $0.guid == "fixture-reaction-1" })
        XCTAssertTrue(reaction.isTapback)
        XCTAssertEqual(reaction.tapbackReactionType, "love")
        XCTAssertEqual(reaction.tapbackTargetGUID, "fixture-message-1")
    }

    func testSearchMessages() throws {
        let results = try db.searchMessages(query: "the", limit: 10)
        XCTAssertFalse(results.isEmpty)
    }

    func testFetchCatalogExcludesGroupChats() throws {
        // fetchConversations()'s existing convention (Conversation.isGroup /
        // Message.isGroup) is chat.style == 43 for a group; fetchCatalog()
        // reuses that same convention (WHERE c.style != 43) so it must never
        // return a chat fetchConversations() itself flags as a group.
        let groupIDs = Set(
            try db.fetchConversations().filter { $0.isGroup }.map(\.id)
        )
        XCTAssertFalse(groupIDs.isEmpty)
        let catalog = try db.fetchCatalog()
        let catalogIDs = Set(catalog.map(\.chatIdentifier))
        XCTAssertTrue(
            catalogIDs.isDisjoint(with: groupIDs),
            "fetchCatalog() must exclude every chat.style == 43 group chat"
        )
    }

    func testFetchCatalogIncludesMessageCount() throws {
        let catalog = try db.fetchCatalog()
        XCTAssertFalse(catalog.isEmpty)
        for entry in catalog {
            // Every row in the catalog passed HAVING last_message_date IS NOT
            // NULL, i.e. it has at least one message.
            XCTAssertGreaterThan(
                entry.messageCount, 0,
                "chat \(entry.chatIdentifier) has a last-activity date but a zero message_count"
            )
        }
    }

    func testFetchParticipantsReturnsStableHandlesForGroupAndOneToOneChat() throws {
        let participants = try db.fetchParticipants(chatIdentifiers: [
            "chat-fixture-group", "+15550000001"
        ])

        XCTAssertEqual(
            participants["chat-fixture-group"],
            ["+15550000002", "+15550000003", "+15550000004"]
        )
        XCTAssertEqual(participants["+15550000001"], ["+15550000001"])
    }

    func testFetchParticipantsOmitsUnknownChatAndBatchesMoreThanFiveHundredIdentifiers() throws {
        let identifiers = (0..<501).map { "unknown-chat-\($0)" }
            + ["chat-fixture-group"]

        let participants = try db.fetchParticipants(chatIdentifiers: identifiers)

        XCTAssertEqual(
            participants["chat-fixture-group"],
            ["+15550000002", "+15550000003", "+15550000004"]
        )
        XCTAssertNil(participants["unknown-chat-0"])
    }

    func testFetchParticipantsThrowsWhenJoinTableIsMissing() throws {
        let dbURL = fixtureDirectory.appendingPathComponent("chat.db")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE chat_handle_join", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(
            try db.fetchParticipants(chatIdentifiers: ["chat-fixture-group"])
        ) { error in
            guard case let ChatDBError.participantFetchFailed(chunkIndex, message) = error else {
                return XCTFail("Expected participant fetch error, got \(error)")
            }
            XCTAssertEqual(chunkIndex, 0)
            XCTAssertTrue(message.localizedCaseInsensitiveContains("chat_handle_join"))
        }
    }

    func testGuidForChatIdentifier() {
        XCTAssertEqual(db.guid(forChatIdentifier: "chat-fixture-group"), "iMessage;+chat-fixture-group")
        XCTAssertNil(db.guid(forChatIdentifier: "unknown-chat"))
    }

    func testFetchCatalogIncludingGroupsAddsGroupMetadataAndParticipants() throws {
        let catalog = try db.fetchCatalog(includeGroups: true)
        let group = try XCTUnwrap(catalog.first { $0.chatIdentifier == "chat-fixture-group" })

        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.groupName, "Family")
        XCTAssertEqual(group.participants, ["+15550000002", "+15550000003", "+15550000004"])
    }

    func testServiceForChatReturnsKnownService() throws {
        let conversations = try db.fetchConversations()
        let first = try XCTUnwrap(conversations.first)
        let service = db.serviceForChat(identifier: first.id)
        // Every fixture chat carries a service name; unknown identifiers get nil.
        XCTAssertNotNil(service)
        XCTAssertNil(db.serviceForChat(identifier: "+10000000000-nonexistent"))
    }

    /// A deliberately minimal, synthetic Messages-schema subset keeps unit
    /// tests deterministic and prevents tests from opening a user's private
    /// ~/Library/Messages/chat.db or requiring Full Disk Access.
    private static func createFixture(at path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else {
            throw NSError(
                domain: "ChatDatabaseTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create synthetic chat fixture"]
            )
        }
        defer { sqlite3_close(connection) }

        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                chat_identifier TEXT,
                guid TEXT,
                display_name TEXT,
                style INTEGER,
                service_name TEXT
            );
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                is_from_me INTEGER,
                date INTEGER,
                date_edited INTEGER,
                associated_message_type INTEGER,
                associated_message_emoji TEXT,
                associated_message_guid TEXT,
                cache_has_attachments INTEGER,
                service TEXT,
                handle_id INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY,
                transfer_name TEXT,
                mime_type TEXT
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

            INSERT INTO handle (ROWID, id) VALUES
                (1, '+15550000001'), (2, '+15550000002'),
                (3, '+15550000003'), (4, '+15550000004');
            INSERT INTO chat (ROWID, chat_identifier, guid, display_name, style, service_name)
                VALUES (1, '+15550000001', 'iMessage;+15550000001', 'Fixture Contact', 45, 'iMessage'),
                       (2, 'chat-fixture-group', 'iMessage;+chat-fixture-group', 'Family', 43, 'SMS');
            INSERT INTO chat_handle_join (chat_id, handle_id)
                VALUES (1, 1), (2, 2), (2, 3), (2, 4);
            INSERT INTO message (
                ROWID, guid, text, is_from_me, date, date_edited,
                associated_message_type, cache_has_attachments, service, handle_id
            ) VALUES
                (1, 'fixture-message-1', 'the first synthetic message', 0, 700000000000000000, 0, 0, 0, 'iMessage', 1),
                (2, 'fixture-message-2', 'the second synthetic message', 1, 700000001000000000, 0, 0, 0, 'iMessage', 1),
                (3, 'fixture-message-3', 'the synthetic group message', 0, 700000002000000000, 0, 0, 0, 'SMS', 2);
            INSERT INTO message (
                ROWID, guid, text, is_from_me, date, date_edited,
                associated_message_type, associated_message_guid,
                cache_has_attachments, service, handle_id
            ) VALUES
                (4, 'fixture-reaction-1', 'Loved “the first synthetic message”', 0,
                 700000003000000000, 0, 2000, 'p:0/fixture-message-1', 0, 'iMessage', 1);
            INSERT INTO chat_message_join (chat_id, message_id)
                VALUES (1, 1), (1, 2), (2, 3), (1, 4);
            """

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            throw NSError(
                domain: "ChatDatabaseTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
