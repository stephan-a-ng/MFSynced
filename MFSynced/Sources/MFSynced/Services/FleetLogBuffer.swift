import Foundation

/// In-memory ring buffer between `crmLog` and the nexus's log-upload wire
/// (`POST {apiEndpoint}/logs`), so a remote Mac can be debugged from the
/// datalake without SSH (Secure Shell) access to it.
///
/// Rules, in priority order:
/// 1. Logging never blocks and never fails — append is a lock plus an
///    array write, nothing else.
/// 2. Sync always outranks logs — the uploader drains in bounded batches
///    and re-buffers on failure; nothing here can stall a poll.
/// 3. Memory is capped — beyond `capacity` entries the OLDEST drop first.
///    A Mac that was offline for a day uploads its tail, not its history.
final class FleetLogBuffer {
    struct Entry {
        let ts: Date
        let level: String
        let category: String
        let line: String
    }

    static let shared = FleetLogBuffer()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    func append(level: String = "info", category: String = "CRMSync", line: String) {
        lock.lock()
        defer { lock.unlock() }
        // The wire caps one line at 2000 characters; truncate here so an
        // oversized line degrades to a shorter line instead of a 422 that
        // would poison its whole batch on upload.
        entries.append(
            Entry(ts: Date(), level: level, category: category, line: String(line.prefix(2000)))
        )
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Remove and return up to `max` oldest entries for one upload batch.
    func drain(max: Int) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let batch = Array(entries.prefix(max))
        entries.removeFirst(batch.count)
        return batch
    }

    /// Put a failed batch back at the FRONT (it is older than anything
    /// appended meanwhile), re-applying the drop-oldest cap.
    func requeue(_ batch: [Entry]) {
        lock.lock()
        defer { lock.unlock() }
        entries.insert(contentsOf: batch, at: 0)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
