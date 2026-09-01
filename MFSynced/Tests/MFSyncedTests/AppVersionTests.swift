import XCTest
@testable import MFSynced

final class AppVersionTests: XCTestCase {
    func testLabelUsesShortVersionFromInfoDictionary() {
        XCTAssertEqual(
            appVersionLabel(infoDictionary: ["CFBundleShortVersionString": "1.7"]),
            "Phone Sync 1.7"
        )
    }

    func testLabelFallsBackToDevWhenShortVersionIsMissing() {
        XCTAssertEqual(appVersionLabel(infoDictionary: nil), "Phone Sync dev")
    }
}
