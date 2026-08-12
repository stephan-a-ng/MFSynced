import XCTest
@testable import MFSynced

final class DeliveryVerifierTests: XCTestCase {
    // deliveryAckStatus maps a chat.db observation of the just-sent outgoing
    // message to the ack the backend should receive. AppleScript "success"
    // only means Messages accepted the send — a stuck iMessage to an Android
    // recipient looks successful there, so chat.db's receipt/error fields are
    // the truth source.

    func testMessagesErrorAcksFailed() {
        XCTAssertEqual(
            MessageSender.deliveryAckStatus(errorCode: 22, delivered: false),
            "failed: Messages reported send error 22"
        )
    }

    func testDeliveryReceiptAcksDelivered() {
        XCTAssertEqual(
            MessageSender.deliveryAckStatus(errorCode: 0, delivered: true),
            "delivered"
        )
    }

    func testNoReceiptYetAcksNothing() {
        // nil = keep waiting (or leave the command in "sent" on timeout) —
        // plain SMS may never produce a receipt, so absence is not failure.
        XCTAssertNil(MessageSender.deliveryAckStatus(errorCode: 0, delivered: false))
    }

    func testErrorWinsOverStaleReceipt() {
        XCTAssertEqual(
            MessageSender.deliveryAckStatus(errorCode: 5, delivered: true),
            "failed: Messages reported send error 5"
        )
    }
}
