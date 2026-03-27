import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            CRMSyncSettingsView()
                .tabItem { Label("CRM Sync", systemImage: "arrow.triangle.2.circlepath") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 450, height: 400)
    }
}
