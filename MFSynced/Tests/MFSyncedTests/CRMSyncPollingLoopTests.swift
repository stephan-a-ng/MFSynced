import XCTest
@testable import MFSynced

private actor ManualPollSleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var requestedDurations: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            requestedDurations.append(nanoseconds)
            waiters.append(continuation)
        }
    }

    var waitingCount: Int { waiters.count }

    func resumeOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PollRecorder {
    private(set) var count = 0
    private(set) var mainThreadObservations: [Bool] = []

    func record(isMainThread: Bool = Thread.isMainThread) {
        count += 1
        mainThreadObservations.append(isMainThread)
    }
}

final class CRMSyncPollingLoopTests: XCTestCase {
    private func makeService(intervalSeconds: TimeInterval = 5) -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        config.pollIntervalSeconds = intervalSeconds
        return CRMSyncService(config: config, authService: .legacyCompatibilityFixture())
    }

    private func eventually(
        _ condition: @escaping () async -> Bool,
        iterations: Int = 10_000
    ) async -> Bool {
        for _ in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    func testPollingLoopRunsWithoutDrivingTheMainRunLoopAndRepeatsSerially() async {
        let service = makeService()
        let sleeper = ManualPollSleeper()
        let recorder = PollRecorder()
        service.pollSleepOverride = { duration in try await sleeper.sleep(nanoseconds: duration) }
        service.pollAttemptOverride = { await recorder.record() }
        service.heartbeatAttemptOverride = {}

        service.startPolling()
        let waitingForFirstInterval = await eventually { await sleeper.waitingCount == 1 }
        XCTAssertTrue(waitingForFirstInterval)
        let countBeforeFirstInterval = await recorder.count
        XCTAssertEqual(countBeforeFirstInterval, 0)

        var updatedConfig = CRMConfig()
        updatedConfig.isEnabled = true
        updatedConfig.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        updatedConfig.apiKey = "test"
        updatedConfig.pollIntervalSeconds = 2
        service.updateConfig(updatedConfig)
        await sleeper.resumeOne()
        let firstPollFinished = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 1 && waiting == 1
        }
        XCTAssertTrue(firstPollFinished)
        let firstDurations = await sleeper.requestedDurations
        let firstThreadObservations = await recorder.mainThreadObservations
        XCTAssertEqual(firstDurations.first, 5_000_000_000)
        XCTAssertEqual(firstDurations.dropFirst().first, 2_000_000_000)
        XCTAssertEqual(firstThreadObservations, [false])

        await sleeper.resumeOne()
        let secondPollFinished = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 2 && waiting == 1
        }
        XCTAssertTrue(secondPollFinished)

        service.stopPolling()
        await sleeper.resumeAll()
    }

    func testRepeatedStartReusesTheActiveSerialLoop() async {
        let service = makeService()
        let sleeper = ManualPollSleeper()
        let recorder = PollRecorder()
        service.pollSleepOverride = { duration in try await sleeper.sleep(nanoseconds: duration) }
        service.pollAttemptOverride = { await recorder.record() }
        service.heartbeatAttemptOverride = {}

        service.startPolling()
        let initialLoopWaiting = await eventually { await sleeper.waitingCount == 1 }
        XCTAssertTrue(initialLoopWaiting)

        // Auth reconciliation can call start twice. Reuse the active loop:
        // never cancel an in-flight upload just to reset its cadence.
        service.startPolling()
        for _ in 0..<100 { await Task.yield() }
        let waitingAfterRepeatedStart = await sleeper.waitingCount
        let countAfterRepeatedStart = await recorder.count
        XCTAssertEqual(waitingAfterRepeatedStart, 1)
        XCTAssertEqual(countAfterRepeatedStart, 0)

        await sleeper.resumeOne()
        let activeLoopPolled = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 1 && waiting == 1
        }
        XCTAssertTrue(activeLoopPolled)

        service.stopPolling()
        await sleeper.resumeAll()
    }

    func testStopThenRestartCreatesANewLoopAndStopCancelsRealSleep() async throws {
        let sleeper = ManualPollSleeper()
        let recorder = PollRecorder()
        let service = makeService()
        service.pollSleepOverride = { duration in try await sleeper.sleep(nanoseconds: duration) }
        service.pollAttemptOverride = { await recorder.record() }
        service.heartbeatAttemptOverride = {}

        service.startPolling()
        let firstLoopWaiting = await eventually { await sleeper.waitingCount == 1 }
        XCTAssertTrue(firstLoopWaiting)
        service.stopPolling()
        await sleeper.resumeAll()

        service.startPolling()
        let restartedLoopWaiting = await eventually { await sleeper.waitingCount == 1 }
        XCTAssertTrue(restartedLoopWaiting)
        await sleeper.resumeOne()
        let restartedLoopPolled = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 1 && waiting == 1
        }
        XCTAssertTrue(restartedLoopPolled)
        service.stopPolling()
        await sleeper.resumeAll()

        // Exercise production Task.sleep rather than the manual seam: stop
        // must cancel the wait, not let a delayed poll escape afterward.
        let realSleepService = makeService(intervalSeconds: 1)
        let realSleepRecorder = PollRecorder()
        realSleepService.pollAttemptOverride = { await realSleepRecorder.record() }
        realSleepService.heartbeatAttemptOverride = {}
        realSleepService.startPolling()
        realSleepService.stopPolling()
        try await Task.sleep(nanoseconds: 120_000_000)
        let escapedPollCount = await realSleepRecorder.count
        XCTAssertEqual(escapedPollCount, 0)
    }

    func testPollIntervalSanitizationClampsAndRejectsNonFiniteValues() {
        XCTAssertEqual(CRMSyncService.pollIntervalNanoseconds(seconds: 5), 5_000_000_000)
        XCTAssertEqual(CRMSyncService.pollIntervalNanoseconds(seconds: -10), 1_000_000_000)
        XCTAssertEqual(CRMSyncService.pollIntervalNanoseconds(seconds: 1e12), 3_600_000_000_000)
        XCTAssertEqual(CRMSyncService.pollIntervalNanoseconds(seconds: .nan), 5_000_000_000)
        XCTAssertEqual(CRMSyncService.pollIntervalNanoseconds(seconds: .infinity), 5_000_000_000)
    }

    func testConcurrentStartStopCannotLeaveADeadLoopRegistered() async throws {
        let service = makeService(intervalSeconds: 1)
        let recorder = PollRecorder()
        service.pollAttemptOverride = { await recorder.record() }
        service.pollSleepOverride = { _ in await Task.yield() }
        service.heartbeatAttemptOverride = {}

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        service.startPolling()
                    } else {
                        service.stopPolling()
                    }
                }
            }
        }

        // Establish a known final lifecycle ordering. The last start must
        // publish a live loop even after every preceding interleaving.
        service.stopPolling()
        let countBeforeFinalStart = await recorder.count
        service.startPolling()
        let finalLoopPolled = await eventually {
            await recorder.count > countBeforeFinalStart
        }
        XCTAssertTrue(finalLoopPolled)
        service.stopPolling()
    }

    func testDisabledPollingReopensManualActionLatchWithoutStartingPollLoop() async {
        let service = makeService()
        let pollRecorder = PollRecorder()
        let heartbeatRecorder = PollRecorder()
        service.pollAttemptOverride = { await pollRecorder.record() }
        service.heartbeatAttemptOverride = { await heartbeatRecorder.record() }

        service.stopPolling()
        var disabledConfig = CRMConfig()
        disabledConfig.isEnabled = false
        disabledConfig.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        service.updateConfig(disabledConfig)
        service.startPolling()

        // Direct heartbeat start is a narrow observable probe of the shared
        // stopped latch. The disabled start must reopen that latch for manual
        // actions but must not create an automatic polling loop.
        service.startHeartbeatLoop()
        let heartbeatStarted = await eventually { await heartbeatRecorder.count == 1 }
        let pollCount = await pollRecorder.count
        XCTAssertTrue(heartbeatStarted)
        XCTAssertEqual(pollCount, 0)
        service.stopPolling()
    }
}
