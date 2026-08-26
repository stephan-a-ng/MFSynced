import Foundation

struct Message: Identifiable, Hashable {
    let id: Int64
    let guid: String
    let text: String?
    let attributedBody: Data?
    let isFromMe: Bool
    let date: Date
    let dateEdited: Date?
    let associatedMessageType: Int
    let associatedMessageEmoji: String?
    var associatedMessageGUID: String? = nil
    let cacheHasAttachments: Bool
    let service: String
    let senderID: String?
    let chatIdentifier: String?
    let chatDisplayName: String?
    let chatStyle: Int?
    let attachmentNames: String?
    let attachmentTypes: String?

    var displayText: String? {
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty,
           text != "\u{FFFC}" {
            return text
        }
        if let attributedBody {
            return AttributedBodyParser.extractText(from: attributedBody)
        }
        return nil
    }

    var isGroup: Bool { chatStyle == 43 }
    var isTapback: Bool { associatedMessageType != 0 }

    /// Apple's associated-message GUID may be prefixed (for example
    /// `p:0/<guid>`).  The nexus stores the base message GUID, so reactions
    /// normalize to the final path component before upload.
    var tapbackTargetGUID: String? {
        guard let raw = associatedMessageGUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    var tapbackReactionType: String? {
        switch associatedMessageType {
        case 2000, 3000: return "love"
        case 2001, 3001: return "like"
        case 2002, 3002: return "dislike"
        case 2003, 3003: return "laugh"
        case 2004, 3004: return "emphasize"
        case 2005, 3005: return "question"
        default: return nil
        }
    }

    var isTapbackRemoval: Bool { (3000...3005).contains(associatedMessageType) }

    var tapbackLabel: String? {
        switch associatedMessageType {
        case 0: return nil
        case 1000: return "[Sticker]"
        case 2000: return "Loved"
        case 2001: return "Liked"
        case 2002: return "Disliked"
        case 2003: return "Laughed at"
        case 2004: return "Emphasized"
        case 2005: return "Questioned"
        case 2006: return "Reacted \(associatedMessageEmoji ?? "?")"
        case 3000...3006: return "Removed reaction"
        default: return "[Reaction]"
        }
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
