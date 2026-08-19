import XCTest
@testable import MFSynced

/// `nameSplit` turns a console `display_name` into CNContact's
/// givenName/familyName pair by splitting on the LAST space, so a
/// multi-word given name ("Mary Jane") survives intact rather than being
/// cut at the first space. Pure — no Contacts access — so directly
/// testable without CNContactStore/TCC permission (same rationale as
/// ContactStoreAvatarTests for avatarJPEG).
final class ContactStoreNameSplitTests: XCTestCase {
    func testSingleTokenBecomesGivenNameOnly() {
        let result = ContactStore.nameSplit("Cher")
        XCTAssertEqual(result.given, "Cher")
        XCTAssertEqual(result.family, "")
    }

    func testTwoTokensSplitOnTheSpace() {
        let result = ContactStore.nameSplit("Alexandra Chen")
        XCTAssertEqual(result.given, "Alexandra")
        XCTAssertEqual(result.family, "Chen")
    }

    func testThreeTokensSplitOnTheLastSpaceOnly() {
        // "Mary Jane Watson" -> given "Mary Jane", family "Watson" — NOT
        // given "Mary", family "Jane Watson".
        let result = ContactStore.nameSplit("Mary Jane Watson")
        XCTAssertEqual(result.given, "Mary Jane")
        XCTAssertEqual(result.family, "Watson")
    }

    func testEmptyStringProducesEmptyGivenAndFamily() {
        let result = ContactStore.nameSplit("")
        XCTAssertEqual(result.given, "")
        XCTAssertEqual(result.family, "")
    }

    func testWhitespaceOnlyStringProducesEmptyGivenAndFamily() {
        let result = ContactStore.nameSplit("   ")
        XCTAssertEqual(result.given, "")
        XCTAssertEqual(result.family, "")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeSplitting() {
        let result = ContactStore.nameSplit("  Alexandra Chen  ")
        XCTAssertEqual(result.given, "Alexandra")
        XCTAssertEqual(result.family, "Chen")
    }
}
