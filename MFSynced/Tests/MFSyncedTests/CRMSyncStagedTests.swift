import XCTest
@testable import MFSynced

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

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

    func testStagedRowsPlanUsesIncrementalModeWhenCursorExistsAndBackfillDone() {
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 500)
        ]
        let cursors = [
            "+1555": StagedCursor(lastRowID: 1_000, oldestRowID: 800, backfilledCount: 200, backfillDone: true)
        ]

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

    // MARK: - stagedRowsPlan (backfill continuation — FINDING 1)

    func testStagedRowsPlanQuietDoneChatDoesNotStarveLaterChats() {
        // Observed live: the first catalog chat was backfill-done with no
        // new messages, and its incremental entry consumed the ENTIRE tick
        // budget — 2 of 1518 chats ever processed, zero-row POSTs forever.
        // Incremental probes must be budget-free so later chats still get
        // their backfill slots in the same tick.
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1DONE", displayName: nil, lastActivityAt: nil, messageCount: 300),
            ChatCatalogEntry(chatIdentifier: "+1NEW", displayName: nil, lastActivityAt: nil, messageCount: 120),
        ]
        let cursors = [
            "+1DONE": StagedCursor(lastRowID: 5_000, oldestRowID: 4_000, backfilledCount: 200, backfillDone: true)
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: cursors, gated: [], budget: 200
        )

        XCTAssertEqual(plan.count, 2)
        guard case .backfill(let limit) = plan[0].mode else {
            return XCTFail("the fresh chat must still get its backfill slot")
        }
        XCTAssertEqual(limit, 120)
        guard case .incremental = plan[1].mode else {
            return XCTFail("expected incremental probe after higher-priority backfill")
        }
    }

    func testStagedRowsPlanCapsQuietChatQueriesPerTick() {
        let chats = (0..<1_500).map {
            ChatCatalogEntry(
                chatIdentifier: String(format: "chat-%04d", $0),
                displayName: nil,
                lastActivityAt: nil,
                messageCount: 200
            )
        }
        let cursors = Dictionary(uniqueKeysWithValues: chats.map {
            ($0.chatIdentifier, StagedCursor(
                lastRowID: 200, oldestRowID: 1, backfilledCount: 200, backfillDone: true
            ))
        })

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats,
            cursors: cursors,
            gated: [],
            budget: 200,
            queryBudget: 40,
            rotationAfter: nil
        )

        XCTAssertEqual(plan.count, 40)
        XCTAssertEqual(plan.first?.chatIdentifier, "chat-0000")
        XCTAssertEqual(plan.last?.chatIdentifier, "chat-0039")
    }

    func testStagedRowsPlanRotatesAcrossFifteenHundredQuietChats() {
        let chats = (0..<1_500).map {
            ChatCatalogEntry(
                chatIdentifier: String(format: "chat-%04d", $0),
                displayName: nil,
                lastActivityAt: nil,
                messageCount: 200
            )
        }
        let cursors = Dictionary(uniqueKeysWithValues: chats.map {
            ($0.chatIdentifier, StagedCursor(
                lastRowID: 200, oldestRowID: 1, backfilledCount: 200, backfillDone: true
            ))
        })
        var rotationAfter: String?
        var seen = Set<String>()

        for _ in 0..<38 {
            let plan = CRMSyncService.stagedRowsPlan(
                chats: chats,
                cursors: cursors,
                gated: [],
                budget: 200,
                queryBudget: 40,
                rotationAfter: rotationAfter
            )
            let ids = plan.map(\.chatIdentifier)
            seen.formUnion(ids)
            rotationAfter = ids.last
        }

        XCTAssertEqual(seen.count, 1_500)
    }

    func testStagedRowsPlanRotationIsStableAcrossCatalogReorderingAndChurn() {
        let ids = ["chat-d", "chat-a", "chat-c"]
        let cursors = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, StagedCursor(
                lastRowID: 200, oldestRowID: 1, backfilledCount: 200, backfillDone: true
            ))
        })
        let chats = ids.map {
            ChatCatalogEntry(
                chatIdentifier: $0, displayName: nil, lastActivityAt: nil, messageCount: 200
            )
        }

        let plan = CRMSyncService.stagedRowsPlan(
            chats: Array(chats.reversed()),
            cursors: cursors,
            gated: [],
            budget: 200,
            queryBudget: 3,
            rotationAfter: "chat-b"
        )

        XCTAssertEqual(plan.map(\.chatIdentifier), ["chat-c", "chat-d", "chat-a"])
    }

    func testStagedRowsPlanPrioritizesBackfillWithinQueryBudget() {
        let doneChats = (0..<10).map {
            ChatCatalogEntry(
                chatIdentifier: String(format: "done-%02d", $0),
                displayName: nil,
                lastActivityAt: nil,
                messageCount: 200
            )
        }
        let fresh = ChatCatalogEntry(
            chatIdentifier: "fresh", displayName: nil, lastActivityAt: nil, messageCount: 200
        )
        let cursors = Dictionary(uniqueKeysWithValues: doneChats.map {
            ($0.chatIdentifier, StagedCursor(
                lastRowID: 200, oldestRowID: 1, backfilledCount: 200, backfillDone: true
            ))
        })

        let plan = CRMSyncService.stagedRowsPlan(
            chats: doneChats + [fresh],
            cursors: cursors,
            gated: [],
            budget: 200,
            queryBudget: 3,
            rotationAfter: nil
        )

        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0].chatIdentifier, "fresh")
        guard case .backfill(let limit) = plan[0].mode else {
            return XCTFail("fresh chat should receive the first query")
        }
        XCTAssertEqual(limit, 200)
        XCTAssertEqual(plan.dropFirst().map(\.chatIdentifier), ["done-00", "done-01"])
    }

    func testStagedRowsPlanKeepsCatalogActivityOrderForBackfills() {
        let chats = [
            ChatCatalogEntry(
                chatIdentifier: "z-recent", displayName: nil,
                lastActivityAt: Date(timeIntervalSince1970: 2), messageCount: 200
            ),
            ChatCatalogEntry(
                chatIdentifier: "a-old", displayName: nil,
                lastActivityAt: Date(timeIntervalSince1970: 1), messageCount: 200
            ),
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats,
            cursors: [:],
            gated: [],
            budget: 200,
            queryBudget: 1,
            rotationAfter: nil
        )

        XCTAssertEqual(plan.first?.chatIdentifier, "z-recent")
    }

    func testStagedRowsPlanContinuesBackfillWhenCursorExistsButNotDone() {
        // A cursor with backfillDone == false — a chat mid-way through its
        // newest-200 window (see FINDING 1) — must resume the backfill from
        // its oldest confirmed rowID, NOT jump to incremental (which would
        // permanently strand every row older than lastRowID).
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 500)
        ]
        let cursors = [
            "+1555": StagedCursor(lastRowID: 1_000, oldestRowID: 950, backfilledCount: 50, backfillDone: false)
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: cursors, gated: [], budget: 200
        )

        XCTAssertEqual(plan.count, 1)
        guard case .continueBackfill(let beforeRowID, let limit) = plan[0].mode else {
            return XCTFail("expected continueBackfill mode")
        }
        XCTAssertEqual(beforeRowID, 950)
        // Remaining window is 200 - 50 = 150, well under the 200 budget.
        XCTAssertEqual(limit, 150)
    }

    func testStagedRowsPlanContinuationLimitCappedByBudgetNotJustWindow() {
        // Only 30 of the window's 150 remaining slots are affordable this
        // tick — the shared budget, not the backfill window, must be the
        // binding constraint here.
        let chats = [
            ChatCatalogEntry(chatIdentifier: "+1555", displayName: nil, lastActivityAt: nil, messageCount: 500)
        ]
        let cursors = [
            "+1555": StagedCursor(lastRowID: 1_000, oldestRowID: 950, backfilledCount: 50, backfillDone: false)
        ]

        let plan = CRMSyncService.stagedRowsPlan(
            chats: chats, cursors: cursors, gated: [], budget: 30
        )

        guard case .continueBackfill(_, let limit) = plan[0].mode else {
            return XCTFail("expected continueBackfill mode")
        }
        XCTAssertEqual(limit, 30)
    }

    func testStagedRowsPlanEmptyWhenNoChats() {
        XCTAssertTrue(
            CRMSyncService.stagedRowsPlan(chats: [], cursors: [:], gated: [], budget: 200).isEmpty
        )
    }

    // MARK: - cursorUpdates (per-chat confirmation-gated cursor advance — FINDING 1)

    func testCursorUpdatesOnlyForConfirmedGuids() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .incremental(afterRowID: 5, limit: 200))]
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
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: ["g1"], rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: [:]
        )

        XCTAssertEqual(updates["chat-a"]?.lastRowID, 10)
    }

    func testCursorUpdatesNoneWhenNothingConfirmed() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .incremental(afterRowID: 5, limit: 200))]
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g1", sender: nil, isFromMe: false,
                body: "a", sentAt: Date(), rowID: 10
            )
        ]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: [], rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: [:]
        )
        XCTAssertTrue(updates.isEmpty)
    }

    func testCursorUpdatesPerChatIndependence() {
        // Chat A fully confirmed, chat B not confirmed at all — chat B must
        // get no update entry while chat A does, proving one chat's
        // confirmation never leaks into another's cursor.
        let plan = [
            CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .incremental(afterRowID: 1, limit: 200)),
            CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-b", mode: .incremental(afterRowID: 1, limit: 200)),
        ]
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

        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: ["a1"], rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: [:]
        )

        XCTAssertEqual(updates["chat-a"]?.lastRowID, 5)
        XCTAssertNil(updates["chat-b"])
    }

    func testCursorUpdatesIncrementalTakesMaxAmongMultipleConfirmedRowsForSameChat() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .incremental(afterRowID: 1, limit: 200))]
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
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: ["g1", "g2", "g3"], rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: [:]
        )
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 20)
    }

    func testCursorUpdatesIncrementalPreservesExistingOldestAndBackfilledCount() {
        // Once backfillDone, oldestRowID/backfilledCount are vestigial —
        // incremental must carry them over unchanged rather than resetting
        // them, since they're meaningless (but still persisted) at that point.
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .incremental(afterRowID: 100, limit: 200))]
        let rows = [
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g1", sender: nil, isFromMe: false,
                body: "a", sentAt: Date(), rowID: 150
            )
        ]
        let existing = ["chat-a": StagedCursor(lastRowID: 100, oldestRowID: 5, backfilledCount: 200, backfillDone: true)]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: ["g1"], rows: rows, exhaustedChats: [],
            existingCursors: existing, messageCounts: [:]
        )
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 150)
        XCTAssertEqual(updates["chat-a"]?.oldestRowID, 5)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 200)
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
    }

    // MARK: - cursorUpdates (backfill / continuation — FINDING 1 core semantics)

    func testCursorUpdatesInitialBackfillNotDoneWhenPartialBudget() {
        // Exactly the bug FINDING 1 describes: a chat with 200 messages that
        // only got a 50-row budget slice must NOT be marked backfillDone.
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .backfill(limit: 50))]
        let rows = (1...50).map { i in
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g\(i)", sender: nil, isFromMe: false,
                body: "m\(i)", sentAt: Date(), rowID: Int64(150 + i)
            )
        }
        let confirmed = Set(rows.map(\.guid))
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: confirmed, rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: ["chat-a": 200]
        )
        XCTAssertEqual(updates["chat-a"]?.backfillDone, false)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 50)
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 200)
        XCTAssertEqual(updates["chat-a"]?.oldestRowID, 151)
    }

    func testCursorUpdatesInitialBackfillDoneWhenMessageCountUnderTwoHundred() {
        // A chat with fewer than 200 messages total finishes backfill in one
        // batch — done at messageCount, not stuck waiting for 200.
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .backfill(limit: 30))]
        let rows = (1...30).map { i in
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g\(i)", sender: nil, isFromMe: false,
                body: "m\(i)", sentAt: Date(), rowID: Int64(i)
            )
        }
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: Set(rows.map(\.guid)), rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: ["chat-a": 30]
        )
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 30)
    }

    func testCursorUpdatesInitialBackfillDoneWhenCountReachesTwoHundred() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .backfill(limit: 200))]
        let rows = (1...200).map { i in
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g\(i)", sender: nil, isFromMe: false,
                body: "m\(i)", sentAt: Date(), rowID: Int64(i)
            )
        }
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: Set(rows.map(\.guid)), rows: rows, exhaustedChats: [],
            existingCursors: [:], messageCounts: [:]  // messageCount unknown — the 200 cap alone must be enough.
        )
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
    }

    func testCursorUpdatesContinuationAccumulatesBackfilledCountAndPreservesLastRowID() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .continueBackfill(beforeRowID: 151, limit: 50))]
        let rows = (101...150).map { i in
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g\(i)", sender: nil, isFromMe: false,
                body: "m\(i)", sentAt: Date(), rowID: Int64(i)
            )
        }
        let existing = ["chat-a": StagedCursor(lastRowID: 200, oldestRowID: 151, backfilledCount: 50, backfillDone: false)]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: Set(rows.map(\.guid)), rows: rows, exhaustedChats: [],
            existingCursors: existing, messageCounts: ["chat-a": 200]
        )
        // lastRowID must stay pinned at the initial batch's newest-seen
        // boundary — continuation only pages OLDER messages.
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 200)
        XCTAssertEqual(updates["chat-a"]?.oldestRowID, 101)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 100)
        XCTAssertEqual(updates["chat-a"]?.backfillDone, false)
    }

    func testCursorUpdatesContinuationDoneWhenRunningTotalReachesWindow() {
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .continueBackfill(beforeRowID: 101, limit: 100))]
        let rows = (1...100).map { i in
            CRMSyncService.StagedMessageRow(
                chatIdentifier: "chat-a", guid: "g\(i)", sender: nil, isFromMe: false,
                body: "m\(i)", sentAt: Date(), rowID: Int64(i)
            )
        }
        let existing = ["chat-a": StagedCursor(lastRowID: 200, oldestRowID: 101, backfilledCount: 100, backfillDone: false)]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: Set(rows.map(\.guid)), rows: rows, exhaustedChats: [],
            existingCursors: existing, messageCounts: [:]
        )
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 200)
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
    }

    func testCursorUpdatesExhaustedChatMarkedDoneWithNoConfirmedRows() {
        // A continuation fetch that returned zero rows (history exhausted
        // before reaching the 200 target) must be marked done immediately —
        // no POST rows needed for it this tick.
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .continueBackfill(beforeRowID: 51, limit: 150))]
        let existing = ["chat-a": StagedCursor(lastRowID: 200, oldestRowID: 51, backfilledCount: 50, backfillDone: false)]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: [], rows: [], exhaustedChats: ["chat-a"],
            existingCursors: existing, messageCounts: [:]
        )
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
        // Nothing new was confirmed — the rest of the cursor carries over.
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 200)
        XCTAssertEqual(updates["chat-a"]?.oldestRowID, 51)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 50)
    }

    func testCursorUpdatesExhaustedChatWithNoExistingCursorDefaultsToZero() {
        // Defensive edge case: exhausted with no prior cursor at all
        // (shouldn't happen in practice — continuation requires a cursor —
        // but must not crash).
        let plan = [CRMSyncService.StagedFetchPlan(chatIdentifier: "chat-a", mode: .continueBackfill(beforeRowID: 1, limit: 150))]
        let updates = CRMSyncService.cursorUpdates(
            plan: plan, confirmedGuids: [], rows: [], exhaustedChats: ["chat-a"],
            existingCursors: [:], messageCounts: [:]
        )
        XCTAssertEqual(updates["chat-a"]?.backfillDone, true)
        XCTAssertEqual(updates["chat-a"]?.lastRowID, 0)
        XCTAssertEqual(updates["chat-a"]?.oldestRowID, 0)
        XCTAssertEqual(updates["chat-a"]?.backfilledCount, 0)
    }

    // MARK: - Multi-tick backfill simulation (pure, no chat.db/network — FINDING 1)

    func testBackfillContinuesAcrossTicksUntilWindowCompleteAndCoversNewest200ExactlyOnce() {
        let chatIdentifier = "+1555"
        // Newest ROWID = 200, oldest = 1; a real chat.db returns messages in
        // ROWID order, so this mirrors fetchMessages(forChat:limit:
        // beforeRowID:)/(forChat:afterRowID:limit:)'s real shape.
        let allMessages = (1...200).map { i in
            makeMessage(id: Int64(i), guid: "g\(i)", chatIdentifier: chatIdentifier)
        }
        let chats = [
            ChatCatalogEntry(chatIdentifier: chatIdentifier, displayName: nil, lastActivityAt: nil, messageCount: 200)
        ]

        func simulateFetch(_ mode: CRMSyncService.StagedFetchMode) -> [Message] {
            switch mode {
            case .backfill(let limit):
                return Array(allMessages.suffix(limit))
            case .continueBackfill(let beforeRowID, let limit):
                return Array(allMessages.filter { $0.id < beforeRowID }.suffix(limit))
            case .incremental(let afterRowID, let limit):
                return Array(allMessages.filter { $0.id > afterRowID }.prefix(limit))
            }
        }

        var cursors: [String: StagedCursor] = [:]
        var coveredRowIDs: [Int64] = []
        var ticks = 0

        while cursors[chatIdentifier]?.backfillDone != true {
            ticks += 1
            XCTAssertLessThan(ticks, 20, "budget-50 backfill of 200 messages should finish in well under 20 ticks")

            // Tick 1 (no cursor yet) uses a small budget deliberately —
            // the exact partial-slice scenario FINDING 1 was about: a
            // chat that gets less than its full 200-message window in one
            // tick must resume, not get marked done early.
            let plan = CRMSyncService.stagedRowsPlan(chats: chats, cursors: cursors, gated: [], budget: 50)
            XCTAssertEqual(plan.count, 1)
            let entry = plan[0]

            let messages = simulateFetch(entry.mode)
            let rows = CRMSyncService.stagedRows(chatIdentifier: chatIdentifier, messages: messages)
            coveredRowIDs.append(contentsOf: rows.map(\.rowID))

            // Simulate the server confirming every posted row.
            let updates = CRMSyncService.cursorUpdates(
                plan: plan, confirmedGuids: Set(rows.map(\.guid)), rows: rows, exhaustedChats: [],
                existingCursors: cursors, messageCounts: [chatIdentifier: 200]
            )
            for (identifier, cursor) in updates { cursors[identifier] = cursor }
        }

        XCTAssertEqual(ticks, 4, "200 messages at 50/tick should take exactly 4 ticks")
        XCTAssertEqual(coveredRowIDs.count, 200, "every one of the newest 200 messages must be staged exactly once")
        XCTAssertEqual(Set(coveredRowIDs), Set((1...200).map(Int64.init)))
        XCTAssertEqual(cursors[chatIdentifier]?.backfilledCount, 200)
    }

    func testBackfillTickOneStagesNewestSliceAndLeavesCursorNotDone() {
        let chatIdentifier = "+1555"
        let allMessages = (1...200).map { i in
            makeMessage(id: Int64(i), guid: "g\(i)", chatIdentifier: chatIdentifier)
        }
        let chats = [
            ChatCatalogEntry(chatIdentifier: chatIdentifier, displayName: nil, lastActivityAt: nil, messageCount: 200)
        ]

        let plan1 = CRMSyncService.stagedRowsPlan(chats: chats, cursors: [:], gated: [], budget: 50)
        guard case .backfill(let limit1) = plan1[0].mode else { return XCTFail("expected backfill mode") }
        XCTAssertEqual(limit1, 50)

        let messages1 = Array(allMessages.suffix(50))
        XCTAssertEqual(messages1.map(\.id), Array((151...200).map(Int64.init)))
        let rows1 = CRMSyncService.stagedRows(chatIdentifier: chatIdentifier, messages: messages1)

        let updates1 = CRMSyncService.cursorUpdates(
            plan: plan1, confirmedGuids: Set(rows1.map(\.guid)), rows: rows1, exhaustedChats: [],
            existingCursors: [:], messageCounts: [chatIdentifier: 200]
        )
        let cursorAfterTick1 = updates1[chatIdentifier]

        XCTAssertEqual(cursorAfterTick1?.backfillDone, false)
        XCTAssertEqual(cursorAfterTick1?.backfilledCount, 50)
        XCTAssertEqual(cursorAfterTick1?.oldestRowID, 151)
        XCTAssertEqual(cursorAfterTick1?.lastRowID, 200)

        // Tick 2: cursor exists with backfillDone == false — must continue
        // the backfill from oldestRowID, not switch to incremental.
        let cursors2 = [chatIdentifier: cursorAfterTick1!]
        let plan2 = CRMSyncService.stagedRowsPlan(chats: chats, cursors: cursors2, gated: [], budget: 50)
        guard case .continueBackfill(let beforeRowID2, let limit2) = plan2[0].mode else {
            return XCTFail("expected continueBackfill mode")
        }
        XCTAssertEqual(beforeRowID2, 151)
        XCTAssertEqual(limit2, 50)
    }

    func testZeroRowContinuationFetchMarksBackfillDoneViaUploadStaged() async {
        // End-to-end through uploadStaged() (not just the pure helper): a
        // chat whose continuation fetch returns zero messages must have its
        // cursor persisted as done, even though this tick has nothing else
        // to POST for any chat (so the network call never even fires).
        let chatIdentifier = "+1555"
        let syncQueue = SyncQueueDatabase(path: NSTemporaryDirectory() + "test_staged_\(UUID().uuidString).db")
        try? syncQueue.setStagedCursor(
            chatIdentifier: chatIdentifier, lastRowID: 200, oldestRowID: 51, backfilledCount: 50, backfillDone: false
        )
        let service = makeService(syncQueue: syncQueue)
        service.catalogChatsProvider = {
            [ChatCatalogEntry(chatIdentifier: chatIdentifier, displayName: nil, lastActivityAt: nil, messageCount: 500)]
        }
        service.stagedMessagesProvider = { _, mode in
            guard case .continueBackfill = mode else { XCTFail("expected continueBackfill mode"); return [] }
            return []  // History exhausted before reaching the 200 target.
        }

        await service.uploadStaged()

        // stagedCursor(for:) is `throws -> StagedCursor?`; `try?` on top of
        // that yields StagedCursor?? — flatten with `?? nil` before chaining.
        let cursor = (try? syncQueue.stagedCursor(for: chatIdentifier)) ?? nil
        XCTAssertEqual(cursor?.backfillDone, true)
        XCTAssertEqual(cursor?.backfilledCount, 50)
    }

    // MARK: - uploadStaged() wiring (real async path, fast-fail endpoint —
    // same pattern as CRMSyncCatalogTests: no live server, just proving the
    // provider + DI (dependency injection) hooks are wired correctly end to end).

    private func makeService(
        synced: Set<String> = [],
        // NEVER default to SyncQueueDatabase() here: the no-path init opens
        // the user's REAL Application Support database, and a test run then
        // writes schema/rows into live data (this happened — an old-schema
        // staged_cursors table landed in the real sync_queue.db).
        syncQueue: SyncQueueDatabase = SyncQueueDatabase(
            path: NSTemporaryDirectory() + "test_svc_\(UUID().uuidString).db"
        )
    ) -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        // Fast-fail endpoint: connection refused immediately, no network wait.
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        config.syncedPhoneNumbers = synced
        return CRMSyncService(
            config: config,
            syncQueue: syncQueue,
            authService: .legacyCompatibilityFixture()
        )
    }

    func testUploadStagedNoOpWithoutProviders() async {
        let service = makeService()
        // Neither provider injected — must be a no-op, not a crash.
        await service.uploadStaged()
    }

    func testUploadStagedNoOpWhenNoChats() async {
        let service = makeService()
        service.catalogChatsProvider = { [] }
        service.stagedMessagesProvider = { _, _ in [] }
        await service.uploadStaged()
    }

    func testUploadStagedAdvancesRotationAfterActualQuietProbes() async {
        let syncQueue = SyncQueueDatabase(
            path: NSTemporaryDirectory() + "test_rotation_\(UUID().uuidString).db"
        )
        let chats = (0..<50).map {
            ChatCatalogEntry(
                chatIdentifier: String(format: "chat-%02d", $0),
                displayName: nil,
                lastActivityAt: nil,
                messageCount: 200
            )
        }
        for chat in chats {
            try? syncQueue.setStagedCursor(
                chatIdentifier: chat.chatIdentifier,
                lastRowID: 200,
                oldestRowID: 1,
                backfilledCount: 200,
                backfillDone: true
            )
        }
        let service = makeService(syncQueue: syncQueue)
        service.catalogChatsProvider = { chats }
        let queried = LockedStrings()
        service.stagedMessagesProvider = { chatIdentifier, _ in
            queried.append(chatIdentifier)
            return []
        }

        await service.uploadStaged()
        await service.uploadStaged()

        let ids = queried.values
        XCTAssertEqual(Array(ids.prefix(40)), (0..<40).map { String(format: "chat-%02d", $0) })
        XCTAssertEqual(Array(ids.dropFirst(40).prefix(10)), (40..<50).map { String(format: "chat-%02d", $0) })
    }

    func testUploadStagedRetriesIncrementalChatTruncatedBySharedRowCap() async {
        let syncQueue = SyncQueueDatabase(
            path: NSTemporaryDirectory() + "test_rotation_truncation_\(UUID().uuidString).db"
        )
        let chats = ["chat-a", "chat-b"].map {
            ChatCatalogEntry(
                chatIdentifier: $0, displayName: nil,
                lastActivityAt: nil, messageCount: 200
            )
        }
        for chat in chats {
            try? syncQueue.setStagedCursor(
                chatIdentifier: chat.chatIdentifier,
                lastRowID: 200,
                oldestRowID: 1,
                backfilledCount: 200,
                backfillDone: true
            )
        }
        let service = makeService(syncQueue: syncQueue)
        service.catalogChatsProvider = { chats }
        let queried = LockedStrings()
        service.stagedMessagesProvider = { chatIdentifier, _ in
            queried.append(chatIdentifier)
            let count = chatIdentifier == "chat-a" ? 150 : 200
            return (1...count).map {
                self.makeMessage(
                    id: Int64($0), guid: "\(chatIdentifier)-\($0)",
                    chatIdentifier: chatIdentifier
                )
            }
        }

        await service.uploadStaged()
        await service.uploadStaged()

        XCTAssertEqual(
            queried.values,
            ["chat-a", "chat-b", "chat-b"],
            "the partially accepted chat must be first again on the next pass"
        )
    }

    func testUploadStagedProbesIncrementalBeforeFullBackfillUsesRowBudget() async {
        let syncQueue = SyncQueueDatabase(
            path: NSTemporaryDirectory() + "test_mixed_\(UUID().uuidString).db"
        )
        try? syncQueue.setStagedCursor(
            chatIdentifier: "done",
            lastRowID: 200,
            oldestRowID: 1,
            backfilledCount: 200,
            backfillDone: true
        )
        let service = makeService(syncQueue: syncQueue)
        service.catalogChatsProvider = {
            [
                ChatCatalogEntry(
                    chatIdentifier: "fresh", displayName: nil,
                    lastActivityAt: Date(timeIntervalSince1970: 2), messageCount: 200
                ),
                ChatCatalogEntry(
                    chatIdentifier: "done", displayName: nil,
                    lastActivityAt: Date(timeIntervalSince1970: 1), messageCount: 200
                ),
            ]
        }
        let queried = LockedStrings()
        service.stagedMessagesProvider = { chatIdentifier, mode in
            queried.append(chatIdentifier)
            if case .backfill = mode {
                return (1...200).map {
                    self.makeMessage(
                        id: Int64($0), guid: "fresh-\($0)", chatIdentifier: "fresh"
                    )
                }
            }
            return []
        }

        await service.uploadStaged()

        XCTAssertEqual(Array(queried.values.prefix(2)), ["done", "fresh"])
    }

    @MainActor
    func testUploadStagedSkipsAllGatedChats() async {
        let service = makeService(synced: ["+15551234567"])
        service.catalogChatsProvider = {
            [ChatCatalogEntry(chatIdentifier: "+15551234567", displayName: nil, lastActivityAt: nil, messageCount: 5)]
        }
        let providerCalled = LockedFlag()
        service.stagedMessagesProvider = { _, _ in
            providerCalled.set()
            return []
        }
        await service.uploadStaged()
        // The only catalog chat is gated (already live-synced) — the plan
        // must exclude it entirely, so the fetch provider is never called.
        XCTAssertFalse(providerCalled.value)
    }
}
