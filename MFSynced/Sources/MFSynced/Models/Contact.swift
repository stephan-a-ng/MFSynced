import Foundation
import AppKit

struct Contact: Identifiable, Hashable {
    let id: String
    var fullName: String?
    var photo: NSImage?

    var initials: String {
        guard let fullName else {
            return String(id.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        }
        let words = fullName.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    static func == (lhs: Contact, rhs: Contact) -> Bool {
        lhs.id == rhs.id && lhs.fullName == rhs.fullName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fullName)
    }
}
