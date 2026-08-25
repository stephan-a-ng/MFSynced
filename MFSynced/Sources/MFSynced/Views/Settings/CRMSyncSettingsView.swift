import SwiftUI

struct CRMSyncSettingsView: View {
    // Shared with ContentView (see MFSyncedApp) so a sign-in/out here
    // reaches the running CRMSyncService immediately — see
    // AppState.refreshCRMConfigAfterAuthChange.
    let appState: AppState
    @State private var config = CRMConfig.load()
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Account") {
                Toggle("CRM Sync Enabled", isOn: $config.isEnabled)

                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(
                        appState.authentication.state.authenticatedEmail
                            .map { "Signed in as \($0)" } ?? "Signed in"
                    )
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("Sign Out") { signOut() }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
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
    }

    private func signOut() {
        isWorking = true
        Task {
            await appState.authentication.signOut()
            // Authentication already fail-closes every network request.
            // Preserve the user's explicit CRM enablement preference so a
            // successful fresh sign-in resumes the same configuration.
            isWorking = false
        }
    }
}
