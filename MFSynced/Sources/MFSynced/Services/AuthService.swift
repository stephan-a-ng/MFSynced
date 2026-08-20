import Foundation
import CryptoKit
import Network
import AppKit

// MARK: - OIDC configuration

/// The Mac agent's OIDC client + loopback redirect shape. Production talks
/// to the Moon Five user-access IdP (see `.production` for the verified
/// prod issuer/client); tests construct their own fixture.
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
    /// the run.app `iss` — always authorize/refresh against the run.app
    /// issuer directly, never an alias.
    static let production = OIDCConfiguration(
        issuer: URL(string: "https://user-access-api-production-537479330777.us-central1.run.app")!,
        clientID: "phonesync",
        redirectURIs: [47831, 47832, 47833],
        scope: "openid email profile"
    )
}

// MARK: - PKCE

enum PKCE {
    private static let unreservedCharset = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// A 64-character verifier drawn from the PKCE unreserved charset
    /// (RFC 7636 §4.1) via Swift's system (cryptographically secure) RNG.
    static func generateVerifier() -> String {
        String((0..<64).map { _ in unreservedCharset.randomElement()! })
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
        let refresh_token: String
        let expires_in: Double
    }

    /// Parses a token-endpoint JSON response
    /// (`{access_token, refresh_token, expires_in, ...}`) into a TokenSet,
    /// anchoring `expiresAt` to `now + expires_in`.
    init(tokenEndpointJSON data: Data, now: Date) throws {
        let decoded = try JSONDecoder().decode(TokenEndpointResponse.self, from: data)
        self.init(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
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
}

// MARK: - Loopback callback parsing

enum LoopbackCallbackError: Error {
    case malformedRequestLine
    case stateMismatch
    case missingCode
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
        guard let code = value("code") else {
            throw LoopbackCallbackError.missingCode
        }
        return code
    }
}

// MARK: - AuthService

actor AuthService {
    enum AuthError: Error {
        case signedOut
        case noBindablePort
        case invalidCallback
        case tokenExchangeFailed
    }

    private let config: OIDCConfiguration
    private let tokenStore: TokenStore
    private let transport: (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        config: OIDCConfiguration = .production,
        tokenStore: TokenStore = KeychainTokenStore(),
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = AuthService.urlSessionTransport
    ) {
        self.config = config
        self.tokenStore = tokenStore
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
        guard let tokenSet = try await tokenStore.load() else {
            throw AuthError.signedOut
        }
        guard TokenRefreshPolicy.shouldRefresh(tokenSet, now: Date()) else {
            return tokenSet.accessToken
        }
        return try await refresh(currentRefreshToken: tokenSet.refreshToken)
    }

    private func refresh(currentRefreshToken: String) async throws -> String {
        var request = URLRequest(url: config.issuer.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": currentRefreshToken,
            "client_id": config.clientID,
        ]).data(using: .utf8)

        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                // The refresh token itself is dead — force a real re-sign-in
                // rather than retrying forever against a token that will
                // never work again.
                try? await tokenStore.clear()
            }
            throw AuthError.signedOut
        }
        let refreshed = try TokenSet(tokenEndpointJSON: data, now: Date())
        try await tokenStore.save(refreshed)
        return refreshed.accessToken
    }

    // MARK: Sign in / out

    /// True once a token is on file — cheap local check, no refresh, no
    /// network; used by the UI to render signed-in vs signed-out state.
    func isSignedIn() async -> Bool {
        (try? await tokenStore.load()) != nil
    }

    /// Best-effort `email` claim from the stored access token's JWT
    /// payload, for a "signed in as ..." label — nil whenever that's not
    /// cheaply available (signed out, or a token shape without an email
    /// claim); callers fall back to just showing signed-in state.
    func signedInEmail() async -> String? {
        guard let tokenSet = try? await tokenStore.load() else { return nil }
        return Self.emailClaim(fromJWT: tokenSet.accessToken)
    }

    func signOut() async {
        try? await tokenStore.clear()
    }

    /// Runs one full interactive sign-in: PKCE + state, a one-shot loopback
    /// HTTP listener on the first bindable port of `config.redirectURIs`,
    /// the system browser at the authorize URL, the callback, then the code
    /// exchange. Integration surface (real sockets + a real browser) —
    /// untested by the suite, same convention as this file's other live
    /// network calls.
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

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        guard opened else { throw AuthError.invalidCallback }

        let requestLine = try await Self.awaitCallback(on: listener)
        let code = try LoopbackCallback.parse(requestLine: requestLine, expectedState: state)

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let tokenSet = try await exchangeCode(code: code, codeVerifier: verifier, redirectURI: redirectURI)
        try await tokenStore.save(tokenSet)
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

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    /// Decodes the `email` claim from a JWT's middle (payload) segment.
    /// Deliberately NOT signature-verified — this only feeds a "signed in
    /// as ..." label; the JWKS-verified check happens server-side on every
    /// authenticated call.
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
        for portValue in candidatePorts {
            guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)),
                  let listener = try? NWListener(using: .tcp, on: port) else { continue }
            let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: true)
                    case .failed, .cancelled:
                        resumed = true
                        continuation.resume(returning: false)
                    default:
                        break
                    }
                }
                listener.start(queue: .main)
            }
            if ready {
                return (listener, portValue)
            }
            listener.cancel()
        }
        throw AuthError.noBindablePort
    }

    /// Awaits the ONE inbound loopback connection, reads its HTTP request
    /// line, and answers with a small "you're signed in" page before
    /// closing the connection.
    private static func awaitCallback(on listener: NWListener) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.newConnectionHandler = { connection in
                guard !resumed else {
                    connection.cancel()
                    return
                }
                resumed = true
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                        guard let data, let text = String(data: data, encoding: .utf8),
                              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
                            connection.cancel()
                            continuation.resume(throwing: error ?? AuthError.invalidCallback)
                            return
                        }
                        let html = "<html><body>You're signed in — close this window.</body></html>"
                        let responseText = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        connection.send(
                            content: responseText.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(returning: String(firstLine))
                    }
                }
                connection.start(queue: .main)
            }
        }
    }
}
