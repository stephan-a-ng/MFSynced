import Foundation
import UserNotifications

enum NotificationService {
    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func showMessageNotification(
        sender: String,
        text: String,
        chatIdentifier: String
    ) {
        let enabled = UserDefaults.standard.bool(forKey: "mfsynced_notifications_enabled")
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = text
        content.sound = UserDefaults.standard.bool(forKey: "mfsynced_notifications_sound")
            ? .default : nil
        content.userInfo = ["chatIdentifier": chatIdentifier]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
