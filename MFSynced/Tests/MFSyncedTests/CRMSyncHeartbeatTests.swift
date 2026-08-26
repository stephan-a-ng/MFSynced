import XCTest
@testable import MFSynced

private actor ManualHeartbeatSleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
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

private actor HeartbeatRecorder {
    private(set) var count = 0

    func record() { count += 1 }
}

private actor BlockingHeartbeatRecorder {
    private(set) var starts = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func attempt() async {
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        active -= 1
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

final class CRMSyncHeartbeatTests: XCTestCase {
    private func makeService() -> CRMSyncService {
        var config = CRMConfig()
        config.isEnabled = true
        config.apiEndpoint = "http://127.0.0.1:1/v1/agent"
        config.apiKey = "test"
        let service = CRMSyncService(config: config, authService: .legacyCompatibilityFixture())
        // startPolling() now owns a real async loop instead of a main-run-loop
        // Timer. Keep heartbeat lifecycle tests from touching production-like
        // sync storage/network when their five-second interval elapses.
        service.pollAttemptOverride = {}
        return service
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

    func testHeartbeatBodyIncludesOwnerEmailWhenSet() {
        var config = CRMConfig()
        config.ownerEmail = "owner@moonfive.tech"

        let body = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )

        XCTAssertEqual(body["owner_email"] as? String, "owner@moonfive.tech")
    }

    func testHeartbeatBodyOmitsOwnerEmailWhenBlank() {
        var config = CRMConfig()
        config.ownerEmail = "   "

        let body = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )

        XCTAssertNil(body["owner_email"])

        config.ownerEmail = ""
        let emptyBody = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )
        XCTAssertNil(emptyBody["owner_email"])
    }

    func testHeartbeatBodyOmitsHistoryCapabilityWithoutProvider() {
        let body = CRMSyncService.heartbeatBody(
            config: CRMConfig(),
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil,
            reviewHistoryAvailable: false
        )
        let capabilities = body["capabilities"] as? [String]
        XCTAssertEqual(capabilities, ["inbound_reactions_v1"])
    }

    func testHeartbeatBodyReportsTheSanitizedPollInterval() {
        var config = CRMConfig()
        config.pollIntervalSeconds = 1e20
        let hugeBody = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )
        XCTAssertEqual(hugeBody["poll_interval_seconds"] as? Int, 3_600)

        config.pollIntervalSeconds = .nan
        let nonFiniteBody = CRMSyncService.heartbeatBody(
            config: config,
            hostname: "test-host",
            osVersion: "test-os",
            uptimeSeconds: 10,
            appVersion: nil
        )
        XCTAssertEqual(nonFiniteBody["poll_interval_seconds"] as? Int, 5)
    }

    func testHeartbeatLoopSendsImmediatelyRepeatsStopsAndRestarts() async {
        let service = makeService()
        let sleeper = ManualHeartbeatSleeper()
        let recorder = HeartbeatRecorder()
        service.heartbeatAttemptOverride = { await recorder.record() }
        service.heartbeatSleepOverride = { _ in try await sleeper.sleep() }

        service.startHeartbeatLoop()
        let sentImmediately = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 1 && waiting == 1
        }
        XCTAssertTrue(sentImmediately)

        await sleeper.resumeOne()
        let repeated = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 2 && waiting == 1
        }
        XCTAssertTrue(repeated)

        service.stopPolling()
        await sleeper.resumeAll()
        for _ in 0..<100 { await Task.yield() }
        let stoppedCount = await recorder.count
        XCTAssertEqual(stoppedCount, 2)

        service.startPolling()
        let restarted = await eventually {
            let count = await recorder.count
            let waiting = await sleeper.waitingCount
            return count == 3 && waiting == 1
        }
        XCTAssertTrue(restarted)
        service.stopPolling()
        await sleeper.resumeAll()
    }

    func testStoppedServiceCannotStartAHeartbeatLoopDirectly() async {
        let service = makeService()
        let recorder = HeartbeatRecorder()
        service.heartbeatAttemptOverride = { await recorder.record() }

        service.stopPolling()
        service.startHeartbeatLoop()
        for _ in 0..<500 { await Task.yield() }

        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testHeartbeatLoopNeverOverlapsAttempts() async {
        let service = makeService()
        let sleeper = ManualHeartbeatSleeper()
        let recorder = BlockingHeartbeatRecorder()
        service.heartbeatAttemptOverride = { await recorder.attempt() }
        service.heartbeatSleepOverride = { _ in try await sleeper.sleep() }

        service.startHeartbeatLoop()
        let firstStarted = await eventually { await recorder.starts == 1 }
        XCTAssertTrue(firstStarted)
        // A repeated start (for example, a config refresh) keeps the one
        // existing loop instead of launching an overlapping immediate POST.
        service.startHeartbeatLoop()
        for _ in 0..<500 { await Task.yield() }
        let firstStarts = await recorder.starts
        let firstMaximum = await recorder.maximumActive
        XCTAssertEqual(firstStarts, 1)
        XCTAssertEqual(firstMaximum, 1)

        await recorder.releaseOne()
        let enteredSleep = await eventually { await sleeper.waitingCount == 1 }
        XCTAssertTrue(enteredSleep)
        await sleeper.resumeOne()
        let secondStarted = await eventually { await recorder.starts == 2 }
        XCTAssertTrue(secondStarted)
        let secondMaximum = await recorder.maximumActive
        XCTAssertEqual(secondMaximum, 1)

        // A real stop/restart must also wait for cooperative cancellation of
        // the retiring attempt before sending the new immediate heartbeat.
        service.stopPolling()
        service.startPolling()
        for _ in 0..<500 { await Task.yield() }
        let startsBeforeRelease = await recorder.starts
        XCTAssertEqual(startsBeforeRelease, 2)
        await recorder.releaseOne()
        let thirdStarted = await eventually { await recorder.starts == 3 }
        XCTAssertTrue(thirdStarted)
        let restartMaximum = await recorder.maximumActive
        XCTAssertEqual(restartMaximum, 1)

        service.stopPolling()
        await recorder.releaseOne()
        await sleeper.resumeAll()
    }

    func testHeartbeatDeadlineCancelsAttemptAndContinuesLoop() async {
        let service = makeService()
        let intervalSleeper = ManualHeartbeatSleeper()
        let timeoutSleeper = ManualHeartbeatSleeper()
        let recorder = HeartbeatRecorder()
        service.heartbeatAttemptOverride = {
            await recorder.record()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        service.heartbeatSleepOverride = { _ in try await intervalSleeper.sleep() }
        service.heartbeatTimeoutSleepOverride = { _ in try await timeoutSleeper.sleep() }

        service.startHeartbeatLoop()
        let firstAttemptWaiting = await eventually {
            let count = await recorder.count
            let timeoutWaiters = await timeoutSleeper.waitingCount
            return count == 1 && timeoutWaiters == 1
        }
        XCTAssertTrue(firstAttemptWaiting)

        await timeoutSleeper.resumeOne()
        let intervalWaiting = await eventually { await intervalSleeper.waitingCount == 1 }
        XCTAssertTrue(intervalWaiting, "the timed-out attempt must yield to the interval")
        await intervalSleeper.resumeOne()

        let secondAttemptStarted = await eventually { await recorder.count == 2 }
        XCTAssertTrue(secondAttemptStarted)
        service.stopPolling()
        await timeoutSleeper.resumeAll()
        await intervalSleeper.resumeAll()
    }
}
