import Foundation
import Observation

struct AuthenticatedSession: Equatable, Sendable {
    let email: String?
}

protocol AuthSessionClient: Sendable {
    func validatedSession() async throws -> AuthenticatedSession
    func signIn() async throws
    func signOut() async throws
}

enum AuthenticationState: Equatable, Sendable {
    case checking
    case signedOut
    case signingIn
    case authenticated(email: String?)
    case failed(message: String)
    case signOutFailed(message: String)
    case cancelled
    case signingOut

    /// The single privacy decision used by both application scenes and by
    /// AppState's polling lifecycle. Only a freshly validated session may
    /// reveal conversations, messages, or prior sync configuration.
    var allowsSensitiveContent: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var authenticatedEmail: String? {
        guard case .authenticated(let email) = self else { return nil }
        return email
    }
}

enum AuthenticatedContentMode: Equatable {
    case authenticationOnly
    case sensitiveApplication

    static func resolve(for state: AuthenticationState) -> Self {
        state.allowsSensitiveContent ? .sensitiveApplication : .authenticationOnly
    }
}

@MainActor
@Observable
final class AuthenticationController {
    private(set) var state: AuthenticationState = .checking
    /// Process-wide start time for the one controller-owned browser flow.
    /// Every authentication gate reads the same value, so opening a second
    /// window cannot produce a fresh or frozen countdown.
    private(set) var signInStartedAt: Date?

    private let client: any AuthSessionClient
    private var didValidateStartup = false
    private var signInTask: Task<Void, Never>?
    /// Main-actor operation version. Any authentication request that starts
    /// later invalidates the result of an earlier suspended request, so a
    /// delayed refresh can never reopen the gate after Sign Out.
    private var operationVersion: UInt64 = 0

    init(client: any AuthSessionClient = AuthService.shared) {
        self.client = client
    }

    /// Runs exactly once for the process startup. The initial `.checking`
    /// state is intentionally privacy-closed, so SwiftUI never constructs
    /// the sensitive application subtree while this awaits Keychain/network.
    func validateStartupSession() async {
        guard !didValidateStartup else { return }
        didValidateStartup = true
        let version = beginOperation()
        await validateSession(showCheckingState: true, version: version)
    }

    func retryValidation() async {
        // A failed sign-out may have left an old Keychain item behind. Never
        // validate that item back into an authenticated state; only a fresh
        // interactive authorization may unlock the app again.
        if case .signOutFailed = state { return }
        let version = beginOperation()
        await validateSession(showCheckingState: true, version: version)
    }

    /// Revalidates an already-visible session. A refresh failure closes the
    /// gate immediately rather than leaving a stale green status visible.
    func revalidateAuthenticatedSession() async {
        guard state.allowsSensitiveContent else { return }
        let version = beginOperation()
        await validateSession(showCheckingState: false, version: version)
    }

    /// Starts the one process-wide interactive sign-in. Every window calls
    /// this controller-owned entry point, so any gate can cancel the same
    /// underlying task instead of holding a view-local handle.
    func startSignIn() {
        guard state != .signingIn else { return }
        let version = beginOperation()
        signInStartedAt = Date()
        state = .signingIn
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            await self?.performSignIn(version: version)
            guard let self, self.isCurrent(version) else { return }
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        guard state == .signingIn else { return }
        _ = beginOperation()
        signInStartedAt = nil
        state = .cancelled
        signInTask?.cancel()
        signInTask = nil
    }

    /// Awaitable convenience retained for deterministic tests. It still
    /// routes through the controller-owned task so cross-window cancellation
    /// has exactly one authority in production and tests.
    func signIn() async {
        startSignIn()
        let task = signInTask
        await withTaskCancellationHandler(operation: {
            await task?.value
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelSignIn() }
        })
    }

    private func performSignIn(version: UInt64) async {
        do {
            try Task.checkCancellation()
            try await client.signIn()
            // Once signIn() returns, the code exchange and token persistence
            // have completed. A cancel click racing that exact boundary must
            // not report cancellation after the browser has truthfully shown
            // success; validate the persisted session and publish it.
            let session = try await client.validatedSession()
            guard isCurrent(version) else { return }
            signInStartedAt = nil
            state = .authenticated(email: session.email)
        } catch is CancellationError {
            guard isCurrent(version) else { return }
            signInStartedAt = nil
            state = .cancelled
        } catch AuthService.AuthError.authorizationCancelled {
            guard isCurrent(version) else { return }
            signInStartedAt = nil
            state = .cancelled
        } catch {
            guard isCurrent(version) else { return }
            signInStartedAt = nil
            state = .failed(message: "Sign-in failed: \(error.localizedDescription)")
        }
    }

    func signOut() async {
        let version = beginOperation()
        signInTask?.cancel()
        signInTask = nil
        signInStartedAt = nil
        // Close the privacy gate synchronously, before Keychain I/O can
        // suspend. This also prevents a second sign-in from racing cleanup.
        state = .signingOut
        do {
            try await client.signOut()
            guard isCurrent(version) else { return }
            state = .signedOut
        } catch {
            guard isCurrent(version) else { return }
            state = .signOutFailed(
                message: "Sign-out cleanup failed: \(error.localizedDescription). "
                    + "Phone Sync remains locked. Sign in again to create a fresh session."
            )
        }
    }

    private func validateSession(showCheckingState: Bool, version: UInt64) async {
        if showCheckingState { state = .checking }
        do {
            let session = try await client.validatedSession()
            guard isCurrent(version) else { return }
            state = .authenticated(email: session.email)
        } catch AuthService.AuthError.signedOut {
            guard isCurrent(version) else { return }
            state = .signedOut
        } catch {
            guard isCurrent(version) else { return }
            state = .failed(message: "Could not verify your Moon Five session: \(error.localizedDescription)")
        }
    }

    private func beginOperation() -> UInt64 {
        operationVersion &+= 1
        return operationVersion
    }

    private func isCurrent(_ version: UInt64) -> Bool {
        operationVersion == version
    }
}
