import SwiftUI

struct AuthenticationGateView: View {
    let authentication: AuthenticationController

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: iconName)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.title2.bold())

            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)

            controls
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("authentication-gate")
    }

    private var iconName: String {
        switch authentication.state {
        case .checking, .signingIn, .signingOut: return "person.badge.clock"
        case .failed, .signOutFailed: return "exclamationmark.shield.fill"
        case .cancelled, .signedOut: return "lock.shield.fill"
        case .authenticated: return "checkmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch authentication.state {
        case .failed, .signOutFailed: return .red
        case .cancelled, .signedOut: return .orange
        case .authenticated: return .green
        case .checking, .signingIn, .signingOut: return .accentColor
        }
    }

    private var title: String {
        switch authentication.state {
        case .checking: return "Checking authentication"
        case .signingIn: return "Complete sign-in in your browser"
        case .signingOut: return "Signing out"
        case .failed: return "Authentication failed"
        case .signOutFailed: return "Sign-out cleanup failed"
        case .cancelled: return "Sign-in cancelled"
        case .signedOut: return "Authentication required"
        case .authenticated: return "Authenticated"
        }
    }

    private var detail: String {
        switch authentication.state {
        case .checking:
            return "Phone Sync is validating your saved Moon Five session. Messages and sync history remain hidden until validation succeeds."
        case .signingIn:
            return "The app will remain locked until the OIDC callback is verified and your tokens are securely saved."
        case .signingOut:
            return "Phone Sync is securely removing the saved session. Messages and sync history remain hidden."
        case .failed(let message):
            return message
        case .signOutFailed(let message):
            return message
        case .cancelled:
            return "No session was created. Phone Sync remains locked and no message or sync history is visible."
        case .signedOut:
            return "Sign in with Moon Five to unlock conversations and sync. Phone Sync cannot be used without an authenticated session."
        case .authenticated(let email):
            return email.map { "Authenticated as \($0)" } ?? "Your Moon Five session is authenticated."
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch authentication.state {
        case .checking, .signingOut:
            ProgressView()
                .controlSize(.large)
        case .signingIn:
            VStack(spacing: 12) {
                TimelineView(.periodic(from: authentication.signInStartedAt ?? .now, by: 1)) { context in
                    let remaining = max(
                        0,
                        AuthService.signInTimeoutSeconds
                            - Int(context.date.timeIntervalSince(authentication.signInStartedAt ?? context.date))
                    )
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser callback… \(remaining)s")
                    }
                }
                Button("Cancel Sign-in") { authentication.cancelSignIn() }
                    .buttonStyle(.bordered)
            }
        case .failed:
            HStack(spacing: 12) {
                Button("Retry Session Check") {
                    Task { await authentication.retryValidation() }
                }
                .buttonStyle(.bordered)
                Button("Sign in with Moon Five") { beginSignIn() }
                    .buttonStyle(.borderedProminent)
            }
        case .signOutFailed:
            Button("Sign in with Moon Five") { beginSignIn() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .cancelled, .signedOut:
            Button("Sign in with Moon Five") { beginSignIn() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .authenticated:
            EmptyView()
        }
    }

    private func beginSignIn() {
        authentication.startSignIn()
    }
}
