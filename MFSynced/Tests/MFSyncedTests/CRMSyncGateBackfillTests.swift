import XCTest
@testable import MFSynced

/// Tests for `CRMSyncService.gateBackfillTargets` — the pure diff + dedup
/// helper behind S3b's completeness backstop: when the server-desired gate
/// (`pullGate()`) gains a number, the Mac backfills that conversation's full
/// history via the same `syncHistory` path the forward/manual-add flows use,
/// at most once per identifier per session.
///
/// These tests thread the `alreadyBackfilled` Set by hand across simulated
/// "poll ticks" the same way `CRMSyncService.pullGate()` threads its real
/// `backfilledThisSession` property — no network, no chat.db, matching the
/// pure-decision-function pattern used by `catalogUploadDecision` /
/// `stagedRowsPlan` elsewhere in this target.
final class CRMSyncGateBackfillTests: XCTestCase {

    // MARK: - Basic diff

    func testFiresOncePerNewlyAddedNumber() {
        let targets = CRMSyncService.gateBackfillTargets(
            previouslyApplied: ["+1111"],
            desired: ["+1111", "+2222", "+3333"],
            alreadyBackfilled: []
        )
        // +1111 was already applied — only the two genuinely new numbers
        // qualify, one entry each (no duplicates).
        XCTAssertEqual(targets, ["+2222", "+3333"])
    }

    func testEmptyWhenDesiredMatchesPreviouslyApplied() {
        let targets = CRMSyncService.gateBackfillTargets(
            previouslyApplied: ["+1111", "+2222"],
            desired: ["+1111", "+2222"],
            alreadyBackfilled: []
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testExcludesNumbersAlreadyBackfilledThisSession() {
        let targets = CRMSyncService.gateBackfillTargets(
            previouslyApplied: [],
            desired: ["+1111", "+2222"],
            alreadyBackfilled: ["+1111"]
        )
        XCTAssertEqual(targets, ["+2222"])
    }

    func testRemovalAloneNeverProducesATarget() {
        // A number leaving the gate (present in previouslyApplied, absent
        // from desired) must never appear as a backfill target — only
        // additions do.
        let targets = CRMSyncService.gateBackfillTargets(
            previouslyApplied: ["+1111", "+2222"],
            desired: ["+1111"],
            alreadyBackfilled: []
        )
        XCTAssertTrue(targets.isEmpty)
    }

    // MARK: - Simulated pullGate() tick sequences (thread alreadyBackfilled
    // by hand, mirroring CRMSyncService.backfilledThisSession across ticks)

    func testSecondPullGateApplicationWithSameListFiresNothing() {
        var backfilled = Set<String>()

        // Tick 1: gate gains +1111.
        let firstTick = CRMSyncService.gateBackfillTargets(
            previouslyApplied: [], desired: ["+1111"], alreadyBackfilled: backfilled
        )
        XCTAssertEqual(firstTick, ["+1111"])
        backfilled.formUnion(firstTick)

        // Tick 2: server returns the SAME desired list again (no change).
        // previouslyApplied is now what tick 1 applied ({+1111}).
        let secondTick = CRMSyncService.gateBackfillTargets(
            previouslyApplied: ["+1111"], desired: ["+1111"], alreadyBackfilled: backfilled
        )
        XCTAssertTrue(secondTick.isEmpty, "must not re-fire while the number stays gated")
    }

    func testNumberReAddedAfterRemovalDoesNotRefire_neverClearPolicy() {
        // Documented choice (see CRMSyncService.backfilledThisSession): the
        // dedup set is NEVER cleared on removal, so a number that leaves and
        // later re-enters the gate does not get backfilled a second time —
        // its full history was already captured the first time.
        var backfilled = Set<String>()

        let addedTick = CRMSyncService.gateBackfillTargets(
            previouslyApplied: [], desired: ["+1111"], alreadyBackfilled: backfilled
        )
        XCTAssertEqual(addedTick, ["+1111"])
        backfilled.formUnion(addedTick)

        // Removal tick: +1111 drops out of desired. gateBackfillTargets
        // itself is never even consulted for pure removals in production
        // (pullGate only calls it after applying the diff), but backfilled
        // is untouched either way per the never-clear policy.

        // Re-added tick: +1111 comes back. previouslyApplied reflects the
        // gate's state just before this tick (empty, since it had been
        // removed), desired has it again.
        let reAddedTick = CRMSyncService.gateBackfillTargets(
            previouslyApplied: [], desired: ["+1111"], alreadyBackfilled: backfilled
        )
        XCTAssertTrue(reAddedTick.isEmpty, "already backfilled this session — must not refire on re-add")
    }

    func testLocallyAddedThenServerConfirmedNumberDoesNotDoubleFire() {
        // Simulates the requestGateAdd ordering (sidebar right-click add, or
        // pullOutbound's auto-enable-on-send): requestGateAdd's own
        // mutateConfig call applies the server-confirmed set to the
        // service's config as soon as its HTTP round trip completes — well
        // before the next timer-driven pullGate() tick. So by the time
        // pullGate() runs its diff, `current` (previouslyApplied here)
        // ALREADY contains the locally-added number; it can never look
        // "newly added" to the gate diff, so no backfill fires for it via
        // this path.
        let targets = CRMSyncService.gateBackfillTargets(
            previouslyApplied: ["+1111"],  // already applied by requestGateAdd's mutateConfig
            desired: ["+1111"],            // server's list, now consistent with the local add
            alreadyBackfilled: []
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testMultipleNewNumbersEachAppearExactlyOnceAcrossTicks() {
        // A three-tick sequence: gate gains two numbers on tick 1, one more
        // on tick 2, nothing on tick 3 — every identifier must appear in
        // exactly one tick's target list, never twice.
        var backfilled = Set<String>()
        var applied = Set<String>()
        var allFired: [String] = []

        func tick(_ desired: Set<String>) {
            let targets = CRMSyncService.gateBackfillTargets(
                previouslyApplied: applied, desired: desired, alreadyBackfilled: backfilled
            )
            allFired.append(contentsOf: targets)
            backfilled.formUnion(targets)
            applied = desired
        }

        tick(["+1111", "+2222"])
        tick(["+1111", "+2222", "+3333"])
        tick(["+1111", "+2222", "+3333"])  // unchanged — nothing new

        XCTAssertEqual(allFired.sorted(), ["+1111", "+2222", "+3333"])
    }
}
