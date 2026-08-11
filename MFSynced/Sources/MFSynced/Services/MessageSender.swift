import Foundation
import OSLog

private let senderLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "MessageSender")

private func senderLog(_ message: String) {
    senderLogger.info("\(message, privacy: .public)")
    let path = NSHomeDirectory() + "/Library/Logs/mfsynced_crm.log"
    let line = "\(Date()): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path),
       let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/Library/Logs",
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

enum MessageSender {
    enum SendError: Error, LocalizedError {
        case scriptError(String)
        var errorDescription: String? {
            switch self { case .scriptError(let msg): return "Send failed: \(msg)" }
        }
    }

    /// Service attempt order. A thread whose chat.db service is anything
    /// other than iMessage — SMS (Short Message Service) or RCS (Rich
    /// Communication Services) — tries the SMS-forwarding account first —
    /// an Android recipient never answers on iMessage, and targeting the
    /// iMessage service leaves the message stuck in Messages waiting for a
    /// manual "Send as Text Message". No/unknown hint keeps iMessage first.
    /// Either way the other service is the fallback, so a wrong hint costs
    /// one extra attempt, never a failed send.
    static func sendOrder(preferredService hint: String?) -> [String] {
        let normalized = hint?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if normalized.isEmpty || normalized == "imessage" {
            return ["iMessage", "SMS"]
        }
        return ["SMS", "iMessage"]
    }

    @discardableResult
    static func send(
        text: String, to recipient: String, preferredService: String? = nil
    ) -> Result<Void, SendError> {
        senderLog("[MessageSender] send to=\(recipient) text_len=\(text.count) hint=\(preferredService ?? "none")")

        var lastError = "No Messages service could send"
        for service in sendOrder(preferredService: preferredService) {
            switch attempt(text: text, to: recipient, service: service) {
            case .success:
                senderLog("[MessageSender] SUCCESS to=\(recipient) via=\(service)")
                return .success(())
            case .failure(let err):
                lastError = err.localizedDescription
                senderLog("[MessageSender] attempt via=\(service) failed for \(recipient): \(lastError) — trying next")
            }
        }
        senderLog("[MessageSender] FAILED to=\(recipient) error=\(lastError)")
        return .failure(.scriptError(lastError))
    }

    private static func attempt(
        text: String, to recipient: String, service: String
    ) -> Result<Void, SendError> {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // `service type` is an AppleScript enum (iMessage / SMS), not a string.
        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = \(service)
                set targetBuddy to participant "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.scriptError("Failed to create AppleScript"))
        }
        appleScript.executeAndReturnError(&error)

        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            return .failure(.scriptError(msg))
        }
        return .success(())
    }
}
