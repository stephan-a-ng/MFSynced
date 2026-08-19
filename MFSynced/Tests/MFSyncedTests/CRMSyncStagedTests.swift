import XCTest
@testable import MFSynced

final class CRMSyncStagedTests: XCTestCase {

    // MARK: - Test helpers

    /// Builds a Message with sane defaults, overriding only what a given
    /// test cares about — the struct has many fields unrelated to staged
    /// upload (attachments, tapback type, etc.) that every test here can
    /// ignore.
    private func makeMessage(
        id: Int64,
        guid: String,
        text: String? = "hello",
        isFromMe: Bool = false,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        senderID: String? = "+15551234567",
        chatIdentifier: String? = "+15551234567"
    ) -> Message {
        Message(
            id: id,
            guid: guid,
            text: text,
            attributedBody: nil,
            isFromMe: isFromMe,
            date: date,
            dateEdited: nil,
            associatedMessageType: 0,
            associatedMessageEmoji: nil,
            cacheHasAttachments: false,
            service: "iMessage",
            senderID: senderID,
            chatIdentifier: chatIdentifier,
            chatDisplayName: nil,
            chatStyle: 45,
            attachmentNames: nil,
            attachmentTypes: nil
        )
    }

    // MARK: - stagedBody (pure body-builder, mirrors catalogBody/heartbeatBody)

    func testStagedBodyShapeIncludesRequiredFields() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "+15551234567",
                guid: "msg-1",
                sender: "+15551234567",
                isFromMe: false,
                body: "hey there",
                sentAt: sentAt,
                rowID: 42
            )
        ]

        let body = CRMSyncService.stagedBody(agentID: "agent-123", rows: rows)

        XCTAssertEqual(body["agent_id"] as? String, "agent-123")
        let sent = (body["messages"] as? [[String: Any]]) ?? []
        XCTAssertEqual(sent.count, 1)
        let row = sent[0]
        XCTAssertEqual(row["chat_identifier"] as? String, "+15551234567")
        XCTAssertEqual(row["guid"] as? String, "msg-1")
        XCTAssertEqual(row["sender"] as? String, "+15551234567")
        XCTAssertEqual(row["is_from_me"] as? Bool, false)
        XCTAssertEqual(row["body"] as? String, "hey there")
        XCTAssertEqual(row["sent_at"] as? String, ISO8601DateFormatter().string(from: sentAt))
        // rowID is bookkeeping only — never sent on the wire.
        XCTAssertNil(row["rowID"])
        XCTAssertNil(row["row_id"])
    }

    func testStagedBodyOmitsSenderWhenNil() {
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "+15559876543", guid: "msg-2", sender: nil,
                isFromMe: true, body: "sent from me", sentAt: Date(), rowID: 1
            )
        ]
        let body = CRMSyncService.stagedBody(agentID: "agent-123", rows: rows)
        let row = ((body["messages"] as? [[String: Any]]) ?? [])[0]
        XCTAssertNil(row["sender"])
        XCTAssertEqual(row["is_from_me"] as? Bool, true)
    }

    func testStagedBodyEmptyRowsProducesEmptyMessagesArray() {
        let body = CRMSyncService.stagedBody(agentID: "agent-123", rows: [])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - stagedRows (empty-body filtering)

    func testStagedRowsSkipsEmptyBodyMessages() {
        let messages = [
            makeMessage(id: 1, guid: "g1", text: "real content"),
            makeMessage(id: 2, guid: "g2", text: ""),
            makeMessage(id: 3, guid: "g3", text: nil),
            makeMessage(id: 4, guid: "g4", text: "more content"),
        ]

        let rows = CRMSyncService.stagedRows(chatIdentifier: "+15551234567", messages: messages)

        XCTAssertEqual(rows.map(\.guid), ["g1", "g4"])
    }

    func testStagedRowsCarriesRowIDForCursorBookkeeping() {
        let messages = [makeMessage(id: 99, guid: "g1", text: "hi")]
        let rows = CRMSyncService.stagedRows(chatIdentifier: "+15551234567", messages: messages)
        XCTAssertEqual(rows.first?.rowID, 99)
    }

    // MARK: - stagedRowsPlan (pure fetch planning — no chat.db, no network)

    func testStagedRowsPlanExcludesGatedChats() {
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 10),
            ChatCatalogEntry(chatIdentifier: "+1666", displayName: nil, lastActivityAt: nil, messageCount: 10),
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: [:], gated: ["+1555"], budget: 200
        )

        XCTAssertEqual(plan.map(\.chatIdentifier), ["+1666"])
    }

    func testStagedRowsPlanBackfillCappedAtTwoHundred() {
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 10_000)
        ]

        // Budget far exceeds the per-chat backfill cap: the cap itself, not
        // the budget, must be what limits the request.
        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: [:], gated: [], budget: 5_000
        )

        XCTAssertEqual(plan.count, 1)
        guard case .backfill(let limit) = plan[0].mode else {
            return XCTFail("expected backfill mode")
        }
        XCTAssertEqual(limit, 200)
    }

    func testStagedRowsPlanSplitsBudgetAcrossChats() {
        // Two chats with 150 messages each against a 200 budget: the first
        // consumes exactly what it has (150, under both the 200 cap and the
        // budget), leaving 50 for the second — not 200/0.
        let chats = [
            ChatCatalogEntry(chatIdentifier: "chat-a", displayName: nil, lastActivityAt: nil, messageCount: 150),
            ChatCatalogEntry(chatIdentifier: "chat-b", displayName: nil, lastActivityAt: nil, messageCount: 150),
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: [:], gated: [], budget: 200
        )

        XCTAssertEqual(plan.count, 2)
        guard case .backfill(let limitA) = plan[0].mode, case .backfill(let limitB) = plan[1].mode else {
            return XCTFail("expected both chats to be backfill")
        }
        XCTAssertEqual(plan[0].chatIdentifier, "chat-a")
        XCTAssertEqual(limitA, 150)
        XCTAssertEqual(plan[1].chatIdentifier, "chat-b")
        XCTAssertEqual(limitB, 50)
    }

    func testStagedRowsPlanUsesIncrementalModeWhenCursorExists() {
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 500)
        ]
        let cursors = ["+1555": StagedCursor(lastRowID: 1_000, backfillDone: true)]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: cursors, gated: [], budget: 200
        )

        XCTAssertEqual(plan.count, 1)
        guard case .incremental(let afterRowID, let limit) = plan[0].mode else {
            return XCTFail("expected incremental mode")
        }
        XCTAssertEqual(afterRowID, 1_000)
        XCTAssertEqual(limit, 200)
    }

    func testStagedRowsPlanEmptyWhenNoChats() {
        XCTAssertTrue(
            CRMSyncService.stagedRowsPlan(chats: [], cursors: [:], gated: [], budget: 200).isEmpty
        )
    }

    // MARK: - cursorAdvances (per-chat confirmation-gated cursor advance)

    func testCursorAdvancesOnlyForConfirmedGuids() {
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g1", sender: nil, isFromMe: false,
                body: "a", sentAt: Date(), rowID: 10
            ),
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g2", sender: nil, isFromMe: false,
                body: "b", sentAt: Date(), rowID: 11
            ),
        ]

        // Only g1 confirmed: cursor must NOT advance to g2's rowID (11) — an
        // unconfirmed guid must not be silently skipped past.
        let advances = CRMSyncService.cursorAdvances(confirmedGuids: ["g1"], rows: rows)

        XCTAssertEqual(advances["chat-a"], 10)
    }

    func testCursorAdvancesNoneWhenNothingConfirmed() {
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g1", sender: nil, isFromMe: false,
                body: "a", sentAt: Date(), rowID: 10
            )
        ]
        let advances = CRMSyncService.cursorAdvances(confirmedGuids: [], rows: rows)
        XCTAssertTrue(advances.isEmpty)
    }

    func testCursorAdvancesPerChatIndependence() {
        // Chat A fully confirmed, chat B not confirmed at all — chat B must
        // get no advance entry while chat A does, proving one chat's
        // confirmation never leaks into another's cursor.
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "a1", sender: nil, isFromMe: false,
                body: "x", sentAt: Date(), rowID: 5
            ),
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-b", guid: "b1", sender: nil, isFromMe: false,
                body: "y", sentAt: Date(), rowID: 7
            ),
        ]

        let advances = CRMSyncService.cursorAdvances(confirmedGuids: ["a1"], rows: rows)

        XCTAssertEqual(advances["chat-a"], 5)
        XCTAssertNil(advances["chat-b"])
    }

    func testCursorAdvancesTakesMaxAmongMultipleConfirmedRowsForSameChat() {
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g1", sender: nil, isFromMe: false,
                body: "a", sentAt: Date(), rowID: 10
            ),
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g2", sender: nil, isFromMe: false,
                body: "b", sentAt: Date(), rowID: 20
            ),
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g3", sender: nil, isFromMe: false,
                body: "c", sentAt: Date(), rowID: 15
            ),
        ]
        let advances = CRMSyncService.cursorAdvances(confirmedGuids: ["g1", "g2", "g3"], rows: rows)
        XCTAssertEqual(advances["chat-a"], 20)
    }

    // MARK: - uploadStaged() wiring (real async path, fast-fail endpoint —
    // same pattern as CRMSyncCatalogTests: no live server, just proving the
    // provider + DI (dependency injection) hooks are wired correctly end to end).

    private func makeService(synced: Set<String> = []) -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        // Fast-fail endpoint: connection refused immediately, no network wait.
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        config.syncedPhoneNumbers = synced
        return CRMSyncService(config: config)
    }

    func testUploadStagedNoOpWithoutProviders() async {
        let service = makeService()
        // Neither provider injected — must be a no-op, not a crash.
        await service.uploadStaged()
    }

    func testUploadStagedNoOpWhenNoChats() async {
        let service = makeService()
        service.catalogChatsProvider = { [] }
        service.stagedMessagesProvider = { _, _, _ in [] }
        await service.uploadStaged()
    }

    func testUploadStagedSkipsAllGatedChats() async {
        let service = makeService(synced: ["+15551234567"])
        service.catalogChatsProvider = {
            [ChatCatalogEntry(chatIdentifier: "+15551234567", displayName: nil, lastActivityAt: nil, messageCount: 5)]
        }
        var providerCalled = false
        service.stagedMessagesProvider = { _, _, _ in
            providerCalled = true
            return []
        }
        await service.uploadStaged()
        // The only catalog chat is gated (already live-synced) — the plan
        // must exclude it entirely, so the fetch provider is never called.
        XCTAssertFalse(providerCalled)
    }
}
