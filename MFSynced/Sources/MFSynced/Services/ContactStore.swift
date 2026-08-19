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

    /// Edge of the square avatar we ship. The console renders avatars at
    /// ~40px (80px on retina), so 128px is already generous. Contacts
    /// "thumbnails" on modern macOS are frequently 320px+ and ~80 KB — over
    /// the catalog's 100 KiB base64 cap once encoded — so without this
    /// downscale a real contact photo was silently dropped (observed live:
    /// an 81 KB thumbnail never reached the console).
    static let avatarEdge: CGFloat = 128

    /// Name + a SMALL JPEG of the contact's photo for backend sync, or nils
    /// when the contact/photo is unknown. Always downscaled to `avatarEdge`
    /// (aspect-fill, centered) before encoding so every thumbnail lands in
    /// the single-digit-KB range regardless of what Contacts hands back.
    func contactInfo(for identifier: String) -> (name: String?, photoJPEG: Data?) {
        let resolved = contact(for: identifier)
        guard let photo = resolved.photo else { return (resolved.fullName, nil) }
        guard let jpeg = Self.avatarJPEG(from: photo) else { return (resolved.fullName, nil) }
        return (resolved.fullName, jpeg)
    }

    /// Aspect-fill `image` into an `avatarEdge` square and encode as JPEG.
    /// Pure (no Contacts access) so the size guarantee is unit-testable.
    static func avatarJPEG(from image: NSImage, edge: CGFloat = avatarEdge,
                           quality: CGFloat = 0.8) -> Data? {
        let size = NSSize(width: edge, height: edge)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(edge), pixelsHigh: Int(edge),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        // Aspect-fill: scale so the shorter side matches `edge`, center-crop.
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }
        let scale = max(edge / src.width, edge / src.height)
        let drawW = src.width * scale, drawH = src.height * scale
        let origin = NSPoint(x: (edge - drawW) / 2, y: (edge - drawH) / 2)
        image.draw(in: NSRect(origin: origin, size: NSSize(width: drawW, height: drawH)),
                   from: .zero, operation: .copy, fraction: 1)
        ctx.flushGraphics()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
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
