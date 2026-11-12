// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// The event log: what is written, what is read back, what is kept, and how a typed time is understood.
final class EventsTests: XCTestCase {
    var folder: URL!
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("halo-events-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func date(_ text: String) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: Int(text.prefix(4)), month: Int(text.dropFirst(5).prefix(2)),
                                           day: Int(text.dropFirst(8).prefix(2)), hour: Int(text.dropFirst(11).prefix(2)),
                                           minute: Int(text.dropFirst(14).prefix(2)), second: 0))!
    }

    func testWritesOneLinePerEventAndReadsThemBack() throws {
        let now = date("2026-11-04 15:00")
        let log = EventLog(folder: folder, calendar: calendar, now: { now })
        let battery = EventRecord(t: now, kind: .battery, event: "changed", device: "MX Master 2S", id: "a1b2c3", percent: 50,
                                  charging: false, from: "51", source: "ble")
        log.record(EventRecord(t: now.addingTimeInterval(-60), kind: .app, event: "launched", text: "0.7.0 (15)"))
        log.record(battery)
        log.flush()
        let text = try String(contentsOf: folder.appendingPathComponent("2026-11-04.jsonl"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\"to\""), "absent fields stay out of the line")
        // `t` is written in this Mac's own time zone (as the export is), whichever calendar names the files.
        let t = DiagnosticsReport.timestamp(now.addingTimeInterval(-60))
        XCTAssertTrue(text.hasPrefix(#"{"v":1,"t":""# + t + #"","kind":"app","event":"launched","text":"0.7.0 (15)"}"#),
                      "keys keep one order: \(text)")
        let read = EventLog.read(folder: folder, since: now.addingTimeInterval(-3600), until: now, calendar: calendar)
        XCTAssertEqual(read.map(\.event), ["launched", "changed"])
        XCTAssertEqual(read.last?.percent, 50)
        XCTAssertEqual(read.last?.from, "51")
        XCTAssertEqual(battery.summary, "MX Master 2S 51% → 50%")
    }

    func testEachLocalDayHasItsOwnFileAndReadsSpanThem() {
        let night = date("2026-11-03 23:59")
        var clock = night
        let log = EventLog(folder: folder, calendar: calendar, now: { clock })
        log.record(EventRecord(t: night, kind: .app, event: "sleep"))
        log.flush()
        clock = date("2026-11-04 08:00")
        log.record(EventRecord(t: clock, kind: .app, event: "wake"))
        log.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted()
        XCTAssertEqual(names, ["2026-11-03.jsonl", "2026-11-04.jsonl"])
        let read = EventLog.read(folder: folder, since: date("2026-11-03 20:00"), until: clock, calendar: calendar)
        XCTAssertEqual(read.map(\.event), ["sleep", "wake"])
        XCTAssertEqual(EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: clock, calendar: calendar).map(\.event), ["wake"])
    }

    func testFilesOlderThanThirtyDaysGoAndNothingElseIsTouched() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file every day: the newest 30 are all within 30 days, so age decides (see `EventLogKeepingTests`).
        let daily = (5...31).map { String(format: "2026-10-%02d.jsonl", $0) } + (1...3).map { String(format: "2026-11-%02d.jsonl", $0) }
        for name in ["2026-10-04.jsonl", "notes.txt", "2020-01-01.json"] + daily {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        let now = date("2026-11-04 09:00")
        let log = EventLog(folder: folder, calendar: calendar, now: { now })
        log.record(EventRecord(t: now, kind: .app, event: "launched"))
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, (["2020-01-01.json", "2026-11-04.jsonl", "notes.txt"] + daily).sorted())
    }

    func testAFullDayStopsGrowingWithOneTruncatedLine() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("2026-11-04.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x20, count: EventLog.dailyLimit - 10))
        let now = date("2026-11-04 12:00")
        let log = EventLog(folder: folder, calendar: calendar, now: { now })
        for _ in 0..<3 { log.record(EventRecord(t: now, kind: .link, text: "retry in 30 s")) }
        log.flush()
        let read = EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: now, calendar: calendar)
        XCTAssertEqual(read.map(\.event), ["truncated"])
    }

    func testBadLinesAndOtherKindsAreSkippedAndKindsFilter() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = date("2026-11-04 12:00")
        let lines = [
            #"{"v":1,"t":"2026-11-04T11:00:00.000+08:00","kind":"link","text":"disconnected"}"#,
            #"{"v":2,"t":"2026-11-04T11:01:00.000+08:00","kind":"teleport"}"#,
            #"{"v":1,"t":"2026-11-04T11:02:00.000+08:00","kind":"battery","device":"Keyboard","percent":52}"#,
            #"{"v":1,"t":"2026-11-04T11:03"#,
        ]
        try (lines.joined(separator: "\n")).write(to: folder.appendingPathComponent("2026-11-04.jsonl"), atomically: true, encoding: .utf8)
        let all = EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: now, calendar: calendar)
        XCTAssertEqual(all.map(\.kind), [.link, .battery])
        let battery = EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: now, kinds: [.battery], calendar: calendar)
        XCTAssertEqual(battery.map(\.device), ["Keyboard"])
    }

    func testCutLinesAndFullDaysAcrossRuns() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("2026-11-04.jsonl")
        try Data(#"{"v":1,"t":"2026-11-04T11:00:00.000+08:00","kind":"link","te"#.utf8).write(to: url)
        let now = date("2026-11-04 12:00")
        var log = EventLog(folder: folder, calendar: calendar, now: { now })
        log.record(EventRecord(t: now, kind: .app, event: "launched"))
        log.flush()
        XCTAssertEqual(EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: now, calendar: calendar).map(\.event), ["launched"],
                       "a line cut short by a crash does not swallow the next one")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x20, count: EventLog.dailyLimit - 10))
        log.record(EventRecord(t: now, kind: .link, text: "retry in 30 s"))
        log.flush()
        log = EventLog(folder: folder, calendar: calendar, now: { now })
        log.record(EventRecord(t: now, kind: .app, event: "launched"))
        log.flush()
        let events = EventLog.read(folder: folder, since: date("2026-11-04 00:00"), until: now, calendar: calendar)
        XCTAssertEqual(events.map(\.event), ["truncated"], "a later run does not say it again")
    }

    func testReadingTheNewestOnly() throws {
        let now = date("2026-11-04 12:00")
        let log = EventLog(folder: folder, calendar: calendar, now: { now })
        for minute in 0..<50 { log.record(EventRecord(t: now.addingTimeInterval(Double(minute - 50) * 60), kind: .link, text: "\(minute)")) }
        log.flush()
        let newest = EventLog.read(folder: folder, since: now.addingTimeInterval(-86400), until: now, limit: 5, calendar: calendar)
        XCTAssertEqual(newest.map(\.text), ["45", "46", "47", "48", "49"])
    }

    func testTypedTimes() {
        let now = date("2026-11-04 14:30")
        let parse = { (text: String) in EventLog.parseTime(text, now: now, calendar: self.calendar) }
        XCTAssertEqual(parse("15:00"), date("2026-11-03 15:00"), "a clock time later than now is yesterday's")
        XCTAssertEqual(parse("09:15"), date("2026-11-04 09:15"))
        XCTAssertEqual(parse("2h"), now.addingTimeInterval(-7200))
        XCTAssertEqual(parse("90m"), now.addingTimeInterval(-5400))
        XCTAssertEqual(parse("3d"), now.addingTimeInterval(-3 * 86400))
        XCTAssertEqual(parse("today"), date("2026-11-04 00:00"))
        XCTAssertEqual(parse("Yesterday"), date("2026-11-03 00:00"))
        XCTAssertEqual(parse("2026-11-02"), date("2026-11-02 00:00"))
        XCTAssertEqual(parse("2026-11-02 15:00"), date("2026-11-02 15:00"))
        XCTAssertEqual(parse("2026-11-02T15:00"), date("2026-11-02 15:00"))
        XCTAssertEqual(parse("2026-11-02T07:00:00Z"), date("2026-11-02 15:00"))
        XCTAssertEqual(parse("2026-11-02T15:00:00+08:00"), date("2026-11-02 15:00"))
        let end = { (text: String) in EventLog.parseTime(text, now: now, calendar: self.calendar, endOfDay: true) }
        XCTAssertEqual(end("2026-11-02"), date("2026-11-03 00:00").addingTimeInterval(-0.001), "a bare day ends --until")
        XCTAssertEqual(end("yesterday"), date("2026-11-04 00:00").addingTimeInterval(-0.001))
        XCTAssertEqual(end("2026-11-02 15:00"), date("2026-11-02 15:00"), "a time stays a time")
        for bad in ["", "soon", "25:00", "2026-13-01", "2026-02-30", "-2h", "12"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    func testPresenceGivesABaselineThenChanges() {
        var presence = Presence<String>()
        let first = presence.update(["a": "Mouse", "b": "Trackpad"])
        XCTAssertEqual(first.present, ["Mouse", "Trackpad"])
        XCTAssertTrue(first.added.isEmpty && first.removed.isEmpty)
        XCTAssertTrue(presence.update(["a": "Mouse", "b": "Trackpad"]) == ([], [], [], []))
        let next = presence.update(["b": "Trackpad", "c": "V-Keyboard"])
        XCTAssertEqual(next.added, ["V-Keyboard"])
        XCTAssertEqual(next.removed, ["Mouse"])
        XCTAssertTrue(next.present.isEmpty)
    }

    func testARemovalCanWaitForASecondListing() {
        var presence = Presence<String>(confirmsRemoval: true)
        _ = presence.update(["m": "Mouse", "t": "Trackpad"])
        XCTAssertTrue(presence.update(["t": "Trackpad"]).removed.isEmpty, "missing from the listing taken at wake")
        let back = presence.update(["m": "Mouse", "t": "Trackpad"])
        XCTAssertTrue(back.added.isEmpty && back.removed.isEmpty, "back before the next listing: nothing happened")
        XCTAssertTrue(presence.update(["t": "Trackpad"]).removed.isEmpty)
        XCTAssertEqual(presence.update(["t": "Trackpad"]).removed, ["Mouse"], "still gone: disconnected")
        XCTAssertEqual(presence.update(["m": "Mouse", "t": "Trackpad"]).added, ["Mouse"])
    }

    func testBatteryLedgerLogsOnlyNewLevels() {
        var ledger = BatteryLedger()
        let reading = { (percent: Int, charging: Bool) in
            BatteryLedger.Reading(id: "k1", name: "Keyboard", percent: percent, charging: charging, source: "registry")
        }
        XCTAssertEqual(ledger.update([reading(52, false)]).map(\.event), ["reading"])
        XCTAssertTrue(ledger.update([reading(52, false)]).isEmpty, "the 30-second read repeats itself")
        let drop = ledger.update([reading(51, false)])
        XCTAssertEqual(drop.map(\.event), ["changed"])
        XCTAssertEqual(drop.first?.from, "52")
        XCTAssertEqual(ledger.update([reading(51, true)]).first?.charging, true, "a cable going in is news")
        XCTAssertTrue(ledger.update([]).isEmpty)
        XCTAssertTrue(ledger.update([reading(51, true)]).isEmpty, "an empty list leaves it alone")
        XCTAssertTrue(ledger.update([]).isEmpty)
        XCTAssertTrue(ledger.update([reading(51, true)]).isEmpty, "back at the same level is no news")
        XCTAssertEqual(ledger.update([reading(50, true)]).first?.from, "51")
        ledger.forget("k1")
        XCTAssertEqual(ledger.note(reading(50, false)).map(\.event), ["reading"])
    }

    func testSummaries() {
        let t = date("2026-11-04 15:00")
        XCTAssertEqual(EventRecord(t: t, kind: .setting, event: "reverse", device: "MX Master 2S", from: "off", to: "on", by: "agent").summary,
                       "MX Master 2S reverse off → on (by agent)")
        XCTAssertEqual(EventRecord(t: t, kind: .device, event: "lent", device: "Magic Trackpad").summary,
                       "Magic Trackpad lent by the other Mac through Universal Control")
        XCTAssertEqual(EventRecord(t: t, kind: .tool, event: "started", device: "Mos", detail: "can modify scrolling").summary,
                       "Mos added a scroll tap (can modify scrolling)")
        XCTAssertEqual(EventRecord(t: t, kind: .app, event: "paused", detail: "no Accessibility permission").summary,
                       "paused, not reversing (no Accessibility permission)")
        XCTAssertEqual(EventRecord(t: t, kind: .handoff, event: "left").summary, "pointer went to the other Mac")
        XCTAssertEqual(EventRecord(t: t, kind: .handoff, event: "arrived").summary, "pointer came back to this Mac")
        XCTAssertEqual(EventRecord(t: t, kind: .link, text: "disconnected").line(calendar: calendar),
                       "2026-11-04 15:00:00  link      disconnected")
    }

    func testDiagnosticsCarriesRecentEvents() throws {
        var report = DiagnosticsReport(source: "live", app: .init(version: "0.7.0", build: "15", macOS: "macOS 27.2", language: "en",
                                                                  exportedAt: date("2026-11-04 15:00"), uptime: 1),
                                       state: .init(appRunning: true, accessibility: true, recordScrolls: false, showIcon: true))
        report.events = [EventRecord(t: date("2026-11-04 14:00"), kind: .link, text: "disconnected")]
        report.eventsFolder = "/tmp/events"
        let data = try DiagnosticsReport.encoder.encode(report)
        XCTAssertEqual(try DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: data), report)
        XCTAssertTrue(report.markdown.contains("## Recent events"))
        XCTAssertTrue(report.markdown.contains("disconnected"))
    }
}

/// Regression: the log survives a clock that jumps ahead, and a late line lands where a follower looks.
final class EventLogKeepingTests: XCTestCase {
    var folder: URL!
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("halo-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    func testAClockThatJumpsAheadKeepsTheLog() throws {
        let names = (1...10).map { String(format: "2026-11-%02d.jsonl", $0) }
        for name in names { FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data()) }
        let jumped = day(2027, 2, 20)
        let log = EventLog(folder: folder, calendar: calendar, now: { jumped })
        log.record(EventRecord(t: jumped, kind: .app, event: "launched"))
        log.flush()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, names + ["2027-02-20.jsonl"], "nothing the real clock would keep is removed")
    }

    func testTheJumpedClockStaysWrongForDaysAndRelaunches() throws {
        let real = (1...10).map { String(format: "2026-11-%02d.jsonl", $0) }
        for name in real { FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data()) }
        for jumpedDay in [20, 20, 21, 22] {
            let now = day(2027, 2, jumpedDay)
            let log = EventLog(folder: folder, calendar: calendar, now: { now })
            log.record(EventRecord(t: now, kind: .app, event: "launched"))
            log.flush()
        }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(Set(real).isSubset(of: left), "relaunching and crossing midnight with the wrong date keep the real days")
    }

    func testRunNowAndThenNothingStaysPastAYear() throws {
        for name in ["2025-09-01.jsonl", "2026-01-10.jsonl"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        let now = day(2026, 11, 5)
        let log = EventLog(folder: folder, calendar: calendar, now: { now })
        log.record(EventRecord(t: now, kind: .app, event: "launched"))
        log.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["2026-01-10.jsonl", "2026-11-05.jsonl"],
                       "few files: the newest stay, but not past \(EventLog.longestKeep) days")
    }

    func testALineAboutDaysAgoIsFoundByAReadOfThatDay() {
        let switchedOff = day(2026, 11, 4, 23, 50)
        let woke = day(2026, 11, 7, 9, 0)
        let log = EventLog(folder: folder, calendar: calendar, now: { woke })
        log.record(EventRecord(t: switchedOff, kind: .device, event: "disconnected", device: "Mouse"))
        log.flush()
        let read = EventLog.read(folder: folder, since: day(2026, 11, 4, 0, 0), until: day(2026, 11, 4, 23, 59, 59), calendar: calendar)
        XCTAssertEqual(read.map(\.event), ["disconnected"], "confirmed after a night asleep, it is still the 4th's")
    }

    func testALateLineGoesIntoTodaysFileWhereTheFollowerLooks() {
        let missing = day(2026, 11, 4, 23, 59, 30)
        let confirmed = day(2026, 11, 5, 0, 0, 40)
        let follower = EventFollower(folder: folder, now: day(2026, 11, 5, 0, 0, 10), calendar: calendar)
        let log = EventLog(folder: folder, calendar: calendar, now: { confirmed })
        log.record(EventRecord(t: missing, kind: .device, event: "disconnected", device: "Mouse"))
        log.flush()
        XCTAssertEqual(follower.next(now: confirmed).map(\.event), ["disconnected"])
        let read = EventLog.read(folder: folder, since: day(2026, 11, 4, 23, 0), until: day(2026, 11, 4, 23, 59, 59), calendar: calendar)
        XCTAssertEqual(read.map(\.t), [missing], "a read of the day it happened still finds it")
    }
}
