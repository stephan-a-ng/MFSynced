import SwiftUI

struct CRMSyncSettingsView: View {
    @State private var config = CRMConfig.load()

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("CRM Sync Enabled", isOn: $config.isEnabled)
                TextField("API Endpoint", text: $config.apiEndpoint, prompt: Text("https://crm.example.com/api"))
                SecureField("API Key", text: $config.apiKey, prompt: Text("mf_sk_..."))
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
    }
}
