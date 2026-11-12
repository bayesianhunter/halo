// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// How long a battery lasts, from the levels the log holds; and following the log as it grows.
final class ForecastTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_793_000_000)

    func reading(_ hours: Double, _ percent: Int, charging: Bool = false) -> BatteryForecast.Reading {
        .init(t: start.addingTimeInterval(hours * 3600), percent: percent, charging: charging)
    }

    func testASteadyDrainGivesDaysLeft() throws {
        // 2 points a day for five days, read as each point drops.
        let readings = (0...10).map { reading(Double($0) * 12, 60 - $0) }
        let now = start.addingTimeInterval(120 * 3600)
        let forecast = try XCTUnwrap(BatteryForecast.estimate(readings, now: now))
        XCTAssertEqual(forecast.perDay, 2, accuracy: 0.01)
        XCTAssertEqual(forecast.days, 25, accuracy: 0.1)
        XCTAssertEqual(forecast.basedOnDays, 5)
        XCTAssertEqual(forecast.at(now.addingTimeInterval(6 * 3600)).days, 24.75, accuracy: 0.01, "counts down between readings")
        XCTAssertEqual(forecast.at(now.addingTimeInterval(10 * 86400)).days, 24.5, accuracy: 0.01,
                       "but no further than one point: a drop would have been logged")
    }

    func testTheShownTextChangesOnlyAtItsSteps() throws {
        // 50% at 2 points a day: "about 25 days" until 24.5 days are left, half a day later. That is also when a
        // point's worth of time has passed, after which it waits for the next reading.
        let days = BatteryForecast(percent: 50, readAt: start, perDay: 2, since: start.addingTimeInterval(-5 * 86400), days: 25)
        XCTAssertEqual(days.shown, .days(25))
        XCTAssertEqual(try XCTUnwrap(days.nextChange(after: start)).timeIntervalSince(start), 43200, accuracy: 1)
        XCTAssertNil(days.nextChange(after: start.addingTimeInterval(43201)), "no longer counting down")
        // 2% at 30 a day: 1.6 hours, shown as 2, then 1 from 1.5 hours left, then almost empty below an hour.
        let hours = BatteryForecast(percent: 2, readAt: start, perDay: 30, since: start.addingTimeInterval(-86400), days: 2.0 / 30)
        XCTAssertEqual(hours.shown, .hours(2))
        let first = try XCTUnwrap(hours.nextChange(after: start))
        XCTAssertEqual(first.timeIntervalSince(start), 0.1 * 3600, accuracy: 1)
        XCTAssertEqual(hours.at(first.addingTimeInterval(1)).shown, .hours(1))
        let second = try XCTUnwrap(hours.nextChange(after: first.addingTimeInterval(1)))
        XCTAssertEqual(second.timeIntervalSince(start), 0.6 * 3600, accuracy: 1)
        XCTAssertEqual(hours.at(second.addingTimeInterval(1)).shown, .almostEmpty)
        XCTAssertNil(hours.nextChange(after: second.addingTimeInterval(1)))
    }

    func testNothingUntilADayAndThreePoints() {
        XCTAssertNil(BatteryForecast.estimate([reading(0, 60), reading(20, 55)]), "under a day")
        XCTAssertNil(BatteryForecast.estimate([reading(0, 60), reading(30, 58)]), "two points in a day and a bit")
        XCTAssertNotNil(BatteryForecast.estimate([reading(0, 60), reading(30, 57)]))
        XCTAssertNil(BatteryForecast.estimate([]))
    }

    func testOnlyTheDischargeSinceTheLastCharge() throws {
        // Fast drain before a charge, slow after: only the slow part counts.
        var readings = (0...4).map { reading(Double($0) * 6, 50 - $0 * 5) }
        readings.append(reading(30, 40, charging: true))
        readings += (0...6).map { reading(40 + Double($0) * 8, 90 - $0) }
        let forecast = try XCTUnwrap(BatteryForecast.estimate(readings, now: readings.last!.t))
        XCTAssertEqual(forecast.perDay, 3, accuracy: 0.05)
        XCTAssertEqual(forecast.since, start.addingTimeInterval(40 * 3600))
    }

    func testARiseWithoutACableIsACharge() throws {
        // A Logitech mouse charged over USB says nothing over Bluetooth; its level just comes back higher.
        let readings = [reading(0, 30), reading(24, 20), reading(30, 95), reading(60, 93), reading(80, 91)]
        let forecast = try XCTUnwrap(BatteryForecast.estimate(readings, now: readings.last!.t))
        XCTAssertEqual(forecast.since, start.addingTimeInterval(30 * 3600))
        XCTAssertGreaterThan(forecast.days, 40)
    }

    func testAOnePointWaverDoesNotRestart() throws {
        let readings = [reading(0, 60), reading(10, 59), reading(14, 60), reading(30, 57), reading(40, 56)]
        let forecast = try XCTUnwrap(BatteryForecast.estimate(readings, now: readings.last!.t))
        XCTAssertEqual(forecast.since, start)
    }

    func testNoneForADeviceThatReportsInSteps() {
        // Like the MX Master 2S: 90, then 50 days later, then 20.
        XCTAssertNil(BatteryForecast.estimate([reading(0, 90), reading(48, 50), reading(200, 50), reading(300, 20)]))
        XCTAssertNil(BatteryForecast.estimate([reading(0, 50), reading(10, 20), reading(20, 90), reading(80, 50)]),
                     "even after a charge: it still reports in steps")
    }

    func testAGapInTheReadingsIsNotCoarse() throws {
        // A keyboard read one point at a time, then not read for four days: one 12-point drop beside small ones.
        let readings = [reading(0, 76), reading(10, 75), reading(20, 74), reading(116, 62), reading(130, 61), reading(140, 60)]
        let forecast = try XCTUnwrap(BatteryForecast.estimate(readings, now: readings.last!.t))
        XCTAssertEqual(forecast.since, start)
    }

    func testNoneWhileChargingOrRising() {
        XCTAssertNil(BatteryForecast.estimate([reading(0, 60), reading(30, 50), reading(31, 52, charging: true)]))
        XCTAssertNil(BatteryForecast.estimate([reading(0, 50), reading(30, 51), reading(40, 52)]))
    }

    func testReadingsFromTheLog() {
        let events = [EventRecord(t: start, kind: .battery, event: "reading", id: "k", percent: 50, source: "ble"),
                      EventRecord(t: start, kind: .link, text: "x"),
                      EventRecord(t: start, kind: .battery, event: "changed", id: "k", percent: 49, charging: true)]
        XCTAssertEqual(BatteryForecast.readings(events), [.init(t: start, percent: 50, charging: false), .init(t: start, percent: 49, charging: true)])
    }

    func testFollowingTheLog() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("halo-follow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 59))!
        let log = EventLog(folder: folder, calendar: calendar, now: { day })
        log.record(EventRecord(t: day, kind: .link, text: "before"))
        log.flush()
        let follower = EventFollower(folder: folder, now: day, calendar: calendar)
        XCTAssertTrue(follower.next(now: day).isEmpty, "only what comes after it starts")
        log.record(EventRecord(t: day, kind: .link, text: "one"))
        log.flush()
        XCTAssertEqual(follower.next(now: day).map(\.text), ["one"])
        // Half a line: it waits for the rest.
        let url = folder.appendingPathComponent("2026-11-04.jsonl")
        let line = EventRecord(t: day, kind: .link, text: "two").jsonLine() + Data([0x0A])
        try EventLog.append(line.prefix(10), to: url)
        XCTAssertTrue(follower.next(now: day).isEmpty)
        try EventLog.append(line.dropFirst(10), to: url)
        XCTAssertEqual(follower.next(now: day).map(\.text), ["two"])
        // Past midnight it moves to the new day's file.
        let next = day.addingTimeInterval(120)
        try EventLog.append(EventRecord(t: next, kind: .app, event: "wake").jsonLine() + Data([0x0A]),
                            to: folder.appendingPathComponent("2026-11-05.jsonl"))
        XCTAssertEqual(follower.next(now: next).map(\.event), ["wake"])
        XCTAssertEqual(follower.file, "2026-11-05.jsonl")
    }
}
