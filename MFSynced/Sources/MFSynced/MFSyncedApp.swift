import SwiftUI
import AppKit

@main
struct MFSyncedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ONE AppState shared by the main window and the Settings scene — a
    // sign-in/out from Settings must reach the same running
    // CRMSyncService the main window's polling drives (see
    // AppState.refreshCRMConfigAfterAuthChange).
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                // Blank the window title: SwiftUI otherwise paints the app
                // name ("Phone Sync") into the detail toolbar, wasting space.
                .navigationTitle("")
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SPM executables default to .prohibited activation policy.
        // Setting .regular makes the app a normal foreground app that
        // gets a dock icon and can receive keyboard input.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring to front and make key
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
