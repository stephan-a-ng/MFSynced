import Foundation

struct ReviewHistorySnapshotPage {
    let snapshotID: String
    let snapshotAsOf: Date
    let messages: [Message]
    let hasMore: Bool
    let nextBeforeRowID: Int64?
}

/// Short-lived local chat.db snapshots for owner-only Review pagination.
/// Files stay on this Mac, are mode 0600, and are never logged by path or
/// conversation identifier.
final class ReviewHistorySnapshotStore: @unchecked Sendable {
    private let source: ChatDatabase
    private let directory: URL
    private let pageSize = 200
    private let maxAge: TimeInterval = 2 * 60 * 60
    private let lock = NSLock()

    init(source: ChatDatabase) {
        self.source = source
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        directory = support
            .appendingPathComponent("MFSynced", isDirectory: true)
            .appendingPathComponent("review-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        cleanupExpired()
    }

    func page(
        chatIdentifier: String,
        beforeRowID: Int64?,
        snapshotID requestedSnapshotID: String?
    ) throws -> ReviewHistorySnapshotPage {
        try lock.withLock {
            cleanupExpiredLocked()
            let snapshotID: String
            if let requestedSnapshotID,
               UUID(uuidString: requestedSnapshotID) != nil {
                snapshotID = requestedSnapshotID.lowercased()
            } else {
                snapshotID = UUID().uuidString.lowercased()
            }
            let url = directory.appendingPathComponent("\(snapshotID).sqlite")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard requestedSnapshotID == nil else {
                    throw ReviewHistorySnapshotError.snapshotExpired
                }
                try source.createSnapshot(at: url.path)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let asOf = (attributes[.creationDate] as? Date)
                ?? (attributes[.modificationDate] as? Date)
                ?? Date()
            let database = ChatDatabase(path: url.path)
            let fetched = try database.fetchMessages(
                forChat: chatIdentifier,
                limit: pageSize + 1,
                beforeRowID: beforeRowID
            )
            let bounded = Self.boundedPage(fetched, pageSize: pageSize)
            return ReviewHistorySnapshotPage(
                snapshotID: snapshotID,
                snapshotAsOf: asOf,
                messages: bounded.messages,
                hasMore: bounded.hasMore,
                // Cursor is the oldest DELIVERED row. The extra look-behind
                // row remains eligible for the next `< beforeRowID` page.
                nextBeforeRowID: bounded.nextBeforeRowID ?? beforeRowID
            )
        }
    }

    static func boundedPage(
        _ fetched: [Message], pageSize: Int
    ) -> (messages: [Message], hasMore: Bool, nextBeforeRowID: Int64?) {
        let hasMore = fetched.count > pageSize
        let messages = hasMore ? Array(fetched.suffix(pageSize)) : fetched
        return (messages, hasMore, messages.map(\.id).min())
    }

    func cleanupExpired() {
        lock.withLock { cleanupExpiredLocked() }
    }

    private func cleanupExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "sqlite" {
            let values = try? url.resourceValues(forKeys: [
                .creationDateKey, .contentModificationDateKey,
            ])
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            if date < cutoff { removeSnapshotFiles(at: url) }
        }
    }

    private func removeSnapshotFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

enum ReviewHistorySnapshotError: Error {
    case snapshotExpired
}
