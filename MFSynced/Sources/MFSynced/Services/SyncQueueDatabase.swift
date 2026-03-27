import Foundation
import SQLite3

struct QueueEntry {
    let id: Int64
    let direction: String
    let messageGuid: String
    let phone: String
    let payload: String
    let createdAt: Date
    let retryCount: Int
    let nextRetryAt: Date
}

final class SyncQueueDatabase {
    private let path: String

    init(path: String? = nil) {
        if let path {
            self.path = path
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("MFSynced")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.path = dir.appendingPathComponent("sync_queue.db").path
        }
        createTable()
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        return db
    }

    private func createTable() {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE IF NOT EXISTS sync_queue (
                id INTEGER PRIMARY KEY,
                direction TEXT NOT NULL,
                message_guid TEXT UNIQUE,
                phone TEXT,
                payload TEXT,
                created_at REAL DEFAULT (strftime('%s', 'now')),
                retry_count INTEGER DEFAULT 0,
                next_retry_at REAL DEFAULT 0
            )
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func enqueue(direction: String, messageGuid: String, phone: String, payload: String) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "INSERT OR IGNORE INTO sync_queue (direction, message_guid, phone, payload) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (direction as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (messageGuid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (phone as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (payload as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func fetchPending(direction: String, limit: Int = 50) throws -> [QueueEntry] {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, direction, message_guid, phone, payload, created_at, retry_count, next_retry_at
            FROM sync_queue WHERE direction = ? AND next_retry_at <= ?
            ORDER BY created_at ASC LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (direction as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var entries: [QueueEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(QueueEntry(
                id: sqlite3_column_int64(stmt, 0),
                direction: String(cString: sqlite3_column_text(stmt, 1)),
                messageGuid: String(cString: sqlite3_column_text(stmt, 2)),
                phone: String(cString: sqlite3_column_text(stmt, 3)),
                payload: String(cString: sqlite3_column_text(stmt, 4)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                retryCount: Int(sqlite3_column_int(stmt, 6)),
                nextRetryAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
        return entries
    }

    func remove(messageGuid: String) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM sync_queue WHERE message_guid = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageGuid as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func incrementRetry(messageGuid: String, nextRetryIn: TimeInterval) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "UPDATE sync_queue SET retry_count = retry_count + 1, next_retry_at = ? WHERE message_guid = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 + nextRetryIn)
        sqlite3_bind_text(stmt, 2, (messageGuid as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func pendingCount(direction: String) throws -> Int {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "SELECT COUNT(*) FROM sync_queue WHERE direction = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (direction as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

enum SyncQueueError: Error {
    case openFailed
    case queryFailed(String)
}
