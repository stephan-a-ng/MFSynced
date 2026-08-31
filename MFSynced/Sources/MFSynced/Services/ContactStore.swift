import Foundation
import Contacts
import AppKit
import OSLog

private let contactStoreLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "ContactStore")

/// Mirrors CRMSyncService's crmLog (private to that file, so not directly
/// reusable here): OSLog plus the same FleetLogBuffer ring the nexus drains
/// on every poll tick, so a write failure here still surfaces in the fleet
/// log viewer without SSH access to the Mac.
private func contactLog(_ message: String) {
    guard SensitiveDiagnostics.record(message, bufferForFleet: true) else { return }
    contactStoreLogger.info("\(message, privacy: .public)")
}

@Observable
final class ContactStore {
    struct PhoneDisplay {
        let name: String?
        let photoJPEG: Data?
    }

    private var cache: [String: Contact] = [:]
    private let store = CNContactStore()
    private let syncQueue: SyncQueueDatabase
    private var phoneToContact: [String: PhoneDisplay] = [:]
    private var phoneMirror: [String: PhoneDisplay] = [:]
    private var avatarJPEGCache: [String: Data] = [:]
    private var identifiersWithoutAvatarJPEG: Set<String> = []
    private var isLoaded = false

    init(syncQueue: SyncQueueDatabase = SyncQueueDatabase()) {
        self.syncQueue = syncQueue
        loadPhoneMirror()
    }

    func contact(for identifier: String) -> Contact {
        if let cached = cache[identifier] {
            return cached
        }

        // Try to resolve from pre-built phone map
        if let match = Self.resolvePhoneDisplay(for: identifier, apple: phoneToContact, mirror: phoneMirror) {
            let resolved = Contact(
                id: identifier, fullName: match.name,
                photo: match.photoJPEG.flatMap(NSImage.init(data:))
            )
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
        if let cached = avatarJPEGCache[identifier] {
            return (resolved.fullName, cached)
        }
        if identifiersWithoutAvatarJPEG.contains(identifier) {
            return (resolved.fullName, nil)
        }
        guard let photo = resolved.photo,
              let jpeg = Self.avatarJPEG(from: photo) else {
            identifiersWithoutAvatarJPEG.insert(identifier)
            return (resolved.fullName, nil)
        }
        avatarJPEGCache[identifier] = jpeg
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
        // save/restoreGraphicsState do NOT restore WHICH context is current —
        // put the previous one back explicitly or this thread's current
        // context stays pointed at the discarded bitmap.
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
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

    // MARK: - Console → Address Book write-back (S5)

    /// Phone match keys for `identifier`: the full digit string plus (when
    /// long enough) its last-10-digit form — the same digit/last-10
    /// matching `buildPhoneMap`/`contact(for:)` already use, so an update
    /// phone in a different format (with/without country code, punctuation)
    /// still resolves to the same contact the rest of the app would.
    static func phoneMatchKeys(for identifier: String) -> Set<String> {
        Set(phoneMatchKeyCandidates(for: identifier))
    }

    private static func phoneMatchKeyCandidates(for identifier: String) -> [String] {
        let digits = identifier.filter { $0.isNumber }
        guard !digits.isEmpty else { return [] }
        var keys = [digits]
        if digits.count >= 10 {
            keys.append(String(digits.suffix(10)))
        }
        return keys
    }

    /// Selects a display record using the exact same full-digit/last-10
    /// matching as Contacts lookup. Apple Contacts deliberately comes first;
    /// the server mirror only fills numbers absent from the local address book.
    static func resolvePhoneDisplay(
        for identifier: String,
        apple: [String: PhoneDisplay],
        mirror: [String: PhoneDisplay]
    ) -> PhoneDisplay? {
        let keys = phoneMatchKeyCandidates(for: identifier)
        for key in keys {
            if let match = apple[key] { return match }
        }
        for key in keys {
            if let match = mirror[key] { return match }
        }
        return nil
    }

    /// Persists server-provided contact details to the app-local mirror only.
    /// It intentionally does not fetch, save, or otherwise touch CNContactStore.
    @discardableResult
    func updatePhoneMirror(phones: [String], displayName: String?, photoJPEG: Data?) -> Bool {
        let keys = Set(phones.flatMap(Self.phoneMatchKeys(for:)))
        guard !keys.isEmpty else { return false }
        do {
            for digits in keys {
                try syncQueue.upsertPhoneMirror(
                    PhoneMirrorEntry(digits: digits, displayName: displayName, photoJPEG: photoJPEG)
                )
                phoneMirror[digits] = PhoneDisplay(name: displayName, photoJPEG: photoJPEG)
            }
            cache.removeAll()
            avatarJPEGCache.removeAll()
            identifiersWithoutAvatarJPEG.removeAll()
            return true
        } catch {
            contactLog("[ContactStore] updatePhoneMirror: \(error.localizedDescription)")
            return false
        }
    }

    private func loadPhoneMirror() {
        do {
            phoneMirror = Dictionary(
                uniqueKeysWithValues: try syncQueue.loadPhoneMirror().map {
                    ($0.digits, PhoneDisplay(name: $0.displayName, photoJPEG: $0.photoJPEG))
                }
            )
        } catch {
            contactLog("[ContactStore] loadPhoneMirror: \(error.localizedDescription)")
        }
    }

    /// Splits a console `display_name` into CNContact's givenName/
    /// familyName on the LAST space — "Mary Jane Watson" → given
    /// "Mary Jane", family "Watson" (keeps a multi-word given name intact
    /// rather than the family name). A single token (no space) becomes
    /// givenName-only, familyName "". Pure — no Contacts access — so this
    /// is directly unit-testable.
    static func nameSplit(_ displayName: String) -> (given: String, family: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSpace = trimmed.range(of: " ", options: .backwards) else {
            return (trimmed, "")
        }
        let given = String(trimmed[trimmed.startIndex..<lastSpace.lowerBound])
        let family = String(trimmed[lastSpace.upperBound...])
        return (given, family)
    }

    /// Applies a console-side NAME/PHOTO edit to the first local CNContact
    /// matching ANY of `phones` — Stephan's call: ANY matching contact, not
    /// just one already shared to the CRM, using the same digit/last-10
    /// matching `contact(for:)` uses. Returns whether anything was actually
    /// written. Contacts write uses the SAME `.contacts` authorization
    /// already requested at launch (full access includes write on macOS);
    /// a save failure (permission revoked mid-session, contact deleted
    /// concurrently, etc.) degrades silently to `false` — logged, never
    /// thrown into the poll loop.
    @discardableResult
    func applyContactUpdate(phones: [String], displayName: String?, photoJPEG: Data?) -> Bool {
        let targetKeys = Set(phones.flatMap(Self.phoneMatchKeys(for:)))
        guard !targetKeys.isEmpty else { return false }

        // Mutation fetch: unlike buildPhoneMap's cached name+thumbnail map,
        // applying an edit needs the live CNContact (for mutableCopy) plus
        // CNContactImageDataKey (the full-res settable image, not the
        // read-only CNContactThumbnailImageDataKey buildPhoneMap fetches).
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var match: CNContact?
        do {
            try store.enumerateContacts(with: request) { cnContact, stop in
                let contactKeys = Set(cnContact.phoneNumbers.flatMap {
                    Self.phoneMatchKeys(for: $0.value.stringValue)
                })
                if !contactKeys.isDisjoint(with: targetKeys) {
                    match = cnContact
                    stop.pointee = true
                }
            }
        } catch {
            contactLog("[ContactStore] applyContactUpdate: enumerate failed: \(error.localizedDescription)")
            return false
        }
        guard let match, let mutable = match.mutableCopy() as? CNMutableContact else { return false }

        var changed = false
        if let displayName, !displayName.isEmpty {
            let (given, family) = Self.nameSplit(displayName)
            if mutable.givenName != given || mutable.familyName != family {
                mutable.givenName = given
                mutable.familyName = family
                changed = true
            }
        }
        if let photoJPEG {
            // Cheap inequality proxy: compare encoded byte counts, not
            // bytes — a full byte compare is unneeded I/O for a photo that
            // in practice either matches or doesn't; a same-length-
            // different-bytes false negative just skips one sync cycle,
            // corrected by the next update.
            if mutable.imageData?.count != photoJPEG.count {
                mutable.imageData = photoJPEG
                changed = true
            }
        }
        guard changed else { return false }

        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        do {
            try store.execute(saveRequest)
        } catch {
            contactLog("[ContactStore] applyContactUpdate: save failed: \(error.localizedDescription)")
            return false
        }
        // Fire-and-forget refresh: applyContactUpdate is a synchronous DI
        // callback (CRMSyncService.contactUpdateApplier), so the cache
        // invalidation can't be awaited inline — mirrors contact(for:)'s
        // Task.detached load-on-demand.
        Task.detached { [weak self] in await self?.refresh() }
        return true
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
            avatarJPEGCache.removeAll()
            identifiersWithoutAvatarJPEG.removeAll()
            isLoaded = false
        }
        loadPhoneMirror()
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
        var newMap: [String: PhoneDisplay] = [:]

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

                for phoneNumber in cnContact.phoneNumbers {
                    let entry = PhoneDisplay(name: name, photoJPEG: cnContact.thumbnailImageData)
                    for key in Self.phoneMatchKeys(for: phoneNumber.value.stringValue) {
                        newMap[key] = entry
                    }
                }
            }
        } catch {
            return
        }

        let completedMap = newMap
        await MainActor.run {
            self.phoneToContact = completedMap
            self.avatarJPEGCache.removeAll()
            self.identifiersWithoutAvatarJPEG.removeAll()
            self.isLoaded = true

            // Re-resolve any cached contacts that were unresolved
            for (identifier, existing) in cache where existing.fullName == nil {
                if let match = Self.resolvePhoneDisplay(
                    for: identifier, apple: completedMap, mirror: self.phoneMirror
                ) {
                    cache[identifier] = Contact(
                        id: identifier, fullName: match.name,
                        photo: match.photoJPEG.flatMap(NSImage.init(data:))
                    )
                }
            }
        }
    }
}
