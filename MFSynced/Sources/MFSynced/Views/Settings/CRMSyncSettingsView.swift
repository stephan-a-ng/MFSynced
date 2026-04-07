import SwiftUI

struct CRMSyncSettingsView: View {
    @State private var config = CRMConfig.load()

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("CRM Sync Enabled", isOn: $config.isEnabled)
                TextField("API Endpoint", text: $config.apiEndpoint, prompt: Text("https://your-backend.com/v1/agent"))
                SecureField("API Key", text: $config.apiKey, prompt: Text("mf_sk_..."))
            }

            Section("Mirror Backend (optional)") {
                TextField("Mirror Endpoint", text: $config.mirrorApiEndpoint, prompt: Text("https://staging.com/v1/agent"))
                SecureField("Mirror API Key", text: $config.mirrorApiKey, prompt: Text("mf_sk_..."))
                if config.hasMirror {
                    Label("All syncs and forwards go to both backends", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Synced Contacts") {
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
        .onChange(of: config.apiEndpoint) { config.save() }
        .onChange(of: config.apiKey) { config.save() }
        .onChange(of: config.pollIntervalSeconds) { config.save() }
        .onChange(of: config.mirrorApiEndpoint) { config.save() }
        .onChange(of: config.mirrorApiKey) { config.save() }
    }
}
