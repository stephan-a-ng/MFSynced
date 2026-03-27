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
