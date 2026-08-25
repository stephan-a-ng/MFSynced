import Foundation
import CryptoKit
import Network
import AppKit

// MARK: - OIDC configuration

/// The Mac agent's OIDC (OpenID Connect) client + loopback redirect shape.
/// Production talks to the Moon Five user-access IdP (identity provider)
/// (see `.production` for the verified prod issuer/client); tests construct
/// their own fixture.
struct OIDCConfiguration {
    let issuer: URL
    let clientID: String
    /// Loopback redirect candidate ports, tried in order at `signIn()` time
    /// — the first one whose listener actually binds wins. AuthURLBuilder
    /// derives `redirect_uri` from this list; `signIn()` narrows it to the
    /// ONE port it actually bound before building the authorize URL, so the
    /// redirect_uri sent to the IdP always matches the listener behind it.
    let redirectURIs: [Int]
    let scope: String

    /// Verified deployment ground truth (2026-08-20): access.moonfive.tech
    /// does not resolve, and users-api.moonfive.tech's tokens still carry
    /// the run.app `iss` — so SERVERS must validate `iss` against the
    /// run.app URL. This CLIENT never checks `iss`, which is what makes
    /// the alias endpoint below safe (and necessary — see its comment).
    static let production = OIDCConfiguration(
        // The CUSTOM-DOMAIN alias, deliberately: some Moon Five networks
        // filter `*.run.app` DNS (moonfive-insight), which silently kills
        // the authorize redirect and the token POST on the raw Cloud Run
        // URL. The alias serves /authorize and /token identically; tokens
        // minted through it still carry the run.app `iss`, which only the
        // SERVER validates — this client never checks `iss`.
        issuer: URL(string: "https://users-api.moonfive.tech")!,
        clientID: "phonesync",
        redirectURIs: [47831, 47832, 47833],
        scope: "openid email profile"
    )
}

/// RFC 7636 §4.1's PKCE (Proof Key for Code Exchange) "unreserved"
/// character set — identical to RFC 3986's unreserved set, so it doubles as
/// `AuthService.formEncode`'s percent-encoding allow-list below. Defined
/// once at file scope so both call sites share the exact same set rather
/// than risking two charsets drifting apart.
private let unreservedCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

// MARK: - PKCE

enum PKCE {
    private static let unreservedCharsetArray = Array(unreservedCharacters)

    /// A 64-character verifier drawn from the PKCE unreserved charset
    /// (RFC 7636 §4.1) via Swift's system (cryptographically secure) RNG
    /// (random number generator).
    static func generateVerifier() -> String {
        String((0..<64).map { _ in unreservedCharsetArray.randomElement()! })
    }

    /// S256 code challenge: base64url(SHA256(verifier)), no padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Authorize URL

enum AuthURLBuilder {
    /// Builds the `/authorize` URL. `redirect_uri` is derived from
    /// `config.redirectURIs` internally — callers that need a SPECIFIC
    /// bound port (`signIn()`, after binding the loopback listener) pass a
    /// config whose `redirectURIs` has already been narrowed to that one
    /// port.
    static func authorizeURL(config: OIDCConfiguration, state: String, codeChallenge: String) -> URL {
        let port = config.redirectURIs.first ?? 47831
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        var components = URLComponents(
            url: config.issuer.appendingPathComponent("authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: config.scope),
        ]
        return components.url!
    }
}

// MARK: - TokenSet

struct TokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    // No custom init here — leave the compiler's automatic memberwise
    // init(accessToken:refreshToken:expiresAt:) in place. The
    // tokenEndpointJSON init lives in the extension below specifically so
    // it doesn't suppress that synthesis (an initializer written directly
    // in the primary declaration would).
}

extension TokenSet {
    private struct TokenEndpointResponse: Decodable {
        let access_token: String
        // Optional: some IdP (identity provider) rotation responses omit
        // `refresh_token` (a policy choice not to reissue it every time) —
        // `init` below carries the PREVIOUS refresh token forward in that
        // case rather than reading an omission as "the refresh token is
        // now empty."
        let refresh_token: String?
        let expires_in: Double
    }

    enum TokenEndpointDecodeError: Error {
        /// The response omitted `refresh_token` AND the caller had no
        /// previous one to carry forward (e.g. the very first code
        /// exchange) — there is truly nothing to persist.
        case missingRefreshToken
    }

    /// Parses a token-endpoint JSON response
    /// (`{access_token, refresh_token, expires_in, ...}`) into a TokenSet,
    /// anchoring `expiresAt` to `now + expires_in`. `previousRefreshToken`
    /// carries the caller's current refresh token forward when the
    /// response omits `refresh_token` (see `TokenEndpointResponse` above).
    init(tokenEndpointJSON data: Data, now: Date, previousRefreshToken: String? = nil) throws {
        let decoded = try JSONDecoder().decode(TokenEndpointResponse.self, from: data)
        guard let refreshToken = decoded.refresh_token ?? previousRefreshToken else {
            throw TokenEndpointDecodeError.missingRefreshToken
        }
        self.init(
            accessToken: decoded.access_token,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(decoded.expires_in)
        )
    }
}

// MARK: - Refresh policy

enum TokenRefreshPolicy {
    /// Refresh this many seconds before actual expiry.
    static let refreshBufferSeconds: TimeInterval = 120

    static func shouldRefresh(_ tokenSet: TokenSet, now: Date) -> Bool {
        now.addingTimeInterval(refreshBufferSeconds) >= tokenSet.expiresAt
    }
}

// MARK: - Token storage

protocol TokenStore {
    func save(_ tokenSet: TokenSet) async throws
    func load() async throws -> TokenSet?
    func clear() async throws
    /// Atomically remove credentials only when they are still the exact
    /// token set supplied by this caller. This prevents a stale operation
    /// from deleting a newer session while recovering from a late write.
    func clear(ifMatching tokenSet: TokenSet) async throws
}

extension TokenStore {
    func clear(ifMatching tokenSet: TokenSet) async throws {
        guard try await load() == tokenSet else { return }
        try await clear()
    }
}

/// Test-only (and safe-default) token store: never touches the system
/// keychain, so unit tests — none of which inject an AuthService — can
/// never race a real signed-in state or a keychain prompt. Production
/// wires KeychainTokenStore explicitly via `AuthService.shared`.
actor InMemoryTokenStore: TokenStore {
    private var stored: TokenSet?

    func save(_ tokenSet: TokenSet) async throws { stored = tokenSet }
    func load() async throws -> TokenSet? { stored }
    func clear() async throws { stored = nil }
    func clear(ifMatching tokenSet: TokenSet) async throws {
        if stored == tokenSet { stored = nil }
    }
}

// MARK: - Loopback callback parsing

enum LoopbackCallbackError: Error, Equatable {
    case malformedRequestLine
    case stateMismatch
    case missingCode
    case authorizationDenied(description: String?)
}

/// Pure parser for the loopback listener's raw HTTP request line
/// (`"GET /callback?code=..&state=.. HTTP/1.1"`). The socket listener
/// itself (`AuthService.signIn()`'s NWListener) is integration surface —
/// untested by design, same convention as this file's live network calls.
enum LoopbackCallback {
    static func parse(requestLine: String, expectedState: String) throws -> String {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: String(parts[1])) else {
            throw LoopbackCallbackError.malformedRequestLine
        }
        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }

        guard let state = value("state"), state == expectedState else {
            throw LoopbackCallbackError.stateMismatch
        }
        if let oauthError = value("error") {
            throw LoopbackCallbackError.authorizationDenied(
                description: value("error_description") ?? oauthError
            )
        }
        guard let code = value("code"), !code.isEmpty else {
            throw LoopbackCallbackError.missingCode
        }
        return code
    }
}

enum BrowserCallbackOutcome: Equatable, Sendable {
    case success
    case failure(String)
}

/// Pure HTTP response builder kept separate from NWConnection so tests can
/// pin the browser's success/failure language without opening a real socket.
enum BrowserCallbackResponse {
    static func httpData(for outcome: BrowserCallbackOutcome) -> Data {
        let title: String
        let detail: String
        switch outcome {
        case .success:
            title = "Phone Sync is signed in"
            detail = "Authentication completed and your session was securely saved. You can close this window."
        case .failure(let message):
            title = "Phone Sync sign-in failed"
            detail = message
        }
        let html = """
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body><h1>\(title)</h1><p>\(detail)</p></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        return response.data(using: .utf8)!
    }
}

// MARK: - Concurrency-safe latches
//
// NWListener/NWConnection callbacks fire on their own dispatch queue, so a
// bare captured `var` "have I already resumed?" flag is a data race under
// Swift 6's strict concurrency checking (Sendable closure captures) — these
// two small lock-guarded boxes replace every such `var` in this file.

/// Thread-safe "first caller wins" latch for a boolean one-shot resume.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Atomically returns true on the FIRST call only; every call after
    /// that returns false.
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

private final class ConnectionReceiveDeadline: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(connection: NWConnection) {
        workItem = DispatchWorkItem { connection.cancel() }
    }

    func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: workItem)
    }

    func cancel() {
        workItem.cancel()
    }
}

/// Coordinates the loopback callback's single completion across (a) many
/// possibly-concurrent inbound connections — only the first one whose
/// request line `LoopbackCallback.parse` accepts should resume, every other
/// connection (a stray probe, e.g. a browser favicon fetch) is closed
/// without resuming — and (b) an external cancellation (the sign-in
/// timeout, or the UI's Cancel button) that can race the socket callback
/// from a different queue. All access goes through one lock so exactly one
/// of "resume with a code" / "cancel" wins, no matter which arrives first
/// or from which thread.
private struct PendingCallback: @unchecked Sendable {
    let code: String
    let connection: NWConnection
}

private final class CallbackCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PendingCallback, Error>?
    private var finished = false
    // A code that arrived BEFORE any continuation attached. The handler is
    // armed before the browser opens (so no callback can be missed), which
    // means an instantly-redirecting IdP session can legitimately deliver
    // the code before signIn() gets around to awaiting it — buffer it
    // rather than dropping it.
    private var bufferedResult: Result<PendingCallback, Error>?
    // The callback socket remains owned here until signIn() explicitly
    // claims it. This covers the task-group boundary where the callback
    // child may finish at the same instant that timeout/cancellation wins
    // group.next(); in that case its returned value is discarded, but the
    // connection is still available for the signIn() defer to close.
    private var unclaimedCallback: PendingCallback?

    /// Stores the continuation this instance will resume exactly once. If
    /// the code already arrived (instant-redirect race), resumes with it
    /// right away; if `cancel()` already fired, resumes immediately with a
    /// `CancellationError` instead of waiting on a socket event a cancelled
    /// sign-in no longer cares about.
    func attach(_ continuation: CheckedContinuation<PendingCallback, Error>) {
        lock.lock()
        if let result = bufferedResult {
            bufferedResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// A connection's request line parsed successfully — resumes with its
    /// code, unless another connection (or a cancellation) already won.
    /// With no continuation attached yet, the code is buffered for the
    /// upcoming `attach`.
    @discardableResult
    func succeed(with callback: PendingCallback) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        unclaimedCallback = callback
        let pending = continuation
        continuation = nil
        if pending == nil {
            bufferedResult = .success(callback)
        }
        lock.unlock()
        pending?.resume(returning: callback)
        return true
    }

    func claim(_ callback: PendingCallback) {
        lock.lock()
        if unclaimedCallback?.connection === callback.connection {
            unclaimedCallback = nil
        }
        lock.unlock()
    }

    func drainUnclaimedCallback() -> PendingCallback? {
        lock.lock()
        let callback = unclaimedCallback
        unclaimedCallback = nil
        lock.unlock()
        return callback
    }

    func fail(with error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil
        if pending == nil {
            bufferedResult = .failure(error)
        }
        lock.unlock()
        pending?.resume(throwing: error)
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

// MARK: - AuthService

actor AuthService: AuthSessionClient {
    enum AuthError: Error, LocalizedError {
        case signedOut
        case noBindablePort(detail: String)
        case invalidCallback
        case authorizationCancelled
        case sessionValidationFailed(statusCode: Int)
        case tokenExchangeFailed
        case signInTimedOut

        // Spell every failure out for the settings UI — "(AuthError
        // error 1.)" cost a debugging round-trip that one real sentence
        // would have avoided.
        var errorDescription: String? {
            switch self {
            case .signedOut:
                return "Not signed in."
            case .noBindablePort(let detail):
                return "Could not open a local sign-in listener — \(detail)"
            case .invalidCallback:
                return "The browser sign-in did not complete (bad callback)."
            case .authorizationCancelled:
                return "Sign-in was cancelled in the browser."
            case .sessionValidationFailed(let statusCode):
                return "Moon Five could not validate the saved session (HTTP \(statusCode))."
            case .tokenExchangeFailed:
                return "Moon Five rejected the sign-in code exchange."
            case .signInTimedOut:
                return "Sign-in timed out — the browser window was not completed."
            }
        }
    }

    private let config: OIDCConfiguration
    private let tokenStore: TokenStore
    private let transport: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let allowsLegacyCredentials: Bool

    init(
        config: OIDCConfiguration = .production,
        tokenStore: TokenStore = KeychainTokenStore(),
        allowsLegacyCredentials: Bool = false,
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = AuthService.urlSessionTransport
    ) {
        self.config = config
        self.tokenStore = tokenStore
        self.allowsLegacyCredentials = allowsLegacyCredentials
        self.transport = transport
    }

    /// The one process-wide, Keychain-backed instance production wires up
    /// (CRMSyncService via AppState, plus the sign-in/out UI) so every
    /// surface shares the same signed-in state. Unit tests never touch
    /// this — AuthServiceTests builds its own fixture, and CRMSyncService's
    /// own default (InMemoryTokenStore-backed) is what every other CRM
    /// test rides on.
    static let shared = AuthService()

    static func urlSessionTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: Access token

    /// A currently-valid access token — from the store as-is when it's
    /// still fresh (no network at all), or by refreshing first when it's
    /// within TokenRefreshPolicy's buffer. Throws `.signedOut` when there
    /// is no stored token, or when the refresh POST comes back 401 (the
    /// refresh token itself is dead; the store is cleared so the caller's
    /// next attempt has to go through `signIn()` again).
    func validAccessToken() async throws -> String {
        let expectedEpoch = credentialEpoch
        guard !requiresFreshSignIn else { throw AuthError.signedOut }
        guard let tokenSet = try await tokenStore.load() else {
            throw AuthError.signedOut
        }
        guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
        guard TokenRefreshPolicy.shouldRefresh(tokenSet, now: Date()) else {
            return tokenSet.accessToken
        }
        let refreshed = try await refreshSingleFlight(
            currentTokenSet: tokenSet,
            credentialEpoch: expectedEpoch
        )
        return refreshed.accessToken
    }

    /// The one in-flight refresh POST, shared by every concurrent caller.
    /// Actor re-entrancy means a naive per-caller `refresh()` lets N
    /// concurrent `validAccessToken()` callers each start their OWN POST
    /// /token with the SAME (stale) refresh token — the IdP rotates AND
    /// revokes the whole token family on reuse past its ~30s grace window,
    /// and this actor's own 401 handler then clears the store, forcing
    /// every one of those callers into a surprise sign-out. Coalescing
    /// every concurrent caller onto the ONE Task<TokenSet, Error> here
    /// fixes that.
    private var credentialEpoch: UInt64 = 0
    /// Set when Keychain cleanup fails. While latched, no retained token may
    /// validate back into a session; only a newly completed authorization
    /// code flow clears it after persisting fresh credentials.
    private var requiresFreshSignIn = false
    private var inFlightRefresh: (id: UUID, task: Task<TokenSet, Error>)?

    private func refreshSingleFlight(
        currentTokenSet: TokenSet,
        credentialEpoch expectedEpoch: UInt64
    ) async throws -> TokenSet {
        guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
        let currentRefreshToken = currentTokenSet.refreshToken
        // Re-check the store first: a concurrent caller may have ALREADY
        // refreshed (and cleared the in-flight slot below) between this
        // caller's own stale-token snapshot and this call — reusing that
        // already-rotated refresh token in a FRESH POST would hit the
        // IdP's reuse-past-grace detection and revoke the whole family.
        // If the persisted refresh token no longer matches what this
        // caller started with, someone else already won; just hand back
        // what they got.
        if let current = try await tokenStore.load(), current.refreshToken != currentRefreshToken {
            guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
            return current
        }
        guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }

        if let inFlightRefresh {
            return try await inFlightRefresh.task.value
        }

        let id = UUID()
        let task = Task<TokenSet, Error> {
            try await self.performRefresh(
                currentTokenSet: currentTokenSet,
                credentialEpoch: expectedEpoch
            )
        }
        inFlightRefresh = (id, task)
        // Cleared in `defer`, whichever way the POST turns out — a stuck
        // slot here would wedge every future refresh behind one that
        // already finished.
        defer {
            if inFlightRefresh?.id == id {
                inFlightRefresh = nil
            }
        }
        return try await task.value
    }

    private func performRefresh(
        currentTokenSet: TokenSet,
        credentialEpoch expectedEpoch: UInt64
    ) async throws -> TokenSet {
        let currentRefreshToken = currentTokenSet.refreshToken
        var request = URLRequest(url: config.issuer.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": currentRefreshToken,
            "client_id": config.clientID,
        ]).data(using: .utf8)

        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                // The refresh token itself is dead — force a real re-sign-in
                // rather than retrying forever against a token that will
                // never work again.
                try? await tokenStore.clear(ifMatching: currentTokenSet)
                throw AuthError.signedOut
            }
            throw AuthError.sessionValidationFailed(statusCode: response.statusCode)
        }
        let refreshed = try TokenSet(
            tokenEndpointJSON: data, now: Date(), previousRefreshToken: currentRefreshToken
        )
        try Task.checkCancellation()
        guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
        try await tokenStore.save(refreshed)
        // TokenStore is an actor-shaped async dependency. Sign Out can run
        // while save is suspended, so check again and remove only this late
        // write. A newer sign-in may already have replaced it.
        guard credentialEpoch == expectedEpoch else {
            try? await tokenStore.clear(ifMatching: refreshed)
            throw AuthError.signedOut
        }
        return refreshed
    }

    // MARK: Per-target credential resolution

    /// Resolves the Authorization header value for one sync target. The
    /// production shared service requires a validated OIDC token and never
    /// falls back while the user is signed out. The opt-in legacy policy is
    /// reserved for isolated compatibility/test clients that are never wired
    /// to AppState or user-facing views.
    func authorizationHeaderValue(for target: SyncTarget) async -> String? {
        if let token = try? await validAccessToken() {
            return "Bearer \(token)"
        }
        guard allowsLegacyCredentials else { return nil }
        guard let legacyKey = target.legacyKey, !legacyKey.isEmpty else { return nil }
        return "Bearer \(legacyKey)"
    }

    func authorizationHeaderValue(legacyKey: String) async -> String? {
        if let token = try? await validAccessToken() {
            return "Bearer \(token)"
        }
        guard allowsLegacyCredentials, !legacyKey.isEmpty else { return nil }
        return "Bearer \(legacyKey)"
    }

    // MARK: Sign in / out

    /// Validates the actual usable session: a fresh stored token is accepted,
    /// while a stale token must refresh successfully before this returns.
    func validatedSession() async throws -> AuthenticatedSession {
        let accessToken = try await validAccessToken()
        return AuthenticatedSession(email: Self.emailClaim(fromJWT: accessToken))
    }

    /// Compatibility convenience for existing setup/settings code. Unlike
    /// the old implementation this performs full validation/refresh and can
    /// never equate "some Keychain bytes exist" with authenticated state.
    func isSignedIn() async -> Bool {
        (try? await validatedSession()) != nil
    }

    /// Best-effort `email` claim from the stored access token's JWT
    /// (JSON Web Token) payload, for a "signed in as ..." label — nil
    /// whenever that's not cheaply available (signed out, or a token shape
    /// without an email claim); callers fall back to just showing
    /// signed-in state.
    func signedInEmail() async -> String? {
        (try? await validatedSession())?.email
    }

    func signOut() async throws {
        credentialEpoch &+= 1
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        do {
            try await tokenStore.clear()
            requiresFreshSignIn = false
        } catch {
            requiresFreshSignIn = true
            throw error
        }
    }

    /// A sign-in attempt gives up after this long — an abandoned browser
    /// tab (closed, or the IdP flow never completed) must not wedge
    /// `signIn()` forever: each abandoned attempt would otherwise leak its
    /// bound loopback listener, exhausting `config.redirectURIs`'s three
    /// candidate ports after just a few tries.
    // 5 minutes: a first-ever Google sign-in on a fresh Mac (password +
    // 2FA + account picker) routinely blows through 3. The waiting UI now
    // shows a live countdown, so a long window no longer looks like a hang.
    static let signInTimeoutSeconds = 300
    private static let signInTimeoutNanoseconds: UInt64 =
        UInt64(signInTimeoutSeconds) * 1_000_000_000

    /// Runs one full interactive sign-in: PKCE + state, a one-shot loopback
    /// HTTP listener on the first bindable port of `config.redirectURIs`,
    /// the system browser at the authorize URL, the callback (raced
    /// against `signInTimeoutNanoseconds`), then the code exchange.
    /// Integration surface (real sockets + a real browser) — untested by
    /// the suite, same convention as this file's other live network calls.
    /// The listener is torn down on EVERY exit path — success, throw, or a
    /// cancellation of the calling Task (the UI's Cancel button) — via
    /// `defer`.
    func signIn() async throws {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.generateVerifier()

        let (listener, port) = try await Self.startLoopbackListener(candidatePorts: config.redirectURIs)
        defer { listener.cancel() }

        let scopedConfig = OIDCConfiguration(
            issuer: config.issuer, clientID: config.clientID, redirectURIs: [port], scope: config.scope
        )
        let authorizeURL = AuthURLBuilder.authorizeURL(config: scopedConfig, state: state, codeChallenge: challenge)

        // Arm the real callback handler SYNCHRONOUSLY before the browser is
        // ever opened — an instantly-redirecting IdP session must find the
        // real handler, not a placeholder (codex P2; Task.yield gives no
        // ordering guarantee, so this is a plain synchronous call). A code
        // that lands before the await below is buffered by the completion.
        let completion = Self.armCallbackHandler(on: listener, expectedState: state)
        defer {
            if let callback = completion.drainUnclaimedCallback() {
                Self.sendBrowserOutcome(
                    .failure("This sign-in attempt is no longer active."),
                    on: callback.connection
                )
            }
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        guard opened else { throw AuthError.invalidCallback }

        let callback = try await Self.awaitCallbackWithTimeout(completion, listener: listener)
        completion.claim(callback)

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        try await completeSignIn(
            code: callback.code,
            codeVerifier: verifier,
            redirectURI: redirectURI
        ) { outcome in
            await Self.sendBrowserOutcomeAndWait(outcome, on: callback.connection)
        }
    }

    /// Completes the callback transaction in the only safe order: exchange
    /// the code, persist the resulting TokenSet, and only then tell the
    /// browser that sign-in succeeded. Any exchange/persistence/cancellation
    /// error receives an explicit failure page and leaves the caller locked.
    func completeSignIn(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        browserResponder: @escaping @Sendable (BrowserCallbackOutcome) async -> Void
    ) async throws {
        let expectedEpoch = credentialEpoch
        do {
            let tokenSet = try await exchangeCode(
                code: code, codeVerifier: codeVerifier, redirectURI: redirectURI
            )
            try Task.checkCancellation()
            guard credentialEpoch == expectedEpoch else { throw AuthError.signedOut }
            try await tokenStore.save(tokenSet)
            guard credentialEpoch == expectedEpoch else {
                try? await tokenStore.clear(ifMatching: tokenSet)
                throw AuthError.signedOut
            }
            requiresFreshSignIn = false
            await browserResponder(.success)
        } catch {
            let message: String
            if error is CancellationError {
                message = "Sign-in was cancelled before the session could be saved."
            } else {
                message = "Authentication could not be completed. Return to Phone Sync and try again."
            }
            await browserResponder(.failure(message))
            throw error
        }
    }

    private func exchangeCode(code: String, codeVerifier: String, redirectURI: String) async throws -> TokenSet {
        var request = URLRequest(url: config.issuer.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
            "client_id": config.clientID,
        ]).data(using: .utf8)

        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw AuthError.tokenExchangeFailed }
        return try TokenSet(tokenEndpointJSON: data, now: Date())
    }

    /// Percent-encodes both keys and values of a form-urlencoded body
    /// against an unreserved-only charset (RFC 3986 §2.3 — the SAME set
    /// PKCE's verifier draws from, see `unreservedCharacters`). Anything
    /// broader (e.g. `CharacterSet.urlQueryAllowed`, which leaves `+`, `/`,
    /// `=` unescaped) is wrong here: `+` means literal space in
    /// `application/x-www-form-urlencoded`, so a literal `+`/`/`/`=` in a
    /// value (or, in principle, a key) MUST be escaped or it corrupts the
    /// body the token endpoint parses. Internal (not private) for test
    /// visibility.
    static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: unreservedCharacters)
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return params.map { key, value in "\(encode(key))=\(encode(value))" }.joined(separator: "&")
    }

    /// Decodes the `email` claim from a JWT's middle (payload) segment.
    /// Deliberately NOT signature-verified — this only feeds a "signed in
    /// as ..." label; the JWKS (JSON Web Key Set)-verified check happens
    /// server-side on every authenticated call.
    private static func emailClaim(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payloadSegment = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payloadSegment.count % 4 != 0 { payloadSegment += "=" }
        guard let data = Data(base64Encoded: payloadSegment),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    // MARK: Loopback listener (integration — untested)

    private static func startLoopbackListener(candidatePorts: [Int]) async throws -> (NWListener, Int) {
        var failures: [String] = []
        for portValue in candidatePorts {
            guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else { continue }

            // Two constructions, best-first. (a) A loopback-pinned bind —
            // the socket is never reachable from off-box at all (same
            // construction ControlServer uses for 127.0.0.1:7891). (b) A
            // plain wildcard bind as fallback: the vanilla NWListener path,
            // kept safe by the accept-side loopback peer check plus the
            // 64-char random `state` the callback must echo. NWListener
            // rejects (a) with EINVAL on some macOS builds/contexts, which
            // previously killed every sign-in as `noBindablePort`.
            var attempts: [(String, () -> NWListener?)] = []
            attempts.append(("loopback-endpoint", {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
                // NWListener(using:on:) THROWS whenever requiredLocalEndpoint
                // is set — the port must come from the endpoint alone.
                return try? NWListener(using: parameters)
            }))
            attempts.append(("wildcard", {
                try? NWListener(using: .tcp, on: port)
            }))

            for (mode, make) in attempts {
                guard let listener = make() else {
                    failures.append("\(portValue)/\(mode): init threw")
                    continue
                }
                // An NWListener started with NO newConnectionHandler fails
                // with EINVAL (verified empirically 2026-08-20; this — not
                // the bind construction — was why every sign-in died with
                // noBindablePort while ControlServer, which sets its handler
                // before start, bound fine). Park a stray-cancelling handler
                // here; awaitCallback installs the real one once we return.
                listener.newConnectionHandler = { connection in connection.cancel() }
                let latch = OneShotLatch()
                let failure = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard latch.tryFire() else { return }
                            continuation.resume(returning: nil)
                        case .failed(let error):
                            guard latch.tryFire() else { return }
                            continuation.resume(returning: "failed: \(error)")
                        case .waiting(let error):
                            // A listener stuck in .waiting never becomes
                            // ready on its own here — treat as a failure so
                            // the loop moves on instead of hanging sign-in.
                            guard latch.tryFire() else { return }
                            continuation.resume(returning: "waiting: \(error)")
                        case .cancelled:
                            guard latch.tryFire() else { return }
                            continuation.resume(returning: "cancelled")
                        default:
                            break
                        }
                    }
                    listener.start(queue: .main)
                }
                if let failure {
                    failures.append("\(portValue)/\(mode): \(failure)")
                    listener.cancel()
                    continue
                }
                return (listener, portValue)
            }
        }
        throw AuthError.noBindablePort(detail: failures.joined(separator: "; "))
    }

    /// Races the real loopback callback against `signInTimeoutNanoseconds`
    /// — whichever finishes first wins, and `defer` cancels the loser. A
    /// timeout throws `.signInTimedOut`; either way `awaitCallback`'s own
    /// `withTaskCancellationHandler` (triggered when this task group
    /// cancels its sibling) tears down the socket side cleanly.
    private static func awaitCallbackWithTimeout(
        _ completion: CallbackCompletion, listener: NWListener
    ) async throws -> PendingCallback {
        try await withThrowingTaskGroup(of: PendingCallback.self) { group in
            group.addTask {
                try await awaitArmedCallback(completion, listener: listener)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: signInTimeoutNanoseconds)
                throw AuthError.signInTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AuthError.signInTimedOut
            }
            return result
        }
    }

    /// Accepts inbound loopback connections until ONE produces a request
    /// line `LoopbackCallback.parse` accepts (the real OIDC redirect,
    /// matching `expectedState`) and resolves with both its code and the
    /// still-open browser connection. Success is deliberately NOT rendered
    /// here; `completeSignIn` owns that only after exchange + persistence.
    /// Invalid callbacks receive a clear failure page without ever exposing
    /// application content.
    /// Cancellation (the timeout race above, or the UI's Cancel button via
    /// the enclosing Task) tears the listener down and resumes with a
    /// `CancellationError` through the SAME `CallbackCompletion`, so a
    /// late-arriving real connection can never double-resume after a
    /// cancellation already won.
    /// Installs the REAL callback connection handler — synchronously, so
    /// the caller can prove the handler is armed before the browser is ever
    /// opened (an instantly-redirecting IdP session must not race a
    /// placeholder handler; codex P2). The returned completion buffers a
    /// code that lands before anyone awaits it.
    private static func armCallbackHandler(
        on listener: NWListener, expectedState: String
    ) -> CallbackCompletion {
        let completion = CallbackCompletion()
        listener.newConnectionHandler = { connection in
                    // Only the local browser may deliver the callback. The
                    // wildcard-bind fallback makes this check load-bearing;
                    // under the loopback-pinned bind it is redundant depth.
                    // Fail CLOSED: anything that isn't an explicitly
                    // recognized loopback hostPort (e.g. .opaque endpoints)
                    // is rejected, not waved through (codex P2).
                    guard case let .hostPort(host, _) = connection.endpoint else {
                        connection.cancel()
                        return
                    }
                    let peer = "\(host)"
                    guard peer.hasPrefix("127.") || peer == "::1" || peer.hasPrefix("::1%") else {
                        connection.cancel()
                        return
                    }
                    // An accepted connection that never sends anything must
                    // not outlive the sign-in: give it a hard deadline
                    // (idempotent — cancel on a finished connection is a
                    // no-op). Codex P3.
                    let receiveDeadline = ConnectionReceiveDeadline(connection: connection)
                    receiveDeadline.schedule()
                    connection.stateUpdateHandler = { state in
                        guard case .ready = state else { return }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                            guard let data, let text = String(data: data, encoding: .utf8),
                                  let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
                                connection.cancel()
                                return
                            }
                            do {
                                let code = try LoopbackCallback.parse(
                                    requestLine: String(firstLine), expectedState: expectedState
                                )
                                // The request arrived. Ownership moves to
                                // completeSignIn only if this callback wins
                                // the completion race. A timeout/cancel may
                                // already have finished the attempt; close
                                // this accepted socket explicitly in that
                                // losing branch so the browser never spins on
                                // an orphaned connection.
                                if completion.succeed(
                                    with: PendingCallback(code: code, connection: connection)
                                ) {
                                    receiveDeadline.cancel()
                                } else {
                                    receiveDeadline.cancel()
                                    Self.sendBrowserOutcome(
                                        .failure("This sign-in attempt is no longer active."),
                                        on: connection
                                    )
                                }
                            } catch LoopbackCallbackError.authorizationDenied {
                                receiveDeadline.cancel()
                                Self.sendBrowserOutcome(
                                    .failure("Sign-in was cancelled or denied in the browser."),
                                    on: connection
                                )
                                completion.fail(with: AuthError.authorizationCancelled)
                            } catch LoopbackCallbackError.missingCode {
                                receiveDeadline.cancel()
                                Self.sendBrowserOutcome(
                                    .failure("The authorization callback did not include a sign-in code."),
                                    on: connection
                                )
                                completion.fail(with: AuthError.invalidCallback)
                            } catch {
                                receiveDeadline.cancel()
                                Self.sendBrowserOutcome(
                                    .failure("This callback is invalid or no longer matches the active sign-in."),
                                    on: connection
                                )
                            }
                        }
                    }
                    connection.start(queue: .main)
        }
        return completion
    }

    /// Awaits a code from an ALREADY-ARMED handler (`armCallbackHandler`).
    /// Cancellation (from the timeout race or the enclosing Task) tears the
    /// listener down and resumes with a `CancellationError` through the
    /// SAME `CallbackCompletion`, so a late-arriving real connection can
    /// never double-resume after a cancellation already won.
    private static func awaitArmedCallback(
        _ completion: CallbackCompletion, listener: NWListener
    ) async throws -> PendingCallback {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PendingCallback, Error>) in
                completion.attach(continuation)
            }
        }, onCancel: {
            listener.cancel()
            completion.cancel()
        })
    }

    private static func sendBrowserOutcome(_ outcome: BrowserCallbackOutcome, on connection: NWConnection) {
        connection.send(
            content: BrowserCallbackResponse.httpData(for: outcome),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func sendBrowserOutcomeAndWait(
        _ outcome: BrowserCallbackOutcome, on connection: NWConnection
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: BrowserCallbackResponse.httpData(for: outcome),
                completion: .contentProcessed { _ in
                    connection.cancel()
                    continuation.resume()
                }
            )
        }
    }
}
