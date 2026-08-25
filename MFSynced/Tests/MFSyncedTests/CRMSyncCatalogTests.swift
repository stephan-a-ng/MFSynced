import XCTest
@testable import MFSynced

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class CRMSyncCatalogTests: XCTestCase {

    // MARK: - catalogBody (pure body-builder, mirrors S1's heartbeatBody)

    func testCatalogBodyShapeIncludesRequiredFields() {
        let activity = Date(timeIntervalSince1970: 1_700_000_000)
        let chats = [
            CRMSyncService.CatalogChatInput(
                chatIdentifier: "+15551234567",
                displayName: "Vince Tester",
                contactName: "Vince T.",
                photoJPEG: Data([0xFF, 0xD8, 0xFF]),
                lastActivityAt: activity,
                messageCount: 42
            )
        ]

        let body = CRMSyncService.catalogBody(agentID: "agent-123", chats: chats)

        XCTAssertEqual(body["agent_id"] as? String, "agent-123")
        let sent = (body["chats"] as? [[String: Any]]) ?? []
        XCTAssertEqual(sent.count, 1)
        let row = sent[0]
        XCTAssertEqual(row["chat_identifier"] as? String, "+15551234567")
        XCTAssertEqual(row["display_name"] as? String, "Vince Tester")
        XCTAssertEqual(row["contact_name"] as? String, "Vince T.")
        XCTAssertEqual(row["message_count"] as? Int, 42)
        XCTAssertEqual(row["photo_thumb"] as? String, Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        XCTAssertEqual(row["last_activity_at"] as? String, ISO8601DateFormatter().string(from: activity))
    }

    func testCatalogBodyOmitsOptionalFieldsWhenNil() {
        let chats = [
            CRMSyncService.CatalogChatInput(
                chatIdentifier: "+15559876543",
                displayName: "+15559876543",
                contactName: nil,
                photoJPEG: nil,
                lastActivityAt: nil,
                messageCount: 0
            )
        ]

        let body = CRMSyncService.catalogBody(agentID: "agent-123", chats: chats)
        let row = ((body["chats"] as? [[String: Any]]) ?? [])[0]

        XCTAssertNil(row["contact_name"])
        XCTAssertNil(row["photo_thumb"])
        XCTAssertNil(row["last_activity_at"])
        // Required fields are still present even with nothing enriched.
        XCTAssertEqual(row["chat_identifier"] as? String, "+15559876543")
        XCTAssertEqual(row["message_count"] as? Int, 0)
    }

    // MARK: - Oversized photo omission

    func testCatalogOmitsPhotoWhenOversized() {
        // Base64 inflates by ~4/3; this raw blob's base64 form exceeds the
        // 100KB (binary) cutoff in CRMSyncService.catalogMaxPhotoBase64Length.
        let oversized = Data(repeating: 0xAB, count: 80_000)
        XCTAssertGreaterThan(
            oversized.base64EncodedString().utf8.count,
            CRMSyncService.catalogMaxPhotoBase64Length
        )

        let chats = [
            CRMSyncService.CatalogChatInput(
                chatIdentifier: "+15551112222",
                displayName: "Big Photo",
                contactName: "Big Photo",
                photoJPEG: oversized,
                lastActivityAt: nil,
                messageCount: 1
            )
        ]

        let body = CRMSyncService.catalogBody(agentID: "agent-123", chats: chats)
        let row = ((body["chats"] as? [[String: Any]]) ?? [])[0]

        XCTAssertNil(row["photo_thumb"])
        // The rest of the row still goes out — omission is per-field, not
        // per-row.
        XCTAssertEqual(row["chat_identifier"] as? String, "+15551112222")
        XCTAssertEqual(row["contact_name"] as? String, "Big Photo")
    }

    func testCatalogIncludesPhotoUnderLimit() {
        let small = Data(repeating: 0xCD, count: 1_000)
        let chats = [
            CRMSyncService.CatalogChatInput(
                chatIdentifier: "+15551112222", displayName: "Small Photo",
                contactName: nil, photoJPEG: small, lastActivityAt: nil, messageCount: 1
            )
        ]
        let body = CRMSyncService.catalogBody(agentID: "agent-123", chats: chats)
        let row = ((body["chats"] as? [[String: Any]]) ?? [])[0]
        XCTAssertEqual(row["photo_thumb"] as? String, small.base64EncodedString())
    }

    // MARK: - Fingerprint gating (pure decision function — no network, no sleeps)

    func testCatalogSkipsWhenFingerprintUnchangedWithinFloor() {
        let decision = CRMSyncService.catalogUploadDecision(
            now: 1_000,
            lastUploadAt: 900,             // 100s ago: past the 60s minInterval
            minIntervalSeconds: 60,
            fingerprint: 42,
            lastFingerprint: 42,           // unchanged
            lastSuccessAt: 990,            // 10s since last success
            floorIntervalSeconds: 600
        )
        XCTAssertEqual(decision, .skipUnchanged)
    }

    func testCatalogResendsAfterFloorIntervalEvenIfUnchanged() {
        let decision = CRMSyncService.catalogUploadDecision(
            now: 10_000,
            lastUploadAt: 9_940,           // 60s ago: past the 60s minInterval
            minIntervalSeconds: 60,
            fingerprint: 42,
            lastFingerprint: 42,           // still unchanged
            lastSuccessAt: 9_399,          // 601s since last success: past the 600s floor
            floorIntervalSeconds: 600
        )
        XCTAssertEqual(decision, .upload)
    }

    func testCatalogUploadsImmediatelyWhenFingerprintChanges() {
        let decision = CRMSyncService.catalogUploadDecision(
            now: 1_000,
            lastUploadAt: 940,
            minIntervalSeconds: 60,
            fingerprint: 42,
            lastFingerprint: 7,            // changed since last success
            lastSuccessAt: 999,            // 1s ago — well within the floor
            floorIntervalSeconds: 600
        )
        XCTAssertEqual(decision, .upload)
    }

    func testCatalogTooSoonWithinMinInterval() {
        let decision = CRMSyncService.catalogUploadDecision(
            now: 1_000,
            lastUploadAt: 970,             // 30s ago: inside the 60s minInterval
            minIntervalSeconds: 60,
            fingerprint: 42,
            lastFingerprint: 7,            // even though it changed
            lastSuccessAt: nil,
            floorIntervalSeconds: 600
        )
        XCTAssertEqual(decision, .tooSoon)
    }

    // MARK: - Chunking

    func testCatalogChunksAtFiveHundred() {
        let chats = (0..<1_200).map { i in
            CRMSyncService.CatalogChatInput(
                chatIdentifier: "chat-\(i)", displayName: "chat-\(i)",
                contactName: nil, photoJPEG: nil, lastActivityAt: nil, messageCount: 1
            )
        }

        let bodies = CRMSyncService.catalogBodies(agentID: "agent-123", chats: chats)

        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual((bodies[0]["chats"] as? [[String: Any]])?.count, 500)
        XCTAssertEqual((bodies[1]["chats"] as? [[String: Any]])?.count, 500)
        XCTAssertEqual((bodies[2]["chats"] as? [[String: Any]])?.count, 200)

        // Every chat_identifier appears exactly once across the chunks, in
        // order, so a multi-POST run is a straight split, not a reshuffle.
        let allIDs = bodies.flatMap { ($0["chats"] as? [[String: Any]] ?? []) }
            .compactMap { $0["chat_identifier"] as? String }
        XCTAssertEqual(allIDs, chats.map(\.chatIdentifier))
    }

    func testCatalogBodiesEmptyForNoChats() {
        XCTAssertTrue(CRMSyncService.catalogBodies(agentID: "agent-123", chats: []).isEmpty)
    }

    // MARK: - uploadCatalog() wiring (real async path, fast-fail endpoint —
    // same pattern as CRMSyncContactPushTests: no live server, just proving
    // the gate + DI (dependency injection) hooks are wired correctly end to end).

    private func makeService() -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        // Fast-fail endpoint: connection refused immediately, no network wait.
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        return CRMSyncService(
            config: config,
            authService: .legacyCompatibilityFixture()
        )
    }

    func testUploadCatalogTouchesGateEvenOnFailureButNotSuccessState() async {
        let service = makeService()
        service.catalogChatsProvider = {
            [ChatCatalogEntry(chatIdentifier: "+15551234567", displayName: "Vince",
                               lastActivityAt: Date(), messageCount: 3)]
        }
        service.contactInfoProvider = { _ in ("Vince Tester", nil) }

        XCTAssertNil(service.lastCatalogUploadAt)
        await service.uploadCatalog()

        // The 60s gate is touched regardless of network outcome...
        XCTAssertNotNil(service.lastCatalogUploadAt)
        // ...but a failed POST must never be recorded as a successful catalog.
        XCTAssertNil(service.lastCatalogFingerprint)
        XCTAssertNil(service.lastCatalogSuccessAt)
    }

    func testUploadCatalogSkipsNetworkEntirelyWhenNoProvider() async {
        let service = makeService()
        // No catalogChatsProvider injected — must be a no-op, not a crash.
        await service.uploadCatalog()
        XCTAssertNil(service.lastCatalogUploadAt)
    }

    func testUploadCatalogRespectsSixtySecondFloorAcrossCalls() async {
        let service = makeService()
        service.catalogChatsProvider = {
            [ChatCatalogEntry(chatIdentifier: "+15551234567", displayName: "Vince",
                               lastActivityAt: Date(), messageCount: 3)]
        }
        await service.uploadCatalog()
        let firstAttempt = service.lastCatalogUploadAt
        XCTAssertNotNil(firstAttempt)

        // Immediately calling again must be a no-op: still inside the 60s
        // minInterval, so the gate timestamp must not move.
        await service.uploadCatalog()
        XCTAssertEqual(service.lastCatalogUploadAt, firstAttempt)
    }

    func testUnchangedCatalogScanAdvancesAttemptGate() async {
        let service = makeService()
        service.catalogMinIntervalSeconds = 60
        service.catalogFloorIntervalSeconds = 600
        let chat = ChatCatalogEntry(
            chatIdentifier: "+15551234567",
            displayName: "Vince",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 3
        )
        let providerCallCount = LockedCounter()
        service.catalogChatsProvider = {
            providerCallCount.increment()
            return [chat]
        }

        let input = CRMSyncService.CatalogChatInput(
            chatIdentifier: chat.chatIdentifier,
            displayName: chat.displayName ?? chat.chatIdentifier,
            contactName: nil,
            photoJPEG: nil,
            lastActivityAt: chat.lastActivityAt,
            messageCount: chat.messageCount
        )
        let now = ProcessInfo.processInfo.systemUptime
        service.lastCatalogUploadAt = now - 61
        service.lastCatalogFingerprint = CRMSyncService.catalogFingerprint(chats: [input])
        service.lastCatalogSuccessAt = now - 1

        await service.uploadCatalog()
        let skippedAttempt = service.lastCatalogUploadAt
        XCTAssertEqual(providerCallCount.current, 1)
        XCTAssertNotNil(skippedAttempt)

        // The first unchanged scan advances the attempt timestamp, so the
        // next poll tick stays behind the cheap time gate and never repeats
        // the database/contact-enrichment pass.
        await service.uploadCatalog()
        XCTAssertEqual(providerCallCount.current, 1)
        XCTAssertEqual(service.lastCatalogUploadAt, skippedAttempt)
    }
}
