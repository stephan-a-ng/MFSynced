import Foundation
import Contacts
import AppKit

@Observable
final class ContactStore {
    private var cache: [String: Contact] = [:]
    private let store = CNContactStore()
    private var phoneToContact: [String: (name: String, photo: NSImage?)] = [:]
    private var isLoaded = false

    func contact(for identifier: String) -> Contact {
        if let cached = cache[identifier] {
            return cached
        }

        // Try to resolve from pre-built phone map
        let digits = identifier.filter { $0.isNumber }
        let last10 = String(digits.suffix(10))

        if let match = phoneToContact[digits] ?? phoneToContact[last10] {
            let resolved = Contact(id: identifier, fullName: match.name, photo: match.photo)
            cache[identifier] = resolved
            return resolved
        }

        // Return unresolved placeholder
        let contact = Contact(id: identifier)
        cache[identifier] = contact

        // If we haven't loaded the phone map yet, do it and then re-resolve
        if !isLoaded {
            Task.detached { [weak self] in
                await self?.buildPhoneMap()
            }
        }

        return contact
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            if granted {
                await buildPhoneMap()
            }
            return granted
        } catch {
            return false
        }
    }

    /// Create a new contact in Contacts.app with the given name and phone number, then refresh the cache.
    func createContact(firstName: String, lastName: String, phoneNumber: String) async throws {
        let newContact = CNMutableContact()
        newContact.givenName = firstName
        newContact.familyName = lastName
        newContact.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: phoneNumber)
        )]

        let saveRequest = CNSaveRequest()
        saveRequest.add(newContact, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)

        await refresh()
    }

    /// Clear cache and re-fetch all contacts from Contacts.app
    func refresh() async {
        await MainActor.run {
            cache.removeAll()
            isLoaded = false
        }
        await buildPhoneMap()
    }

    /// Build a phone-number-to-contact map from all contacts.
    /// Uses last-10-digits matching for reliability.
    private func buildPhoneMap() async {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let req = CNContactFetchRequest(keysToFetch: keysToFetch)
        var newMap: [String: (name: String, photo: NSImage?)] = [:]

        do {
            try store.enumerateContacts(with: req) { cnContact, _ in
                var name = [cnContact.givenName, cnContact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                // Fall back to organization name if no personal name
                if name.isEmpty {
                    name = cnContact.organizationName
                }
                guard !name.isEmpty else { return }

                var photo: NSImage?
                if let imageData = cnContact.thumbnailImageData {
                    photo = NSImage(data: imageData)
                }

                for phoneNumber in cnContact.phoneNumbers {
                    let digits = phoneNumber.value.stringValue.filter { $0.isNumber }
                    let entry = (name: name, photo: photo)
                    newMap[digits] = entry
                    // Also key by last 10 digits for flexible matching
                    if digits.count >= 10 {
                        newMap[String(digits.suffix(10))] = entry
                    }
                }
            }
        } catch {
            return
        }

        await MainActor.run {
            self.phoneToContact = newMap
            self.isLoaded = true

            // Re-resolve any cached contacts that were unresolved
            for (identifier, existing) in cache where existing.fullName == nil {
                let digits = identifier.filter { $0.isNumber }
                let last10 = String(digits.suffix(10))
                if let match = newMap[digits] ?? newMap[last10] {
                    cache[identifier] = Contact(id: identifier, fullName: match.name, photo: match.photo)
                }
            }
        }
    }
}
