import XCTest
@testable import MFSynced

final class SyncQueueDatabasePhoneMirrorTests: XCTestCase {
    private var db: SyncQueueDatabase!
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "test_phone_mirror_\(UUID().uuidString).db"
        db = SyncQueueDatabase(path: path)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testPhoneMirrorTableCreatesAndLoadsNoRows() throws {
        XCTAssertTrue(try db.loadPhoneMirror().isEmpty)
    }

    func testUpsertAndLoadPhoneMirror() throws {
        let photo = Data([0x01, 0x02])
        try db.upsertPhoneMirror(
            PhoneMirrorEntry(digits: "15555550001", displayName: "Mirror Person", photoJPEG: photo)
        )

        XCTAssertEqual(try db.loadPhoneMirror(), [
            PhoneMirrorEntry(digits: "15555550001", displayName: "Mirror Person", photoJPEG: photo),
        ])
    }

    func testUpsertOverwritesExistingPhoneMirrorRow() throws {
        try db.upsertPhoneMirror(
            PhoneMirrorEntry(digits: "15555550002", displayName: "Before", photoJPEG: Data([0x01]))
        )
        try db.upsertPhoneMirror(
            PhoneMirrorEntry(digits: "15555550002", displayName: "After", photoJPEG: Data([0x02]))
        )

        XCTAssertEqual(try db.loadPhoneMirror(), [
            PhoneMirrorEntry(digits: "15555550002", displayName: "After", photoJPEG: Data([0x02])),
        ])
    }

    func testPhoneMirrorLoadsEveryRow() throws {
        try db.upsertPhoneMirror(PhoneMirrorEntry(digits: "15555550003", displayName: "Three", photoJPEG: nil))
        try db.upsertPhoneMirror(PhoneMirrorEntry(digits: "15555550004", displayName: "Four", photoJPEG: nil))

        XCTAssertEqual(Set(try db.loadPhoneMirror().map(\.digits)), ["15555550003", "15555550004"])
    }

    func testPhoneMatchKeysNormalizeDigitsAndLastTenDigits() {
        XCTAssertEqual(
            ContactStore.phoneMatchKeys(for: "+1 (555) 555-0005"),
            ["15555550005", "5555550005"]
        )
        XCTAssertEqual(ContactStore.phoneMatchKeys(for: "not a phone"), [])
    }
}
