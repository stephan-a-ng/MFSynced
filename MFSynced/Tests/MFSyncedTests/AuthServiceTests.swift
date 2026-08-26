import XCTest
@testable import MFSynced

// MARK: - Test-only transport recorder
//
// Mirrors this codebase's existing DI convention (CRMSyncService's
// `contactPushStatusOverride`/`contactUpdatesFetchOverride`: a plain closure
// seam, not a protocol) rather than inventing a new `Transport` protocol.
// AuthService is expected to accept a
// `(URLRequest) async throws -> (Data, HTTPURLResponse)` closure — production
// defaults to a real `URLSession` call, tests pass `RecordingTransport.handle`.
private actor RecordingTransport {
    private(set) var requests: [URLRequest] = []
    private var responses: [(status: Int, body: Data)]

    init(responses: [(status: Int, body: Data)] = []) {
        self.responses = responses
    }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.unknown)
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://access.moonfive.tech/token")!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (next.body, response)
    }
}

private actor SuspendedTransport {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    var isPending: Bool { continuation != nil }

    func succeed(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://access.moonfive.tech/token")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        continuation?.resume(returning: (body, response))
        continuation = nil
    }
}

/// Stores a token, then suspends the selected save before returning to the
/// AuthService actor. This deterministically opens the post-save epoch-check
/// window without involving a real Keychain.
private actor LateWriteTokenStore: TokenStore {
    private var stored: TokenSet?
    private var suspendNextSave = false
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func seed(_ tokenSet: TokenSet?) { stored = tokenSet }
    func armSaveSuspension() { suspendNextSave = true }

    func save(_ tokenSet: TokenSet) async throws {
        stored = tokenSet
        guard suspendNextSave else { return }
        suspendNextSave = false
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
    }

    func load() async throws -> TokenSet? { stored }
    func clear() async throws { stored = nil }
    func clear(ifMatching tokenSet: TokenSet) async throws {
        if stored == tokenSet { stored = nil }
    }

    var isSavePending: Bool { saveContinuation != nil }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private actor FailingClearTokenStore: TokenStore {
    enum ClearError: Error { case denied }
    private var stored: TokenSet?
    private var shouldFailClear = true

    init(stored: TokenSet?) { self.stored = stored }

    func save(_ tokenSet: TokenSet) async throws { stored = tokenSet }
    func load() async throws -> TokenSet? { stored }
    func clear() async throws {
        if shouldFailClear { throw ClearError.denied }
        stored = nil
    }
    func clear(ifMatching tokenSet: TokenSet) async throws {
        if stored == tokenSet { stored = nil }
    }
}

private func bodyString(_ request: URLRequest) -> String? {
    request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
}

final class AuthServiceTests: XCTestCase {
    private let testConfig = OIDCConfiguration(
        issuer: URL(string: "https://access.moonfive.tech")!,
        clientID: "phonesync",
        redirectURIs: [47831, 47832, 47833],
        scope: "openid email profile"
    )

    // MARK: - PKCE

    func testGenerateVerifierIsSixtyFourCharsFromUnreservedCharset() {
        let verifier = PKCE.generateVerifier()
        XCTAssertEqual(verifier.count, 64)

        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        XCTAssertTrue(
            verifier.unicodeScalars.allSatisfy { allowed.contains($0) },
            "verifier '\(verifier)' contains a character outside the PKCE unreserved charset"
        )
    }

    func testGenerateVerifierProducesDistinctValuesAcrossCalls() {
        let first = PKCE.generateVerifier()
        let second = PKCE.generateVerifier()
        XCTAssertNotEqual(first, second)
    }

    func testChallengeMatchesRFC7636AppendixBVector() {
        // RFC 7636 Appendix B, the canonical worked example — pinned exactly.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - AuthURLBuilder

    func testAuthorizeURLContainsRequiredParametersAndBase() throws {
        let url = AuthURLBuilder.authorizeURL(
            config: testConfig,
            state: "state-abc123",
            codeChallenge: "challenge-xyz789"
        )

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "access.moonfive.tech")
        XCTAssertEqual(url.path, "/authorize")

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "phonesync")
        XCTAssertEqual(value("state"), "state-abc123")
        XCTAssertEqual(value("code_challenge"), "challenge-xyz789")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("scope"), "openid email profile")
        XCTAssertEqual(value("prompt"), "select_account")

        // The exact bound port is a signIn()-time (socket-bind) concern, not
        // this pure builder's — just require it to be one of the configured
        // loopback candidates, on the /callback path.
        let redirectURIString = try XCTUnwrap(value("redirect_uri"))
        let redirectURL = try XCTUnwrap(URL(string: redirectURIString))
        XCTAssertEqual(redirectURL.host, "127.0.0.1")
        XCTAssertEqual(redirectURL.path, "/callback")
        let redirectPort = try XCTUnwrap(redirectURL.port)
        XCTAssertTrue(testConfig.redirectURIs.contains(redirectPort))
    }

    // MARK: - TokenSet

    func testTokenSetDecodesFromTokenEndpointJSON() throws {
        let json = """
        {"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let now = Date()

        let tokenSet = try TokenSet(tokenEndpointJSON: json, now: now)

        XCTAssertEqual(tokenSet.accessToken, "a")
        XCTAssertEqual(tokenSet.refreshToken, "r")
        XCTAssertEqual(tokenSet.expiresAt.timeIntervalSince(now), 3600, accuracy: 5)
    }

    // MARK: - TokenRefreshPolicy

    func testShouldRefreshFalseWellBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokenSet = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        XCTAssertFalse(TokenRefreshPolicy.shouldRefresh(tokenSet, now: now))
    }

    func testShouldRefreshTrueWithinOneHundredTwentySecondBuffer() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 60s to expiry: inside the 120s refresh buffer.
        let tokenSet = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(TokenRefreshPolicy.shouldRefresh(tokenSet, now: now))
    }

    func testShouldRefreshTrueAfterExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokenSet = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(-1))
        XCTAssertTrue(TokenRefreshPolicy.shouldRefresh(tokenSet, now: now))
    }

    // MARK: - LoopbackCallback

    func testLoopbackCallbackParsesCodeFromValidRequestLine() throws {
        let code = try LoopbackCallback.parse(
            requestLine: "GET /callback?code=abc&state=xyz HTTP/1.1",
            expectedState: "xyz"
        )
        XCTAssertEqual(code, "abc")
    }

    func testLoopbackCallbackRejectsStateMismatch() {
        XCTAssertThrowsError(
            try LoopbackCallback.parse(
                requestLine: "GET /callback?code=abc&state=xyz HTTP/1.1",
                expectedState: "different-state"
            )
        )
    }

    func testLoopbackCallbackRejectsMissingCode() {
        XCTAssertThrowsError(
            try LoopbackCallback.parse(
                requestLine: "GET /callback?state=xyz HTTP/1.1",
                expectedState: "xyz"
            )
        )
    }

    func testLoopbackCallbackPercentDecodesCode() throws {
        // "a b/c" percent-encoded — proves decoding, not just substring slicing.
        let code = try LoopbackCallback.parse(
            requestLine: "GET /callback?code=a%20b%2Fc&state=xyz HTTP/1.1",
            expectedState: "xyz"
        )
        XCTAssertEqual(code, "a b/c")
    }

    func testLoopbackCallbackSurfacesBrowserAuthorizationDenial() {
        XCTAssertThrowsError(
            try LoopbackCallback.parse(
                requestLine: "GET /callback?error=access_denied&error_description=User%20cancelled&state=xyz HTTP/1.1",
                expectedState: "xyz"
            )
        ) { error in
            XCTAssertEqual(
                error as? LoopbackCallbackError,
                .authorizationDenied(description: "User cancelled")
            )
        }
    }

    // MARK: - TokenStore round trip (InMemoryTokenStore)

    func testInMemoryTokenStoreRoundTripsSaveLoadClear() async throws {
        let store = InMemoryTokenStore()

        let initial = try await store.load()
        XCTAssertNil(initial)

        let tokenSet = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        try await store.save(tokenSet)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.accessToken, "a")
        XCTAssertEqual(loaded?.refreshToken, "r")

        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    // MARK: - AuthService

    private func makeStaleTokenSet(now: Date) -> TokenSet {
        // 10s to expiry: inside the 120s refresh buffer, so validAccessToken()
        // must treat it as stale and trigger a refresh.
        TokenSet(accessToken: "stale-access", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(10))
    }

    func testValidAccessTokenReturnsStoredTokenWithoutNetworkWhenFresh() async throws {
        let now = Date()
        let store = InMemoryTokenStore()
        try await store.save(
            TokenSet(accessToken: "fresh-access", refreshToken: "fresh-refresh", expiresAt: now.addingTimeInterval(3600))
        )
        let transport = RecordingTransport()
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let accessToken = try await service.validAccessToken()

        XCTAssertEqual(accessToken, "fresh-access")
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "a fresh token must never hit the network")
    }

    func testValidAccessTokenRefreshesAndPersistsBothRotatedTokensWhenStale() async throws {
        let now = Date()
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: now))

        let refreshedJSON = """
        {"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let transport = RecordingTransport(responses: [(200, refreshedJSON)])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let accessToken = try await service.validAccessToken()
        XCTAssertEqual(accessToken, "rotated-access")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, testConfig.issuer.appendingPathComponent("token"))
        XCTAssertEqual(requests[0].timeoutInterval, AuthService.refreshRequestTimeoutSeconds)
        XCTAssertLessThan(
            requests[0].timeoutInterval, 10,
            "token refresh must finish before CRM's ten-second heartbeat deadline"
        )
        let body = try XCTUnwrap(bodyString(requests[0]))
        XCTAssertTrue(body.contains("grant_type=refresh_token"), "body was: \(body)")
        XCTAssertTrue(body.contains("old-refresh"), "refresh must send the CURRENT refresh token, body was: \(body)")

        // Persistence must reflect BOTH rotated tokens, not just the
        // in-memory value handed back from this call.
        let persisted = try await store.load()
        let unwrapped = try XCTUnwrap(persisted)
        XCTAssertEqual(unwrapped.accessToken, "rotated-access")
        XCTAssertEqual(unwrapped.refreshToken, "rotated-refresh")
    }

    func testValidAccessTokenSurfacesErrorAndClearsStoreOn401() async throws {
        let now = Date()
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: now))

        let transport = RecordingTransport(responses: [(401, Data())])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        do {
            _ = try await service.validAccessToken()
            XCTFail("expected validAccessToken() to throw when the refresh POST comes back 401")
        } catch {
            // Expected: a 401 on refresh means the refresh token itself is
            // dead — signed-out state, not a transient network error.
        }

        let persisted = try await store.load()
        XCTAssertNil(persisted, "a 401 refresh must clear the token store (forces re-signIn)")
    }

    func testIsSignedInRefreshesStaleStoredTokenBeforeReportingAuthenticated() async throws {
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: Date()))
        let refreshedJSON = """
        {"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let transport = RecordingTransport(responses: [(200, refreshedJSON)])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let signedIn = await service.isSignedIn()
        let requests = await transport.requests
        XCTAssertTrue(signedIn)
        XCTAssertEqual(requests.count, 1)
    }

    func testIsSignedInRejectsAndClearsInvalidStoredSession() async throws {
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: Date()))
        let transport = RecordingTransport(responses: [(401, Data())])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let signedIn = await service.isSignedIn()
        let persisted = try await store.load()
        XCTAssertFalse(signedIn)
        XCTAssertNil(persisted)
    }

    func testValidatedSessionSurfacesTransientRefreshFailureWithoutClearingStoredToken() async throws {
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: Date()))
        let transport = RecordingTransport(responses: [(503, Data())])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        do {
            _ = try await service.validatedSession()
            XCTFail("expected transient validation failure")
        } catch AuthService.AuthError.sessionValidationFailed(let statusCode) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let persisted = try await store.load()
        XCTAssertNotNil(persisted, "transient server failures must not destroy a refreshable saved session")
    }

    func testSignOutPreventsInFlightRefreshFromRepersistingCredentials() async throws {
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: Date()))
        let transport = SuspendedTransport()
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let refresh = Task { try await service.validAccessToken() }
        while !(await transport.isPending) { await Task.yield() }

        try await service.signOut()
        let refreshedJSON = """
        {"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        await transport.succeed(status: 200, body: refreshedJSON)
        _ = try? await refresh.value

        let persistedAfterRefresh = try await store.load()
        XCTAssertNil(
            persistedAfterRefresh,
            "a refresh that finishes after sign-out must never restore credentials"
        )
    }

    func testCancelledOldRefreshCannotClearCredentialsFromANewerSignIn() async throws {
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: Date()))
        let transport = SuspendedTransport()
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let oldRefresh = Task { try await service.validAccessToken() }
        while !(await transport.isPending) { await Task.yield() }

        try await service.signOut()
        let newerSession = TokenSet(
            accessToken: "new-session-access",
            refreshToken: "new-session-refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await store.save(newerSession)
        await transport.succeed(status: 401, body: Data())
        _ = try? await oldRefresh.value

        let persistedNewerSession = try await store.load()
        XCTAssertEqual(persistedNewerSession, newerSession)
    }

    func testLateSuccessfulRefreshCannotClearCredentialsFromANewerSignIn() async throws {
        let store = LateWriteTokenStore()
        await store.seed(makeStaleTokenSet(now: Date()))
        await store.armSaveSuspension()
        let refreshedJSON = """
        {"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let service = AuthService(
            config: testConfig,
            tokenStore: store,
            transport: RecordingTransport(responses: [(200, refreshedJSON)]).handle
        )

        let oldRefresh = Task { try await service.validAccessToken() }
        while !(await store.isSavePending) { await Task.yield() }

        try await service.signOut()
        let newerSession = TokenSet(
            accessToken: "new-session-access",
            refreshToken: "new-session-refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        await store.seed(newerSession)
        await store.resumeSave()
        _ = try? await oldRefresh.value

        let persistedNewerSession = try await store.load()
        XCTAssertEqual(persistedNewerSession, newerSession)
    }

    func testSignOutPreventsInFlightCodeExchangeFromPersistingCredentials() async throws {
        let store = InMemoryTokenStore()
        let transport = SuspendedTransport()
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        let exchange = Task {
            try await service.completeSignIn(
                code: "authorization-code",
                codeVerifier: "verifier",
                redirectURI: "http://127.0.0.1:47831/callback"
            ) { _ in }
        }
        while !(await transport.isPending) { await Task.yield() }

        try await service.signOut()
        let tokenJSON = """
        {"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        await transport.succeed(status: 200, body: tokenJSON)
        _ = try? await exchange.value

        let persistedAfterExchange = try await store.load()
        XCTAssertNil(
            persistedAfterExchange,
            "a code exchange that finishes after sign-out must never create a new session"
        )
    }

    func testFailedSignOutRequiresFreshAuthorizationBeforeRetainedTokenCanValidate() async throws {
        let retained = TokenSet(
            accessToken: "retained-access",
            refreshToken: "retained-refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let store = FailingClearTokenStore(stored: retained)
        let freshJSON = """
        {"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let service = AuthService(
            config: testConfig,
            tokenStore: store,
            transport: RecordingTransport(responses: [(200, freshJSON)]).handle
        )

        do {
            try await service.signOut()
            XCTFail("expected synthetic Keychain cleanup failure")
        } catch {
            // Expected: the retained item must now be blocked by the
            // credential-layer fresh-sign-in latch.
        }

        do {
            _ = try await service.validAccessToken()
            XCTFail("retained credentials must not validate after failed sign-out")
        } catch AuthService.AuthError.signedOut {
            // Expected.
        }

        try await service.completeSignIn(
            code: "fresh-authorization-code",
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:47831/callback"
        ) { _ in }

        let accessToken = try await service.validAccessToken()
        XCTAssertEqual(accessToken, "fresh-access")
    }

    // MARK: - Refresh single-flight (P1-1: stampede fix)

    func testConcurrentValidAccessTokenCallsShareExactlyOneTransportInvocation() async throws {
        let now = Date()
        let store = InMemoryTokenStore()
        try await store.save(makeStaleTokenSet(now: now))

        // Only ONE response queued on purpose: if single-flight coalescing
        // is broken, a second independent POST would find the queue empty
        // and throw, failing this test outright.
        let refreshedJSON = """
        {"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let transport = RecordingTransport(responses: [(200, refreshedJSON)])
        let service = AuthService(config: testConfig, tokenStore: store, transport: transport.handle)

        async let first = service.validAccessToken()
        async let second = service.validAccessToken()
        let (firstToken, secondToken) = try await (first, second)

        XCTAssertEqual(firstToken, "rotated-access")
        XCTAssertEqual(secondToken, "rotated-access")

        let requests = await transport.requests
        XCTAssertEqual(
            requests.count, 1,
            "two concurrent callers racing the SAME stale token must share ONE refresh POST, not one each"
        )
    }

    // MARK: - formEncode (P2: percent-encode keys AND values)

    func testFormEncodePercentEncodesReservedCharactersInValues() {
        let encoded = AuthService.formEncode(["k": "abc+def/ghi="])
        XCTAssertEqual(encoded, "k=abc%2Bdef%2Fghi%3D")
    }

    // MARK: - TokenSet (P3: refresh_token optional, carries previous forward)

    func testTokenSetCarriesForwardPreviousRefreshTokenWhenOmitted() throws {
        let json = """
        {"access_token":"a2","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let tokenSet = try TokenSet(
            tokenEndpointJSON: json, now: Date(), previousRefreshToken: "carried-forward-refresh"
        )
        XCTAssertEqual(tokenSet.accessToken, "a2")
        XCTAssertEqual(tokenSet.refreshToken, "carried-forward-refresh")
    }

    func testTokenSetThrowsWhenRefreshTokenOmittedAndNoPreviousProvided() {
        let json = """
        {"access_token":"a2","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try TokenSet(tokenEndpointJSON: json, now: Date()))
    }

    // MARK: - Per-target credential resolution (P1-2)

    func testAuthorizationHeaderForTargetUsesOIDCBearerWhenSignedIn() async throws {
        let store = InMemoryTokenStore()
        try await store.save(
            TokenSet(accessToken: "signed-in-access", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        )
        let service = AuthService(config: testConfig, tokenStore: store, transport: RecordingTransport().handle)

        // Even a target with NO legacy key of its own gets the shared OIDC
        // Bearer token when signed in — one IdP, trusted everywhere.
        let target = SyncTarget(name: "staging", url: URL(string: "https://staging.example.com/v1/agent")!)
        let header = await service.authorizationHeaderValue(for: target)
        XCTAssertEqual(header, "Bearer signed-in-access")
    }

    func testProductionAuthorizationNeverUsesLegacyKeyWhenSignedOut() async {
        let service = AuthService(
            config: testConfig, tokenStore: InMemoryTokenStore(), transport: RecordingTransport().handle
        )
        let primary = SyncTarget(
            name: "primary", url: URL(string: "https://example.com/v1/agent")!, legacyKey: "prod-key"
        )

        let primaryHeader = await service.authorizationHeaderValue(for: primary)

        XCTAssertNil(
            primaryHeader,
            "the production policy must remain fail-closed even when a migrated legacy key exists"
        )
    }

    func testExplicitCompatibilityClientMayUseOnlyTargetsOwnLegacyKey() async {
        let service = AuthService(
            config: testConfig,
            tokenStore: InMemoryTokenStore(),
            allowsLegacyCredentials: true,
            transport: RecordingTransport().handle
        )
        let primary = SyncTarget(
            name: "primary", url: URL(string: "https://example.com/v1/agent")!, legacyKey: "prod-key"
        )
        let mirror = SyncTarget(name: "mirror", url: URL(string: "https://mirror.example.com/v1/agent")!)

        let primaryHeader = await service.authorizationHeaderValue(for: primary)
        let mirrorHeader = await service.authorizationHeaderValue(for: mirror)
        XCTAssertEqual(primaryHeader, "Bearer prod-key")
        XCTAssertNil(mirrorHeader)
    }

    func testBrowserResponseDoesNotClaimSuccessForFailure() throws {
        let response = try XCTUnwrap(
            String(
                data: BrowserCallbackResponse.httpData(for: .failure("Token persistence failed.")),
                encoding: .utf8
            )
        )
        XCTAssertTrue(response.contains("Phone Sync sign-in failed"))
        XCTAssertFalse(response.contains("Phone Sync is signed in"))
    }

    func testCompleteSignInReportsSuccessOnlyAfterTokenPersistence() async throws {
        actor OutcomeRecorder {
            let store: InMemoryTokenStore
            var outcome: BrowserCallbackOutcome?
            var hadStoredTokenAtResponse = false

            init(store: InMemoryTokenStore) { self.store = store }

            func record(_ value: BrowserCallbackOutcome) async {
                outcome = value
                hadStoredTokenAtResponse = (try? await store.load()) != nil
            }
        }

        let store = InMemoryTokenStore()
        let tokenJSON = """
        {"access_token":"signed-access","refresh_token":"signed-refresh","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let service = AuthService(
            config: testConfig,
            tokenStore: store,
            transport: RecordingTransport(responses: [(200, tokenJSON)]).handle
        )
        let recorder = OutcomeRecorder(store: store)

        try await service.completeSignIn(
            code: "authorization-code",
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:47831/callback"
        ) { outcome in
            await recorder.record(outcome)
        }

        let recordedOutcome = await recorder.outcome
        let hadStoredTokenAtResponse = await recorder.hadStoredTokenAtResponse
        XCTAssertEqual(recordedOutcome, .success)
        XCTAssertTrue(hadStoredTokenAtResponse)
    }

    func testCompleteSignInReportsFailureAndDoesNotPersistRejectedExchange() async throws {
        actor OutcomeRecorder {
            var outcome: BrowserCallbackOutcome?
            func record(_ value: BrowserCallbackOutcome) { outcome = value }
        }

        let store = InMemoryTokenStore()
        let service = AuthService(
            config: testConfig,
            tokenStore: store,
            transport: RecordingTransport(responses: [(400, Data())]).handle
        )
        let recorder = OutcomeRecorder()

        do {
            try await service.completeSignIn(
                code: "rejected-code",
                codeVerifier: "verifier",
                redirectURI: "http://127.0.0.1:47831/callback"
            ) { outcome in
                await recorder.record(outcome)
            }
            XCTFail("expected rejected token exchange")
        } catch {
            // Expected.
        }

        let recordedOutcome = await recorder.outcome
        guard case .failure = recordedOutcome else {
            return XCTFail("browser must receive failure after a rejected exchange")
        }
        let persisted = try await store.load()
        XCTAssertNil(persisted)
    }
}
