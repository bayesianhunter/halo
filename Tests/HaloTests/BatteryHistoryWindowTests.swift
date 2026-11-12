// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class BatteryHistoryWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ daysAgo: Double, id: String = "keyboard") -> EventRecord {
        EventRecord(t: now.addingTimeInterval(-daysAgo * 86400), kind: .battery, id: id, percent: 50)
    }

    func testInitialLoadKeepsBoundaryAndDropsExpiredDevices() {
        let boundary = event(30), current = event(1)
        let history = BatteryHistoryWindow(events: ["keyboard": [event(31), boundary, current], "gone": [event(31, id: "gone")]], now: now)
        XCTAssertEqual(history.events, ["keyboard": [boundary, current]])
    }

    func testNewReadingDuringLongRunReleasesOtherDevicesHistory() {
        var history = BatteryHistoryWindow(events: ["gone": [event(29, id: "gone")]], now: now)
        let later = now.addingTimeInterval(2 * 86400)
        let fresh = EventRecord(t: later, kind: .battery, id: "new", percent: 80)
        XCTAssertTrue(history.append(fresh, now: later))
        XCTAssertEqual(history.events, ["new": [fresh]])
    }

    func testForecastRequestCanTrimWithoutAnyNewReading() {
        var history = BatteryHistoryWindow(events: ["keyboard": [event(29)]], now: now)
        XCTAssertFalse(history.trimIfNeeded(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(history.trimIfNeeded(at: now.addingTimeInterval(2 * 86400)))
        XCTAssertTrue(history.events.isEmpty)
        history.append(event(31), now: now.addingTimeInterval(2 * 86400))
        XCTAssertTrue(history.events.isEmpty, "a late reading cannot restore expired history")
    }

    func testBackwardsClockPreservesReadingsAndResetsCheckTime() {
        var history = BatteryHistoryWindow(events: ["keyboard": [event(1)]], now: now)
        XCTAssertFalse(history.trimIfNeeded(at: now.addingTimeInterval(-3 * 86400)))
        XCTAssertEqual(history.events["keyboard"], [event(1)])
        XCTAssertTrue(history.trimIfNeeded(at: now.addingTimeInterval(31 * 86400)))
        XCTAssertTrue(history.events.isEmpty)
    }
}
