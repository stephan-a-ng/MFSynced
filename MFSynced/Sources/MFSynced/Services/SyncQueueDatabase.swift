import Foundation
import SQLite3

// sqlite must copy bound text: with the nil (SQLITE_STATIC) destructor the
// temporary NSString buffer backing `utf8String` can be freed before
// sqlite3_step, silently binding garbage. Field-observed: an exact-match
// lookup returned nil for a row that exists.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

/// One chat's staged-upload progress. `lastRowID` is the chat.db ROWID
/// through which the chat's INCREMENTAL cursor has advanced (only meaningful
/// once `backfillDone`); `oldestRowID`/`backfilledCount` track how far the
/// newest-200-per-chat backfill window has been consumed so far. Absence of
/// a row entirely (not this struct — see `SyncQueueDatabase.stagedCursor
/// (for:)` returning nil) is what tells CRMSyncService.stagedRowsPlan a chat
/// still needs its initial backfill.
struct StagedCursor: Equatable {
    let lastRowID: Int64
    let oldestRowID: Int64
    let backfilledCount: Int
    let backfillDone: Bool
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
        let stagedCursorsSQL = """
            CREATE TABLE IF NOT EXISTS staged_cursors (
                chat_identifier TEXT PRIMARY KEY,
                last_row_id INTEGER NOT NULL,
                oldest_row_id INTEGER NOT NULL,
                backfilled_count INTEGER NOT NULL DEFAULT 0,
                backfill_done INTEGER NOT NULL DEFAULT 0
            )
            """
        sqlite3_exec(db, stagedCursorsSQL, nil, nil, nil)
        let kvStateSQL = """
            CREATE TABLE IF NOT EXISTS kv_state (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        sqlite3_exec(db, kvStateSQL, nil, nil, nil)
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

    /// Drop every queued row for one phone — the gate-removal purge. A number
    /// the owner took OFF the allowlist must stop uploading immediately,
    /// including rows already captured and retrying.
    func removeAll(phone: String) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM sync_queue WHERE phone = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (phone as NSString).utf8String, -1, nil)
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

    /// The staged-upload cursor for one chat, or nil when that chat has
    /// never had a confirmed staged row — the signal CRMSyncService.
    /// stagedRowsPlan uses to pick INITIAL BACKFILL over incremental/
    /// continuation.
    func stagedCursor(for chatIdentifier: String) throws -> StagedCursor? {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT last_row_id, oldest_row_id, backfilled_count, backfill_done
            FROM staged_cursors WHERE chat_identifier = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (chatIdentifier as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return StagedCursor(
            lastRowID: sqlite3_column_int64(stmt, 0),
            oldestRowID: sqlite3_column_int64(stmt, 1),
            backfilledCount: Int(sqlite3_column_int(stmt, 2)),
            backfillDone: sqlite3_column_int(stmt, 3) != 0
        )
    }

    /// Upserts one chat's staged-upload cursor — called only after the nexus
    /// has CONFIRMED rows up through `lastRowID`/`oldestRowID`, never
    /// speculatively. `oldestRowID`/`backfilledCount` track how much of the
    /// newest-200-per-chat backfill window has been consumed; once
    /// `backfillDone` they stay at whatever they were on the last backfill
    /// batch (only `lastRowID` keeps moving, via the incremental path).
    func setStagedCursor(
        chatIdentifier: String, lastRowID: Int64, oldestRowID: Int64,
        backfilledCount: Int, backfillDone: Bool
    ) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO staged_cursors
                (chat_identifier, last_row_id, oldest_row_id, backfilled_count, backfill_done)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chat_identifier) DO UPDATE SET
                last_row_id = excluded.last_row_id,
                oldest_row_id = excluded.oldest_row_id,
                backfilled_count = excluded.backfilled_count,
                backfill_done = excluded.backfill_done
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (chatIdentifier as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, lastRowID)
        sqlite3_bind_int64(stmt, 3, oldestRowID)
        sqlite3_bind_int(stmt, 4, Int32(backfilledCount))
        sqlite3_bind_int(stmt, 5, backfillDone ? 1 : 0)
        sqlite3_step(stmt)
    }

    /// Every chat's staged-upload cursor, keyed by chat_identifier — the
    /// full picture stagedRowsPlan needs to decide backfill vs continuation
    /// vs incremental for every catalog chat in one pass.
    func allStagedCursors() throws -> [String: StagedCursor] {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "SELECT chat_identifier, last_row_id, oldest_row_id, backfilled_count, backfill_done FROM staged_cursors"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var cursors: [String: StagedCursor] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let identifier = String(cString: sqlite3_column_text(stmt, 0))
            cursors[identifier] = StagedCursor(
                lastRowID: sqlite3_column_int64(stmt, 1),
                oldestRowID: sqlite3_column_int64(stmt, 2),
                backfilledCount: Int(sqlite3_column_int(stmt, 3)),
                backfillDone: sqlite3_column_int(stmt, 4) != 0
            )
        }
        return cursors
    }

    // MARK: - kv_state (scalar sync state, e.g. poll cursors)

    /// Reads one `kv_state` value, or nil when `key` has never been set —
    /// the signal a poll cursor uses to fall back to its starting value (see
    /// `CRMSyncService.pullContactUpdates`).
    func getState(key: String) throws -> String? {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = "SELECT value FROM kv_state WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Upserts one `kv_state` value — called only once a value is confirmed
    /// ready to persist (e.g. a poll cursor after its whole batch applied
    /// successfully), never speculatively.
    func setState(key: String, value: String) throws {
        guard let db = open() else { throw SyncQueueError.openFailed }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO kv_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncQueueError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }
}

enum SyncQueueError: Error {
    case openFailed
    case queryFailed(String)
}
