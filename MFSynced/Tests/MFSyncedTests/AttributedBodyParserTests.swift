import XCTest
@testable import MFSynced

final class AttributedBodyParserTests: XCTestCase {
    func testExtractFromNilReturnsNil() {
        XCTAssertNil(AttributedBodyParser.extractText(from: nil))
    }

    func testExtractFromEmptyDataReturnsNil() {
        XCTAssertNil(AttributedBodyParser.extractText(from: Data()))
    }

    func testExtractFromBlobWithNSStringMarker() {
        var blob = Data()
        blob.append(contentsOf: [0x00, 0x00])
        blob.append("NSString".data(using: .utf8)!)
        blob.append(contentsOf: [0x00, 0x2b])
        let text = "Hello world"
        blob.append(UInt8(text.utf8.count))
        blob.append(text.data(using: .utf8)!)
        blob.append(contentsOf: [0x00, 0x00])

        XCTAssertEqual(AttributedBodyParser.extractText(from: blob), "Hello world")
    }

    func testExtractFromBlobWithMultiByteLengthEncoding() {
        var blob = Data()
        blob.append(contentsOf: [0x00])
        blob.append("NSString".data(using: .utf8)!)
        blob.append(contentsOf: [0x00, 0x2b])
        let text = String(repeating: "A", count: 200)
        blob.append(0x81)
        blob.append(UInt8(text.utf8.count))
        blob.append(text.data(using: .utf8)!)

        XCTAssertEqual(AttributedBodyParser.extractText(from: blob), text)
    }

    func testExtractFromDataWithoutMarkerReturnsNil() {
        let blob = "some random data without the marker".data(using: .utf8)!
        XCTAssertNil(AttributedBodyParser.extractText(from: blob))
    }
}
