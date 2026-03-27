import Foundation

struct Conversation: Identifiable, Hashable {
    let id: String
    let displayName: String?
    let chatStyle: Int
    let service: String
    var lastMessage: Message?
    var messages: [Message]
    var isCRMSynced: Bool

    var isGroup: Bool { chatStyle == 43 }

    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }

    var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
