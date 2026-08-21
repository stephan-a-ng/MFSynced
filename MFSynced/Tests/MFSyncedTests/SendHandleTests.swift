import XCTest
@testable import MFSynced

/// Covers the pure parts of the "report this Mac's own handle to the
/// nexus" feature: `CRMSyncService.heartbeatBody`'s `send_handle` field,
/// and `ChatDatabase.selectSelfHandle`'s candidate-picking logic. Neither
/// touches chat.db or the network. `selfHandle()`'s real-chat.db SQL path,
/// the 10-minute cache window, and cross-thread cache behavior have NO
/// automated coverage — they are exercised only by running the app.
final class SendHandleTests: XCTestCase {

    // MARK: - heartbeatBody

    func testHeartbeatBodyIncludesSendHandleWhenSet() {
        let body = CRMSyncService.heartbeatBody(
            config: CRMConfig(),
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil,
            sendHandle: "+15551234567"
        )

        XCTAssertEqual(body["send_handle"] as? String, "+15551234567")
    }

    func testHeartbeatBodyOmitsSendHandleWhenNil() {
        let body = CRMSyncService.heartbeatBody(
            config: CRMConfig(),
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil,
            sendHandle: nil
        )

        XCTAssertNil(body["send_handle"])
    }

    func testHeartbeatBodyOmitsSendHandleWhenBlank() {
        let body = CRMSyncService.heartbeatBody(
            config: CRMConfig(),
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil,
            sendHandle: "   "
        )

        XCTAssertNil(body["send_handle"])
    }

    func testHeartbeatBodyDefaultsSendHandleToNilWhenOmittedEntirely() {
        // Existing call sites (CRMSyncHeartbeatTests, and sendHeartbeat()
        // pre-this-change) never pass sendHandle at all — the parameter
        // must default to nil rather than becoming a required argument.
        let body = CRMSyncService.heartbeatBody(
            config: CRMConfig(),
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )

        XCTAssertNil(body["send_handle"])
    }

    // MARK: - ChatDatabase.selectSelfHandle

    private func date(_ secondsFromEpoch: Double) -> Date {
        Date(timeIntervalSince1970: secondsFromEpoch)
    }

    func testSelectSelfHandlePrefersPhoneNumberOverEmail() {
        // Email is MORE recent, but the phone-looking handle must still
        // win — the product ask is specifically "the phone number used on
        // that Mac".
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: "+15551234567", lastActivity: date(1000)),
            (handle: "me@icloud.com", lastActivity: date(2000)),
        ]

        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "+15551234567")
    }

    func testSelectSelfHandlePrefersMostRecentAmongSameKind() {
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: "+15551234567", lastActivity: date(1000)),
            (handle: "+15559876543", lastActivity: date(5000)),
            (handle: "+15550001111", lastActivity: date(3000)),
        ]

        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "+15559876543")
    }

    func testSelectSelfHandlePrefersMostRecentEmailWhenNoPhoneCandidate() {
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: "old@icloud.com", lastActivity: date(1000)),
            (handle: "new@icloud.com", lastActivity: date(5000)),
        ]

        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "new@icloud.com")
    }

    func testSelectSelfHandleSkipsEmptyAndNilHandles() {
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: nil, lastActivity: date(9000)),
            (handle: "", lastActivity: date(8000)),
            (handle: "   ", lastActivity: date(7000)),
            (handle: "+15551234567", lastActivity: date(1000)),
        ]

        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "+15551234567")
    }

    func testSelectSelfHandleReturnsNilWhenAllCandidatesEmpty() {
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: nil, lastActivity: date(1000)),
            (handle: "", lastActivity: date(2000)),
        ]

        XCTAssertNil(ChatDatabase.selectSelfHandle(from: candidates))
    }

    func testSelectSelfHandleReturnsNilForEmptyCandidateList() {
        XCTAssertNil(ChatDatabase.selectSelfHandle(from: []))
    }

    func testSelectSelfHandleFallsBackToMostCommonOnRecencyTie() {
        // Three candidates tied at the same most-recent timestamp: no
        // single "most recent" winner, so the most frequently occurring
        // value in the tied set breaks the tie.
        let tied = date(5000)
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: "+15551234567", lastActivity: tied),
            (handle: "+15551234567", lastActivity: tied),
            (handle: "+15559876543", lastActivity: tied),
        ]

        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "+15551234567")
    }

    func testTieAtNewestNeverLosesToOlderButMoreCommonHandle() {
        // Codex P2 regression: frequency must be counted among the TIED
        // NEWEST candidates only — an older handle repeated three times
        // must not beat the two handles tied at the newest timestamp.
        let newest = date(9000)
        let older = date(1000)
        let candidates: [(handle: String?, lastActivity: Date)] = [
            (handle: "+15550001111", lastActivity: newest),
            (handle: "+15559998888", lastActivity: newest),
            (handle: "+15553334444", lastActivity: older),
            (handle: "+15553334444", lastActivity: older),
            (handle: "+15553334444", lastActivity: older),
        ]

        // Tie among the newest resolves alphabetically within that set.
        XCTAssertEqual(ChatDatabase.selectSelfHandle(from: candidates), "+15550001111")
    }
}
