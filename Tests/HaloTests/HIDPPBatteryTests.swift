// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class HIDPPBatteryTests: XCTestCase {
    func packet(_ feature: UInt8, software: UInt8 = 0x0D, parameters: [UInt8]) -> Data {
        Data([0x11, 0xFF, feature, software] + parameters + Array(repeating: 0, count: 16 - parameters.count))
    }
    func reader() -> HIDPPBattery {
        var reader = HIDPPBattery()
        let response = reader.receive(packet(0, parameters: [7, 0, 0]))
        XCTAssertEqual([UInt8](response.request!)[2], 7)
        return reader
    }
    func testPlugAndUnplugEventsWithoutAnAppRestart() {
        var r = reader()
        XCTAssertFalse(r.receive(packet(7, parameters: [20, 10, 0])).reading!.charging)
        XCTAssertTrue(r.receive(packet(7, software: 0, parameters: [20, 0, 1])).reading!.charging)
        XCTAssertFalse(r.receive(packet(7, software: 0, parameters: [20, 10, 0])).reading!.charging)
    }

    func testGATTIdentifiesTheReportAndDeviceWithoutExtraHeaderBytes() {
        XCTAssertEqual(HIDPPBattery.discoveryGATT.count, 18)
        XCTAssertEqual(HIDPPBattery.discoveryGATT.first, 0)
        var r = HIDPPBattery()
        let response = r.receiveGATT(Data(packet(0, parameters: [7, 0, 0]).dropFirst(2)))
        XCTAssertEqual(response.request?.count, 18)
        XCTAssertEqual(response.request?.first, 7)
        XCTAssertTrue(r.receiveGATT(Data(packet(7, parameters: [20, 0, 1]).dropFirst(2))).reading!.charging)
        XCTAssertNil(r.receiveGATT(packet(7, parameters: [20, 0, 1])).reading)
    }
    func testChargingFinalSlowFullAndErrors() {
        var r = reader()
        for status: UInt8 in [1, 2, 4] {
            XCTAssertTrue(r.receive(packet(7, parameters: [20, 0, status])).reading!.charging)
        }
        for status: UInt8 in [0, 3, 5, 6, 7] {
            XCTAssertFalse(r.receive(packet(7, parameters: [100, 0, status])).reading!.charging)
        }
    }
    func testUnknownPercentDoesNotOverwriteTheStandardReading() {
        var r = reader()
        XCTAssertNil(r.receive(packet(7, parameters: [0, 0, 1])).reading!.percent)
        XCTAssertEqual(r.receive(packet(7, parameters: [0, 0, 3])).reading!.percent, 100)
    }
    func testCompleteOverridesCoarseAndDelayedStandardLevelsUntilDischargingResumes() {
        var r = reader()
        XCTAssertEqual(r.percent(forStandardReading: 50), 50)
        XCTAssertEqual(r.receive(packet(7, software: 0, parameters: [90, 0, 3])).reading?.percent, 100)
        XCTAssertTrue(r.reading!.chargedOnCable)
        XCTAssertEqual(r.percent(forStandardReading: 90), 100)
        XCTAssertFalse(r.reading!.charging)
        XCTAssertEqual(r.receive(packet(7, software: 0, parameters: [90, 50, 0])).reading?.percent, 90)
        XCTAssertFalse(r.reading!.chargedOnCable)
        XCTAssertEqual(r.percent(forStandardReading: 50), 50)
    }
    func testCapabilityIsQueriedOnceAndNeverBecomesABatteryReading() {
        var r = reader()
        let first = r.receiveGATT(Data(packet(7, parameters: [0, 0, 1]).dropFirst(2)))
        XCTAssertEqual(first.request?.count, 18)
        XCTAssertEqual(first.request?.prefix(2), Data([7, 0x1D]))
        XCTAssertNil(r.receive(packet(7, parameters: [0, 0, 1])).request)
        let capability = r.receive(packet(7, software: 0x1D, parameters: [4, 4, 0]))
        XCTAssertNil(capability.reading)
        XCTAssertEqual(capability.capability?.levels, 4)
        XCTAssertEqual(capability.capability?.coarse, true)
        XCTAssertEqual(capability.capability?.rechargeable, true)
        XCTAssertEqual(r.reading?.status, 1)
        XCTAssertNil(r.receive(packet(7, software: 0x10, parameters: [4, 4, 0])).capability)
        XCTAssertNil(r.receive(packet(7, software: 0x1D, parameters: [0, 4, 0])).capability)
        XCTAssertNil(r.receive(packet(7, software: 0x1D, parameters: [101, 4, 0])).capability)
        XCTAssertNil(r.receive(packet(7, software: 0x1D, parameters: [4, 0xFF, 0])).capability)
        XCTAssertEqual(r.receive(packet(7, software: 0x1D, parameters: [100, 6, 0])).capability?.coarse, false)
    }
    func testOtherReportsClientsAndMalformedDataAreIgnored() {
        var r = reader()
        XCTAssertNil(r.receive(packet(7, software: 2, parameters: [20, 0, 1])).reading)
        XCTAssertNil(r.receive(packet(8, parameters: [20, 0, 1])).reading)
        XCTAssertNil(r.receive(packet(7, parameters: [101, 0, 1])).reading)
        XCTAssertNil(r.receive(packet(7, parameters: [20, 0, 8])).reading)
        XCTAssertNil(r.receive(Data([0x11])).reading)
        var unsupported = HIDPPBattery()
        XCTAssertNil(unsupported.receive(packet(0, parameters: [0, 0, 0])).request)
        XCTAssertNil(unsupported.featureIndex)
    }
}
