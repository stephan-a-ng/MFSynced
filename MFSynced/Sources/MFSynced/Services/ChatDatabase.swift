import Foundation
import SQLite3


// sqlite must copy bound text: with the nil (SQLITE_STATIC) destructor the
// temporary NSString buffer backing `utf8String` can be freed before
// sqlite3_step, silently binding garbage. Field-observed: an exact-match
// lookup returned nil for a row that exists.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ChatDatabase {
    private let path: String

    init(path: String? = nil) {
        if let path {
            self.path = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.path = "\(home)/Library/Messages/chat.db"
        }
    }

    private func openConnection() throws -> OpaquePointer {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw ChatDBError.openFailed(msg)
        }
        return db
    }

    func getMaxRowID() throws -> Int64 {
        let db = try openConnection()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message", -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    func fetchMessages(afterRowID rowID: Int64, chatFilter: String? = nil) throws -> [Message] {
        let db = try openConnection()
        defer { sqlite3_close(db) }

        var sql = """
            SELECT m.ROWID AS message_id, m.guid, m.text, m.attributedBody,
                m.is_from_me, m.date AS message_date, m.date_edited,
                m.associated_message_type, m.associated_message_emoji,
                m.cache_has_attachments, m.service,
                h.id AS sender_id,
                c.chat_identifier, c.display_name, c.style AS chat_style,
                GROUP_CONCAT(DISTINCT a.transfer_name) AS attachment_names,
                GROUP_CONCAT(DISTINCT a.mime_type) AS attachment_types
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE m.ROWID > ?
            """
        if chatFilter != nil { sql += " AND c.chat_identifier = ?" }
        sql += " GROUP BY m.ROWID ORDER BY m.ROWID ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, rowID)
        if let chatFilter {
            sqlite3_bind_text(stmt, 2, (chatFilter as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        return parseMessageRows(stmt)
    }

    func fetchMessages(forChat chatIdentifier: String, limit: Int = 100, beforeRowID: Int64? = nil) throws -> [Message] {
        let db = try openConnection()
        defer { sqlite3_close(db) }

        var sql = """
            SELECT m.ROWID AS message_id, m.guid, m.text, m.attributedBody,
                m.is_from_me, m.date AS message_date, m.date_edited,
                m.associated_message_type, m.associated_message_emoji,
                m.cache_has_attachments, m.service,
                h.id AS sender_id,
                c.chat_identifier, c.display_name, c.style AS chat_style,
                GROUP_CONCAT(DISTINCT a.transfer_name) AS attachment_names,
                GROUP_CONCAT(DISTINCT a.mime_type) AS attachment_types
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE c.chat_identifier = ?
            """
        if beforeRowID != nil { sql += " AND m.ROWID < ?" }
        sql += " GROUP BY m.ROWID ORDER BY m.ROWID DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var p: Int32 = 1
        sqlite3_bind_text(stmt, p, (chatIdentifier as NSString).utf8String, -1, SQLITE_TRANSIENT); p += 1
        if let beforeRowID { sqlite3_bind_int64(stmt, p, beforeRowID); p += 1 }
        sqlite3_bind_int(stmt, p, Int32(limit))

        return parseMessageRows(stmt).reversed()
    }

    /// The Messages service a chat lives on ("iMessage", "SMS" (Short Message
    /// Service), "RCS" (Rich Communication Services)...),
    /// or nil for an unknown identifier. Drives outbound service selection:
    /// a non-iMessage thread should be sent via the SMS-forwarding account.
    func serviceForChat(identifier: String) -> String? {
        guard let db = try? openConnection() else { return nil }
        defer { sqlite3_close(db) }

        if let service = queryService(db, sql: "SELECT service_name FROM chat WHERE chat_identifier = ? LIMIT 1", bind: identifier) {
            return service
        }
        // Formats drift between the portal's normalized E.164 and Apple's
        // chat_identifier; fall back to matching on the last 10 digits.
        let digits = identifier.filter { $0.isNumber }
        guard digits.count >= 10 else { return nil }
        return queryService(
            db,
            sql: "SELECT service_name FROM chat WHERE chat_identifier LIKE ? LIMIT 1",
            bind: "%" + String(digits.suffix(10))
        )
    }

    /// Delivery state of the FIRST outgoing message that appeared in this
    /// chat after `afterRowID` — the message a send just created. Returns
    /// nil until Messages writes the row.
    func outgoingDeliveryState(identifier: String, afterRowID: Int64) -> (delivered: Bool, errorCode: Int)? {
        guard let db = try? openConnection() else { return nil }
        defer { sqlite3_close(db) }

        let digits = identifier.filter { $0.isNumber }
        let suffix = digits.count >= 10 ? String(digits.suffix(10)) : digits
        let sql = """
            SELECT m.is_delivered, m.error FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE (c.chat_identifier = ? OR c.chat_identifier LIKE ?)
              AND m.is_from_me = 1 AND m.ROWID > ?
            ORDER BY m.ROWID ASC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (identifier as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (("%" + suffix) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, afterRowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int(stmt, 0) == 1, Int(sqlite3_column_int(stmt, 1)))
    }

    private func queryService(_ db: OpaquePointer, sql: String, bind: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bind as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    func fetchConversations() throws -> [Conversation] {
        let db = try openConnection()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT c.chat_identifier, c.display_name, c.style, c.service_name,
                MAX(m.date) AS last_message_date
            FROM chat c
            LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            LEFT JOIN message m ON cmj.message_id = m.ROWID
            GROUP BY c.chat_identifier
            HAVING last_message_date IS NOT NULL
            ORDER BY last_message_date DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var conversations: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            conversations.append(Conversation(
                id: columnText(stmt, 0) ?? "",
                displayName: columnText(stmt, 1),
                chatStyle: Int(sqlite3_column_int(stmt, 2)),
                service: columnText(stmt, 3) ?? "iMessage",
                lastMessage: nil,
                messages: [],
                isCRMSynced: false
            ))
        }
        return conversations
    }

    func searchMessages(query: String, limit: Int = 50) throws -> [Message] {
        let db = try openConnection()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.ROWID AS message_id, m.guid, m.text, m.attributedBody,
                m.is_from_me, m.date AS message_date, m.date_edited,
                m.associated_message_type, m.associated_message_emoji,
                m.cache_has_attachments, m.service,
                h.id AS sender_id,
                c.chat_identifier, c.display_name, c.style AS chat_style,
                NULL AS attachment_names, NULL AS attachment_types
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.text LIKE ?
            ORDER BY m.date DESC LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return parseMessageRows(stmt)
    }

    // MARK: - Row Parsing

    private func parseMessageRows(_ stmt: OpaquePointer?) -> [Message] {
        var messages: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(Message(
                id: sqlite3_column_int64(stmt, 0),
                guid: columnText(stmt, 1) ?? "",
                text: columnText(stmt, 2),
                attributedBody: columnBlob(stmt, 3),
                isFromMe: sqlite3_column_int(stmt, 4) != 0,
                date: AppleDateConverter.toDate(sqlite3_column_int64(stmt, 5)) ?? Date.distantPast,
                dateEdited: sqlite3_column_int64(stmt, 6) > 0
                    ? AppleDateConverter.toDate(sqlite3_column_int64(stmt, 6)) : nil,
                associatedMessageType: Int(sqlite3_column_int(stmt, 7)),
                associatedMessageEmoji: columnText(stmt, 8),
                cacheHasAttachments: sqlite3_column_int(stmt, 9) != 0,
                service: columnText(stmt, 10) ?? "iMessage",
                senderID: columnText(stmt, 11),
                chatIdentifier: columnText(stmt, 12),
                chatDisplayName: columnText(stmt, 13),
                chatStyle: sqlite3_column_type(stmt, 14) != SQLITE_NULL
                    ? Int(sqlite3_column_int(stmt, 14)) : nil,
                attachmentNames: columnText(stmt, 15),
                attachmentTypes: columnText(stmt, 16)
            ))
        }
        return messages
    }

    private func columnText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: cStr)
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) == SQLITE_BLOB else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, i))
        guard len > 0, let ptr = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: ptr, count: len)
    }
}

enum ChatDBError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open chat.db: \(msg)"
        case .queryFailed(let msg): return "Query failed: \(msg)"
        }
    }
}
