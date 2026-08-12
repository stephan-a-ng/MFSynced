import XCTest
@testable import MFSynced

final class MessageSenderTests: XCTestCase {
    // sendOrder is the pure routing rule behind SMS (Short Message Service)
    // support: a thread known to be SMS tries the SMS service first so an
    // Android recipient never waits on a doomed iMessage attempt; everything
    // else keeps iMessage first. Both orders carry the other service as the
    // fallback, so a wrong or missing hint degrades to one extra attempt,
    // never a failed send.

    func testDefaultOrderIsIMessageFirst() {
        XCTAssertEqual(MessageSender.sendOrder(preferredService: nil), ["iMessage", "SMS"])
    }

    func testIMessageHintKeepsIMessageFirst() {
        XCTAssertEqual(MessageSender.sendOrder(preferredService: "iMessage"), ["iMessage", "SMS"])
    }

    func testSMSHintPutsSMSFirst() {
        XCTAssertEqual(MessageSender.sendOrder(preferredService: "SMS"), ["SMS", "iMessage"])
    }

    func testSMSHintIsCaseInsensitive() {
        XCTAssertEqual(MessageSender.sendOrder(preferredService: "sms"), ["SMS", "iMessage"])
    }

    func testRCSThreadsPreferTheSMSService() {
        // Newer macOS stores RCS (Rich Communication Services) chats with
        // their own service name; Messages sends to them via the SMS-forwarding
        // account, so any non-iMessage service prefers SMS.
        XCTAssertEqual(MessageSender.sendOrder(preferredService: "RCS"), ["SMS", "iMessage"])
    }

    func testUnknownHintFallsBackToIMessageFirst() {
        XCTAssertEqual(MessageSender.sendOrder(preferredService: ""), ["iMessage", "SMS"])
    }
}
