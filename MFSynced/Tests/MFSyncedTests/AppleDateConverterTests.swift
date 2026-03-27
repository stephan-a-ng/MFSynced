import XCTest
@testable import MFSynced

final class AppleDateConverterTests: XCTestCase {
    func testConvertKnownTimestamp() {
        let appleNs: Int64 = 796339648388169088
        let date = AppleDateConverter.toDate(appleNs)
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 27)
    }

    func testZeroReturnsNil() {
        XCTAssertNil(AppleDateConverter.toDate(0))
    }

    func testNegativeReturnsNil() {
        XCTAssertNil(AppleDateConverter.toDate(-1))
    }

    func testToISO8601() {
        let appleNs: Int64 = 796339648388169088
        let iso = AppleDateConverter.toISO8601(appleNs)
        XCTAssertNotNil(iso)
        XCTAssertTrue(iso!.hasPrefix("2026-03-27T"))
    }
}
