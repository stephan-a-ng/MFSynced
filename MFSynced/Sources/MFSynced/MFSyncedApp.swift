import SwiftUI
import AppKit

@main
struct MFSyncedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
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
