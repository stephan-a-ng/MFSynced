import Network
import XCTest

@testable import MFSynced

/// Pins the NWListener construction contract that broke sign-in: the
/// initializer that takes BOTH parameters (with `requiredLocalEndpoint`
/// set) AND an explicit `on:` port throws at construction time — before
/// any bind — so a port-fallback loop built on it exhausts every
/// candidate and reports `noBindablePort` even with all ports free.
///
/// These tests deliberately never `start()` a listener (binding is
/// blocked in sandboxed test environments); construction alone is the
/// API contract under test.
final class LoopbackListenerConstructionTests: XCTestCase {

    private func loopbackParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        return parameters
    }

    func testDualSpecConstructionThrows() {
        // The regression: endpoint + on:port must throw. If Apple ever
        // relaxes this, the guard in startLoopbackListener still works —
        // this test just documents why the endpoint-only form is used.
        XCTAssertThrowsError(
            try NWListener(using: loopbackParameters(port: 47831), on: 47831)
        )
    }

    func testEndpointOnlyConstructionSucceeds() {
        XCTAssertNoThrow(try NWListener(using: loopbackParameters(port: 47831)))
    }
}
