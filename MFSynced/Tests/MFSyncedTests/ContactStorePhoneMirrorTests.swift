import XCTest
@testable import MFSynced

final class ContactStorePhoneMirrorTests: XCTestCase {
    private var db: SyncQueueDatabase!
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "test_contact_phone_mirror_\(UUID().uuidString).db"
        db = SyncQueueDatabase(path: path)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testUpdatePhoneMirrorPersistsEveryPhoneFromContactUpdate() throws {
        let store = ContactStore(syncQueue: db)
        let update = CRMSyncService.ContactUpdate(
            phones: ["+1 (555) 555-0006", "+1 555 555 0007"],
            displayName: "Server Person",
            photoJPEG: Data([0x0A])
        )

        XCTAssertTrue(store.updatePhoneMirror(
            phones: update.phones, displayName: update.displayName, photoJPEG: update.photoJPEG
        ))
        XCTAssertEqual(Set(try db.loadPhoneMirror().map(\.digits)), ["15555550006", "5555550006", "15555550007", "5555550007"])
    }

    func testAppleContactsEntryWinsAndMirrorFillsGap() {
        let apple = ["15555550008": ContactStore.PhoneDisplay(name: "Apple Person", photoJPEG: nil)]
        let mirror = ["15555550008": ContactStore.PhoneDisplay(name: "Mirror Loses", photoJPEG: nil),
                      "15555550009": ContactStore.PhoneDisplay(name: "Mirror Fallback", photoJPEG: nil)]

        XCTAssertEqual(ContactStore.resolvePhoneDisplay(for: "+1 555 555 0008", apple: apple, mirror: mirror)?.name, "Apple Person")
        XCTAssertEqual(ContactStore.resolvePhoneDisplay(for: "+1 555 555 0009", apple: apple, mirror: mirror)?.name, "Mirror Fallback")
    }

    func testUpdatePhoneMirrorDoesNotRequireOrMutateCNContactStore() throws {
        // This path is intentionally database-only: it succeeds without
        // requesting Contacts permission and leaves its evidence solely in
        // phone_mirror, unlike applyContactUpdate's explicit CN save path.
        let store = ContactStore(syncQueue: db)

        XCTAssertTrue(store.updatePhoneMirror(
            phones: ["+1 555 555 0010"], displayName: "Mirror Only", photoJPEG: nil
        ))
        XCTAssertEqual(Set(try db.loadPhoneMirror().compactMap(\.displayName)), ["Mirror Only"])
    }
}
