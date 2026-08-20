import SwiftUI

struct CRMSyncSettingsView: View {
    @State private var config = CRMConfig.load()
    @State private var isSignedIn = false
    @State private var signedInEmail: String?
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        Form {
            Section("Account") {
                Toggle("CRM Sync Enabled", isOn: $config.isEnabled)

                if isSignedIn {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(signedInEmail.map { "Signed in as \($0)" } ?? "Signed in")
                        Spacer()
                        Button("Sign Out") { signOut() }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                    }
                } else {
                    HStack {
                        Button("Sign in with Moon Five") { signIn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking)
                        if isWorking {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                }
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("Owner Email", text: $config.ownerEmail, prompt: Text("you@example.com"))
                Text("The Message console account that owns this Mac's sync decisions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Poll interval")
                    Spacer()
                    TextField("", value: $config.pollIntervalSeconds, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Advanced") {
                ForEach(config.targets, id: \.name) { target in
                    HStack {
                        Text(target.name.capitalized)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(target.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Synced Contacts") {
                Text(
                    "When connected to the nexus, this allowlist is managed by "
                    + "the agent's owner in the Message console (Fleet page); "
                    + "the Mac applies the server's list on each poll."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if config.syncedPhoneNumbers.isEmpty {
                    Text("No contacts synced. Right-click a contact in the sidebar to enable CRM sync.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(config.syncedPhoneNumbers).sorted(), id: \.self) { phone in
                        HStack {
                            Text(phone)
                            Spacer()
                            Button("Remove") {
                                config.syncedPhoneNumbers.remove(phone)
                                config.save()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: config.isEnabled) { config.save() }
        .onChange(of: config.ownerEmail) { config.save() }
        .onChange(of: config.pollIntervalSeconds) { config.save() }
        .task { await refreshSignInState() }
    }

    private func refreshSignInState() async {
        let signedIn = await AuthService.shared.isSignedIn()
        let email = await AuthService.shared.signedInEmail()
        await MainActor.run {
            isSignedIn = signedIn
            signedInEmail = email
        }
    }

    private func signIn() {
        isWorking = true
        actionError = nil
        Task {
            do {
                try await AuthService.shared.signIn()
                await refreshSignInState()
                await MainActor.run {
                    config.isEnabled = true
                    config.save()
                }
            } catch {
                await MainActor.run {
                    actionError = "Sign-in failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run { isWorking = false }
        }
    }

    private func signOut() {
        isWorking = true
        Task {
            await AuthService.shared.signOut()
            await refreshSignInState()
            await MainActor.run { isWorking = false }
        }
    }
}
