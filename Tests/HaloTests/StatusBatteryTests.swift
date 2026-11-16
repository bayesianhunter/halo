// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class StatusBatteryTests: XCTestCase {
    func testOnlyUnattendedLowBatteriesTakePriority() {
        let a = Battery(name: "A", serial: "a", percent: 5)
        let b = Battery(name: "B", serial: "b", percent: 10)
        let chargingA = Battery(name: "A", serial: "a", percent: 5, charging: true)
        let chargingB = Battery(name: "B", serial: "b", percent: 10, charging: true)
        XCTAssertEqual(Battery.indicator([a, b]), a)
        XCTAssertEqual(Battery.indicator([chargingA, b]), b)
        XCTAssertEqual(Battery.indicator([chargingA, chargingB]), chargingA)
        XCTAssertNil(Battery.lowest([chargingA, chargingB]))
    }

    func testEqualLevelsKeepTheSelectedDeviceButNotAfterItsStateChanges() {
        let a = Battery(name: "A", serial: "a", percent: 10)
        let b = Battery(name: "B", serial: "b", percent: 10)
        XCTAssertEqual(Battery.indicator([a, b], keeping: b), b)
        let chargingB = Battery(name: "B", serial: "b", percent: 10, charging: true)
        XCTAssertEqual(Battery.indicator([chargingB, a], keeping: b), a)
        XCTAssertEqual(Battery.indicator([a], keeping: b), a)
    }

    func testZeroThresholdFullAndMissingReadings() {
        let empty = Battery(name: "Empty", serial: "", percent: 0)
        XCTAssertEqual(Battery.indicator([empty])?.percent, 0)
        XCTAssertNotNil(Battery.indicator([Battery(name: "Low", serial: "", percent: 20)]))
        XCTAssertNil(Battery.indicator([Battery(name: "Normal", serial: "", percent: 21)]))
        XCTAssertNotNil(Battery.indicator([Battery(name: "Full", serial: "", percent: 100, charging: true)]))
        XCTAssertNil(Battery.indicator([Battery(name: "Full", serial: "", percent: 100)]))
        XCTAssertNil(Battery.indicator([]))
    }

    func testFullOnCableIsExplicitAndComesAfterLowAndCharging() {
        let full = Battery(name: "Full", serial: "f", percent: 100, chargedOnCable: true)
        let low = Battery(name: "Low", serial: "l", percent: 10)
        let charging = Battery(name: "Charging", serial: "c", percent: 80, charging: true)
        XCTAssertEqual(Battery.indicator([full]), full)
        XCTAssertEqual(Battery.indicator([full, charging]), charging)
        XCTAssertEqual(Battery.indicator([full, charging, low]), low)
        XCTAssertFalse(Battery(name: "Unplugged", serial: "", percent: 100).chargedOnCable)
        XCTAssertFalse(Battery(name: "Not full", serial: "", percent: 90, chargedOnCable: true).chargedOnCable)
        XCTAssertFalse(Battery(name: "Charging", serial: "", percent: 100, charging: true, chargedOnCable: true).chargedOnCable)
    }

    func testUpdateOwnsPointUntilClearedThenFullReturnsAndUnplugClearsIt() {
        let full = Battery(name: "Full", serial: "f", percent: 100, chargedOnCable: true)
        XCTAssertEqual(Battery.indicatorPoint(for: full, updateAvailable: true), .update)
        XCTAssertEqual(Battery.indicatorPoint(for: full, updateAvailable: false), .charged)
        let unplugged = Battery(name: "Full", serial: "f", percent: 100)
        XCTAssertNil(Battery.indicator([unplugged]))
        XCTAssertEqual(Battery.indicatorPoint(for: unplugged, updateAvailable: false), .ordinary)
        XCTAssertEqual(Battery.indicatorPoint(for: nil, updateAvailable: true), .update)
        for battery in [Battery(name: "Low", serial: "", percent: 5), Battery(name: "Charging", serial: "", percent: 90, charging: true)] {
            XCTAssertEqual(Battery.indicatorPoint(for: battery, updateAvailable: true), .update)
            XCTAssertEqual(Battery.indicatorPoint(for: battery, updateAvailable: false), .ordinary)
        }
    }
}
