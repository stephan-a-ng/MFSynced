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

    @discardableResult
    static func send(text: String, to recipient: String) -> Result<Void, SendError> {
        senderLog("[MessageSender] send to=\(recipient) text_len=\(text.count)")

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            senderLog("[MessageSender] FAILED to create AppleScript for \(recipient)")
            return .failure(.scriptError("Failed to create AppleScript"))
        }
        appleScript.executeAndReturnError(&error)

        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            senderLog("[MessageSender] FAILED to=\(recipient) error=\(msg)")
            return .failure(.scriptError(msg))
        }
        senderLog("[MessageSender] SUCCESS to=\(recipient)")
        return .success(())
    }
}
