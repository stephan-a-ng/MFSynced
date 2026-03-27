import Foundation
import Contacts
import AppKit

@Observable
final class ContactStore {
    private var cache: [String: Contact] = [:]
    private let store = CNContactStore()

    func contact(for identifier: String) -> Contact {
        if let cached = cache[identifier] {
            return cached
        }
        let contact = Contact(id: identifier)
        cache[identifier] = contact
        Task.detached { [weak self] in
            await self?.lookupContact(identifier)
        }
        return contact
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    private func lookupContact(_ identifier: String) async {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]

        do {
            let predicate: NSPredicate
            if identifier.contains("@") {
                predicate = CNContact.predicateForContacts(matchingEmailAddress: identifier)
            } else {
                let digits = identifier.filter { $0.isNumber }
                let phoneNumber = CNPhoneNumber(stringValue: digits)
                predicate = CNContact.predicateForContacts(matching: phoneNumber)
            }

            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            guard let cnContact = contacts.first else { return }

            let fullName = [cnContact.givenName, cnContact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            var photo: NSImage?
            if let imageData = cnContact.thumbnailImageData {
                photo = NSImage(data: imageData)
            }

            await MainActor.run {
                self.cache[identifier] = Contact(
                    id: identifier,
                    fullName: fullName.isEmpty ? nil : fullName,
                    photo: photo
                )
            }
        } catch {
            // Silently fail — will show initials
        }
    }
}
