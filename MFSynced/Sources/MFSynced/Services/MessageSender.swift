import Foundation

enum MessageSender {
    enum SendError: Error, LocalizedError {
        case scriptError(String)
        var errorDescription: String? {
            switch self { case .scriptError(let msg): return "Send failed: \(msg)" }
        }
    }

    @discardableResult
    static func send(text: String, to recipient: String) -> Result<Void, SendError> {
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
