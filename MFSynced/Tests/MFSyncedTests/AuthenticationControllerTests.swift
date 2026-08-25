import XCTest
@testable import MFSynced

private actor FakeAuthSessionClient: AuthSessionClient {
    enum Behavior {
        case succeed(AuthenticatedSession)
        case succeedAfterCancellingCaller(AuthenticatedSession)
        case fail(Error)
        case waitForCancellation
    }

    var validationBehavior: Behavior
    var signInBehavior: Behavior
    private(set) var signOutCount = 0

    init(
        validationBehavior: Behavior,
        signInBehavior: Behavior = .succeed(AuthenticatedSession(email: nil))
    ) {
        self.validationBehavior = validationBehavior
        self.signInBehavior = signInBehavior
    }

    func validatedSession() async throws -> AuthenticatedSession {
        try await resolve(validationBehavior)
    }

    func signIn() async throws {
        _ = try await resolve(signInBehavior)
    }

    func signOut() async throws {
        signOutCount += 1
    }

    private func resolve(_ behavior: Behavior) async throws -> AuthenticatedSession {
        switch behavior {
        case .succeed(let session):
            return session
        case .succeedAfterCancellingCaller(let session):
            withUnsafeCurrentTask { $0?.cancel() }
            return session
        case .fail(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return AuthenticatedSession(email: nil)
        }
    }
}

private actor BlockingSignOutClient: AuthSessionClient {
    private var signOutContinuation: CheckedContinuation<Void, Error>?

    func validatedSession() async throws -> AuthenticatedSession {
        AuthenticatedSession(email: "verified@example.com")
    }

    func signIn() async throws {}

    func signOut() async throws {
        try await withCheckedThrowingContinuation { continuation in
            signOutContinuation = continuation
        }
    }

    var isSignOutPending: Bool { signOutContinuation != nil }

    func finishSignOut() {
        signOutContinuation?.resume()
        signOutContinuation = nil
    }
}

private actor RevalidationRaceClient: AuthSessionClient {
    private var validationCount = 0
    private var revalidationContinuation: CheckedContinuation<AuthenticatedSession, Error>?

    func validatedSession() async throws -> AuthenticatedSession {
        validationCount += 1
        if validationCount == 1 {
            return AuthenticatedSession(email: "verified@example.com")
        }
        return try await withCheckedThrowingContinuation { continuation in
            revalidationContinuation = continuation
        }
    }

    func signIn() async throws {}
    func signOut() async throws {}

    var isRevalidationPending: Bool { revalidationContinuation != nil }

    func finishRevalidation() {
        revalidationContinuation?.resume(
            returning: AuthenticatedSession(email: "stale@example.com")
        )
        revalidationContinuation = nil
    }
}

private actor FailingSignOutClient: AuthSessionClient {
    enum CleanupError: Error { case denied }
    private(set) var validationCount = 0

    func validatedSession() async throws -> AuthenticatedSession {
        validationCount += 1
        return AuthenticatedSession(email: "verified@example.com")
    }

    func signIn() async throws {}
    func signOut() async throws { throw CleanupError.denied }
}

final class AuthenticationControllerTests: XCTestCase {
    @MainActor
    func testStartupBeginsPrivacyClosedAndSignedOutValidationKeepsSensitiveContentHidden() async {
        let client = FakeAuthSessionClient(validationBehavior: .fail(AuthService.AuthError.signedOut))
        let controller = AuthenticationController(client: client)

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(AuthenticatedContentMode.resolve(for: controller.state), .authenticationOnly)

        await controller.validateStartupSession()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertFalse(controller.state.allowsSensitiveContent)
        XCTAssertEqual(AuthenticatedContentMode.resolve(for: controller.state), .authenticationOnly)
    }

    @MainActor
    func testValidatedStartupSessionUnlocksSensitiveApplication() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .succeed(AuthenticatedSession(email: "person@example.com"))
        )
        let controller = AuthenticationController(client: client)

        await controller.validateStartupSession()

        XCTAssertEqual(controller.state, .authenticated(email: "person@example.com"))
        XCTAssertTrue(controller.state.allowsSensitiveContent)
        XCTAssertEqual(AuthenticatedContentMode.resolve(for: controller.state), .sensitiveApplication)
    }

    @MainActor
    func testEveryUnconfirmedStateUsesAuthenticationOnlyRendering() {
        let states: [AuthenticationState] = [
            .checking,
            .signedOut,
            .signingIn,
            .failed(message: "network unavailable"),
            .signOutFailed(message: "cleanup denied"),
            .cancelled,
            .signingOut,
        ]

        for state in states {
            XCTAssertFalse(state.allowsSensitiveContent, "state unexpectedly exposed sensitive content: \(state)")
            XCTAssertEqual(AuthenticatedContentMode.resolve(for: state), .authenticationOnly)
        }
    }

    @MainActor
    func testLockForAuthenticationClearsCachedDisplayStateAndLegacySensitiveLogs() throws {
        let controller = AuthenticationController(
            client: FakeAuthSessionClient(validationBehavior: .fail(AuthService.AuthError.signedOut))
        )
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFSynced-PrivacyLogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logsDirectory) }

        let appState = AppState(authentication: controller, logsDirectory: logsDirectory)
        var cachedConfig = CRMConfig()
        cachedConfig.ownerEmail = "private@example.com"
        cachedConfig.apiKey = "synthetic-legacy-value"
        cachedConfig.syncedPhoneNumbers = ["+15550000000"]
        appState.crmConfig = cachedConfig
        let sensitiveFiles = [
            "mfsynced_messages.txt",
            "mfsynced_conversations.txt",
            "mfsynced_crm.log",
        ]
        for filename in sensitiveFiles {
            try Data("synthetic private fixture".utf8).write(
                to: logsDirectory.appendingPathComponent(filename)
            )
        }
        let unrelatedFile = logsDirectory.appendingPathComponent("unrelated.log")
        try Data("keep".utf8).write(to: unrelatedFile)
        SensitiveDiagnostics.setEnabled(true)
        SensitiveDiagnostics.record("synthetic private fixture", bufferForFleet: true)
        XCTAssertGreaterThan(FleetLogBuffer.shared.count, 0)
        appState.searchText = "cached private history"
        appState.isSearching = true
        appState.dbError = "cached error containing a local path"

        appState.lockForAuthentication()

        XCTAssertTrue(appState.conversations.isEmpty)
        XCTAssertNil(appState.selectedConversation)
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertTrue(appState.searchText.isEmpty)
        XCTAssertTrue(appState.searchResults.isEmpty)
        XCTAssertFalse(appState.isSearching)
        XCTAssertNil(appState.dbError)
        XCTAssertTrue(appState.crmConfig.ownerEmail.isEmpty)
        XCTAssertTrue(appState.crmConfig.apiKey.isEmpty)
        XCTAssertTrue(appState.crmConfig.syncedPhoneNumbers.isEmpty)
        XCTAssertEqual(FleetLogBuffer.shared.count, 0)
        for filename in sensitiveFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: logsDirectory.appendingPathComponent(filename).path
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @MainActor
    func testSearchCannotReadMessagesWhileAuthenticationIsUnconfirmed() {
        let controller = AuthenticationController(
            client: FakeAuthSessionClient(validationBehavior: .fail(AuthService.AuthError.signedOut))
        )
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFSynced-LockedSearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logsDirectory) }
        let appState = AppState(
            authentication: controller,
            logsDirectory: logsDirectory
        )
        appState.searchText = "private query"

        appState.performSearch()

        XCTAssertFalse(appState.isSearching)
        XCTAssertTrue(appState.searchResults.isEmpty)
    }

    @MainActor
    func testAuthRefreshCannotReloadCRMConfigWhileLocked() {
        var persisted = CRMConfig()
        persisted.ownerEmail = "synthetic-owner@example.com"
        persisted.apiKey = "synthetic-legacy-key"
        persisted.syncedPhoneNumbers = ["+15551234567"]
        persisted.save()
        defer {
            var cleared = CRMConfig.load()
            cleared.ownerEmail = ""
            cleared.apiKey = ""
            cleared.syncedPhoneNumbers = []
            cleared.save()
        }

        let controller = AuthenticationController(
            client: FakeAuthSessionClient(validationBehavior: .fail(AuthService.AuthError.signedOut))
        )
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFSynced-LockedCRMRefresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logsDirectory) }
        let appState = AppState(authentication: controller, logsDirectory: logsDirectory)

        appState.lockForAuthentication()
        appState.refreshCRMConfigAfterAuthChange()

        XCTAssertTrue(appState.crmConfig.ownerEmail.isEmpty)
        XCTAssertTrue(appState.crmConfig.apiKey.isEmpty)
        XCTAssertTrue(appState.crmConfig.syncedPhoneNumbers.isEmpty)
    }

    func testPurgedDiagnosticsCannotBeRequeuedByAnInFlightUpload() throws {
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFSynced-RequeueLogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer {
            SensitiveDiagnostics.purge()
            try? FileManager.default.removeItem(at: logsDirectory)
        }

        SensitiveDiagnostics.configure(logsDirectory: logsDirectory)
        SensitiveDiagnostics.setEnabled(true)
        SensitiveDiagnostics.record("synthetic private fixture", bufferForFleet: true)
        let drained = FleetLogBuffer.shared.drain(max: 200)
        XCTAssertFalse(drained.isEmpty)

        SensitiveDiagnostics.purge()
        SensitiveDiagnostics.requeue(drained)

        XCTAssertEqual(FleetLogBuffer.shared.count, 0)
    }

    @MainActor
    func testExplicitSignInUnlocksOnlyAfterPostSignInValidation() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .succeed(AuthenticatedSession(email: "verified@example.com"))
        )
        let controller = AuthenticationController(client: client)

        await controller.signIn()

        XCTAssertEqual(controller.state, .authenticated(email: "verified@example.com"))
        XCTAssertTrue(controller.state.allowsSensitiveContent)
    }

    @MainActor
    func testCancellationRacingPersistedSuccessDoesNotReportFalseCancellation() async {
        let session = AuthenticatedSession(email: "verified@example.com")
        let client = FakeAuthSessionClient(
            validationBehavior: .succeed(session),
            signInBehavior: .succeedAfterCancellingCaller(session)
        )
        let controller = AuthenticationController(client: client)

        let task = Task { await controller.signIn() }
        await task.value

        XCTAssertEqual(controller.state, .authenticated(email: "verified@example.com"))
        XCTAssertTrue(controller.state.allowsSensitiveContent)
    }

    @MainActor
    func testSignInCancellationRemainsLockedAndIsUnambiguous() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .fail(AuthService.AuthError.signedOut),
            signInBehavior: .waitForCancellation
        )
        let controller = AuthenticationController(client: client)
        let task = Task { await controller.signIn() }
        await Task.yield()

        XCTAssertEqual(controller.state, .signingIn)
        XCTAssertFalse(controller.state.allowsSensitiveContent)

        task.cancel()
        await task.value

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertFalse(controller.state.allowsSensitiveContent)
    }

    @MainActor
    func testAnyGateCanCancelControllerOwnedSignIn() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .fail(AuthService.AuthError.signedOut),
            signInBehavior: .waitForCancellation
        )
        let controller = AuthenticationController(client: client)

        controller.startSignIn()
        XCTAssertEqual(controller.state, .signingIn)
        XCTAssertNotNil(controller.signInStartedAt)

        controller.cancelSignIn()
        await Task.yield()

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertNil(controller.signInStartedAt)
        XCTAssertFalse(controller.state.allowsSensitiveContent)
    }

    @MainActor
    func testTimeoutFailureRemainsLockedAndShowsSpecificReason() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .fail(AuthService.AuthError.signedOut),
            signInBehavior: .fail(AuthService.AuthError.signInTimedOut)
        )
        let controller = AuthenticationController(client: client)

        await controller.signIn()

        guard case .failed(let message) = controller.state else {
            return XCTFail("expected failed state, got \(controller.state)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("timed out"), message)
        XCTAssertFalse(controller.state.allowsSensitiveContent)
    }

    @MainActor
    func testSignOutClosesGate() async {
        let client = FakeAuthSessionClient(
            validationBehavior: .succeed(AuthenticatedSession(email: nil))
        )
        let controller = AuthenticationController(client: client)
        await controller.validateStartupSession()
        XCTAssertTrue(controller.state.allowsSensitiveContent)

        await controller.signOut()

        XCTAssertEqual(controller.state, .signedOut)
        let signOutCount = await client.signOutCount
        XCTAssertEqual(signOutCount, 1)
    }

    @MainActor
    func testSignOutClosesGateBeforeCredentialCleanupFinishes() async {
        let client = BlockingSignOutClient()
        let controller = AuthenticationController(client: client)
        await controller.validateStartupSession()
        XCTAssertTrue(controller.state.allowsSensitiveContent)

        let signOut = Task { await controller.signOut() }
        while !(await client.isSignOutPending) { await Task.yield() }

        XCTAssertEqual(controller.state, .signingOut)
        XCTAssertFalse(controller.state.allowsSensitiveContent)

        await client.finishSignOut()
        await signOut.value
        XCTAssertEqual(controller.state, .signedOut)
    }

    @MainActor
    func testSignOutCleanupFailureStaysLockedAndRequiresFreshSignIn() async {
        let client = FailingSignOutClient()
        let controller = AuthenticationController(client: client)
        await controller.validateStartupSession()
        XCTAssertTrue(controller.state.allowsSensitiveContent)

        await controller.signOut()

        guard case .signOutFailed(let message) = controller.state else {
            return XCTFail("expected dedicated sign-out cleanup failure, got \(controller.state)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("fresh session"), message)
        XCTAssertFalse(controller.state.allowsSensitiveContent)

        await controller.retryValidation()
        let validationCount = await client.validationCount
        XCTAssertEqual(validationCount, 1)
        guard case .signOutFailed = controller.state else {
            return XCTFail("cleanup failure must not validate surviving credentials")
        }
    }

    @MainActor
    func testDelayedRevalidationCannotReopenGateAfterSignOut() async {
        let client = RevalidationRaceClient()
        let controller = AuthenticationController(client: client)
        await controller.validateStartupSession()

        let revalidation = Task { await controller.revalidateAuthenticatedSession() }
        while !(await client.isRevalidationPending) { await Task.yield() }

        await controller.signOut()
        XCTAssertEqual(controller.state, .signedOut)

        await client.finishRevalidation()
        await revalidation.value

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertFalse(controller.state.allowsSensitiveContent)
    }
}
