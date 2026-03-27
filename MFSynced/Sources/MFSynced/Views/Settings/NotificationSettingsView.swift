import SwiftUI

struct NotificationSettingsView: View {
    @AppStorage("mfsynced_notifications_enabled") private var enabled = true
    @AppStorage("mfsynced_notifications_sound") private var sound = true
    @AppStorage("mfsynced_notifications_filter") private var filter = "all"

    var body: some View {
        Form {
            Toggle("Enable notifications", isOn: $enabled)

            if enabled {
                Toggle("Play sound", isOn: $sound)

                Picker("Show notifications for", selection: $filter) {
                    Text("All messages").tag("all")
                    Text("CRM contacts only").tag("crm")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
