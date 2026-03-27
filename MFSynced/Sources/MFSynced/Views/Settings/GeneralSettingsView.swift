import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("mfsynced_theme") private var theme = "system"
    @AppStorage("mfsynced_db_path") private var dbPath = ""
    @AppStorage("mfsynced_poll_interval") private var pollInterval = 2.0

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }

            Section("Database") {
                TextField("chat.db Path", text: $dbPath, prompt: Text("~/Library/Messages/chat.db"))
                Text("Leave empty to use default location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Polling") {
                HStack {
                    Text("Poll interval")
                    Spacer()
                    TextField("", value: $pollInterval, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
