import SwiftUI

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            CRMSyncSettingsView(appState: appState)
                .tabItem { Label("CRM Sync", systemImage: "arrow.triangle.2.circlepath") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 450, height: 400)
    }
}
