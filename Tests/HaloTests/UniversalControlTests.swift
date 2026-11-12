// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class UniversalControlTests: XCTestCase {
    func testExplicitConnectionList() {
        XCTAssertEqual(UniversalControlLog.connected("Connected Devices IDS: [1234ABCD]"), true)
        XCTAssertEqual(UniversalControlLog.connected("Connected Devices IDS: [1234ABCD, 5678efab]"), true)
        XCTAssertEqual(UniversalControlLog.connected("Connected Devices IDS: []"), false)
    }

    func testHandoffAndDiscoveryDoNotDisconnectSession() {
        for message in ["user.uid.501.com.apple.universalcontrol.inputstate: publish filter notification: 0x2",
                        "Connections: [1234ABCD (connected)] -> [1234ABCD (connected)]",
                        "Sync Connected Devices: [1234ABCD,5678ABCD] -> [1234ABCD]",
                        "=== XPC: Connected Devices ==="] {
            XCTAssertNil(UniversalControlLog.connected(message))
        }
    }

    func testUnknownDoesNotMasqueradeAsDisconnected() {
        for message in ["Connected Devices IDS: <private>", "Connected Devices IDS: [<private>]",
                        "Connected Devices IDS: [1234ABCD,]", "Connected Devices IDS: [1234]",
                        "Connected Devices IDS: [1234ABCD] extra", "Connected Devices IDS: ["] {
            XCTAssertNil(UniversalControlLog.connected(message))
        }
    }

    func testLatestTransitionWinsEvenWhenLinesAreReordered() throws {
        let connected = try line("Connected Devices IDS: [1234ABCD]", at: 10)
        let disconnected = try line("Connected Devices IDS: []", at: 20)
        XCTAssertEqual(UniversalControlLog.latest(disconnected + connected), false)
        XCTAssertEqual(UniversalControlLog.latest(connected + disconnected), false)
        XCTAssertNil(UniversalControlLog.latest(Data()))
        XCTAssertEqual(UniversalControlLog.snapshot(Data()), .unchanged)
    }

    func testNewestUnknownInvalidatesOlderEvidence() throws {
        let known = try line("Connected Devices IDS: [1234ABCD]", at: 10)
        let unknown = try line("Connected Devices IDS: [<private>]", at: 20)
        XCTAssertNil(UniversalControlLog.latest(known + unknown))
        XCTAssertNil(UniversalControlLog.latest(unknown + known))
        XCTAssertEqual(UniversalControlLog.snapshot(unknown + known), .unknown)
        let recovered = try line("Connected Devices IDS: []", at: 30)
        XCTAssertEqual(UniversalControlLog.latest(unknown + recovered), false)
    }

    func testPeerSetIdentityIgnoresOrderButDetectsDifferentConnectedPeer() throws {
        let a = try line("Connected Devices IDS: [1234ABCD,5678efab]", at: 10)
        let reordered = try line("Connected Devices IDS: [5678EFAB, 1234abcd]", at: 20)
        let changed = try line("Connected Devices IDS: [1234ABCD,9012ABCD]", at: 30)
        XCTAssertEqual(UniversalControlLog.snapshot(a), UniversalControlLog.snapshot(reordered))
        XCTAssertNotEqual(UniversalControlLog.snapshot(a), UniversalControlLog.snapshot(changed))
        XCTAssertEqual(UniversalControlLog.latest(changed), true)
    }

    private func line(_ message: String, at: UInt64) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["eventMessage": message, "machTimestamp": at]) + Data([10])
    }
}
