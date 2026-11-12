// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// One thing that happened, as Halo noticed it: a line in the event log an agent reads to answer "what happened at
/// 15:00". Written when it happens, never by polling for it. Keys are English and stable; texts Halo made for people
/// (audio events) stay in the app's language, like the diagnostics export.
///
/// Kinds and their events:
/// - `app`: `launched`, `quit`, `sleep`, `wake`, `reversing`, `paused` (detail says why), `truncated`,
///   `state-unreadable`, `battery notifications unavailable`
/// - `device`: `present` (at launch), `connected`, `disconnected`, `lent` and `returned` (a device another Mac lends
///   through Universal Control while the pointer is here)
/// - `battery`: `reading` (first this run; for a speaker or headphones also after each reconnect), `changed`
/// - `setting`: `reverse`, `speed`, `speaker-mic`, `match-settings`, `clipboard`, with `from`, `to` and `by`
///   (`person`, `agent`, `other Mac`)
/// - `tool`: `present` (at launch), `started`, `stopped` (programs with a scroll tap), `blocked`, `unblocked`
/// - `handoff`: `left` (the pointer went to another Mac through Universal Control) and `arrived` (it came back);
///   `stalled` (the other Mac dropped this Mac's keyboard and pointer while they were over there, so they did nothing
///   until Universal Control here noticed), `recovered` (with `detail` "N s") and `cleared` (stopped waiting);
///   `peer-stalled`, `peer-recovered` and `peer-cleared` for the same on the other Mac, logged on the Mac that dropped them
/// - `link`, `clipboard`, `audio`: the line the app logged, in `text`
public struct EventRecord: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case app, device, battery, setting, tool, handoff, link, clipboard, audio
    }

    public static let currentVersion = 1

    public var v = EventRecord.currentVersion
    public var t: Date
    public var kind: Kind
    public var event: String?
    /// The device or program, by the name Halo shows.
    public var device: String?
    /// The same id the diagnostics export gives the device, so an agent can pass it to `--set`.
    public var id: String?
    public var text: String?
    public var detail: String?
    public var percent: Int?
    public var charging: Bool?
    public var from: String?
    public var to: String?
    public var by: String?
    /// Where a battery reading came from: `registry`, `ble` or `bluetoothd`.
    public var source: String?

    public init(t: Date = Date(), kind: Kind, event: String? = nil, device: String? = nil, id: String? = nil, text: String? = nil,
                detail: String? = nil, percent: Int? = nil, charging: Bool? = nil, from: String? = nil, to: String? = nil,
                by: String? = nil, source: String? = nil) {
        self.t = t
        self.kind = kind
        self.event = event
        self.device = device
        self.id = id
        self.text = text
        self.detail = detail
        self.percent = percent
        self.charging = charging
        self.from = from
        self.to = to
        self.by = by
        self.source = source
    }

    /// One English line for people and agents reading in a terminal; the JSON has every field.
    public var summary: String {
        let name = device ?? "?"
        let extra = detail.map { " (\($0))" } ?? ""
        switch kind {
        case .app:
            switch event {
            case "launched": return "Halo launched" + (text.map { " \($0)" } ?? "")
            case "quit": return "Halo quit"
            case "sleep": return "Mac went to sleep"
            case "wake": return "Mac woke up"
            case "reversing": return "reversing scrolls"
            case "paused": return "paused, not reversing" + extra
            case "truncated": return "event log full for today; later events were not kept"
            default: return [event, text].compactMap { $0 }.joined(separator: " ")
            }
        case .device:
            switch event {
            case "present": return "\(name) present" + extra
            case "lent": return "\(name) lent by the other Mac through Universal Control"
            case "returned": return "\(name) went back to the other Mac"
            default: return "\(name) \(event ?? "")" + extra
            }
        case .battery:
            let charge = charging == true ? ", charging" : ""
            let level = percent.map { "\($0)%" } ?? "?"
            if event == "changed", let from { return "\(name) \(from)% → \(level)\(charge)" }
            return "\(name) \(level)\(charge)"
        case .setting:
            let by = self.by.map { " (by \($0))" } ?? ""
            let target = device.map { "\($0) " } ?? ""
            return "\(target)\(event ?? "setting") \(from ?? "?") → \(to ?? "?")\(by)"
        case .tool:
            switch event {
            case "blocked": return "\(text ?? "another program") changed \(name)'s reversed direction back"
            case "unblocked": return "\(name)'s direction is no longer changed back"
            default: return "\(name) \(event == "present" ? "has" : event == "stopped" ? "removed" : "added") a scroll tap" + extra
            }
        case .handoff:
            switch event {
            case "left": return "pointer went to the other Mac"
            case "arrived": return "pointer came back to this Mac"
            case "stalled": return "keyboard and pointer not responding: the other Mac dropped them while they were over there"
            case "recovered": return "keyboard and pointer responding again on this Mac" + extra
            case "cleared": return "stopped waiting for the keyboard and pointer to come back" + extra
            case "peer-stalled": return "the other Mac's keyboard and pointer not responding: this Mac dropped them"
            case "peer-recovered": return "the other Mac's keyboard and pointer responding again" + extra
            case "peer-cleared": return "stopped waiting for the other Mac's keyboard and pointer" + extra
            case "drop-told": return "told the other Mac its keyboard and pointer left this Mac"
            case "lent-again": return "told the other Mac its keyboard and pointer are back on this Mac"
            default: return event ?? ""
            }
        case .link, .clipboard:
            return text ?? ""
        case .audio:
            return "\(name): \(text ?? "")" + (detail.map { " [\($0)]" } ?? "")
        }
    }

    /// `2026-11-04 15:00:12  battery   MX Master 2S 51% → 50%`, in local time.
    public func line(calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
        let time = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return time + "  " + kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0) + " " + summary
    }

    /// The stored line: one JSON object with its keys always in this order, so lines read alike in a text editor.
    public func jsonLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let fields: [(String, Data?)] = [
            ("v", try? encoder.encode(v)), ("t", try? encoder.encode(DiagnosticsReport.timestamp(t))), ("kind", try? encoder.encode(kind)),
            ("event", event.flatMap { try? encoder.encode($0) }), ("device", device.flatMap { try? encoder.encode($0) }),
            ("id", id.flatMap { try? encoder.encode($0) }), ("percent", percent.flatMap { try? encoder.encode($0) }),
            ("charging", charging.flatMap { try? encoder.encode($0) }), ("from", from.flatMap { try? encoder.encode($0) }),
            ("to", to.flatMap { try? encoder.encode($0) }), ("by", by.flatMap { try? encoder.encode($0) }),
            ("source", source.flatMap { try? encoder.encode($0) }), ("text", text.flatMap { try? encoder.encode($0) }),
            ("detail", detail.flatMap { try? encoder.encode($0) }),
        ]
        var line = Data("{".utf8)
        for (index, (key, value)) in fields.compactMap({ field in field.1.map { (field.0, $0) } }).enumerated() {
            if index > 0 { line.append(Data(",".utf8)) }
            line.append(Data("\"\(key)\":".utf8))
            line.append(value)
        }
        line.append(Data("}".utf8))
        return line
    }
}

/// The event log: one file of JSON lines per local day in `folder`, appended as things happen and kept for 30 days.
/// A line goes into the file of the day it is written, even when it tells of a moment just before (a removal confirmed
/// a minute late), so a follower of today's file sees it; readers filter on each line's own time.
/// Writes go through one serial queue, opening the day's file, appending a line and closing it; at a few hundred
/// events a day that costs nothing worth keeping a file open for. Nothing here ever runs on the scroll path.
public final class EventLog {
    public static let keepDays = 30
    /// A day's file stops growing here; one `truncated` line says so. Far above any day seen, it only stops a loop.
    public static let dailyLimit = 5 << 20

    public let folder: URL
    private let queue = DispatchQueue(label: "halo.events", qos: .utility)
    private let calendar: Calendar
    private let now: () -> Date
    private var prunedDay: String?
    private var fullDay: String?
    private var failure: String?
    private var stopped = false
    /// The last write's failure, for the diagnostics export; nil once a write succeeds.
    public var lastError: String? { queue.sync { failure } }

    /// `calendar` follows the person's time zone as it changes, so the app and a later `Halo --events` name days alike.
    public init(folder: URL, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.calendar = calendar
        self.now = now
    }

    /// Appends the event in the background.
    public func record(_ event: EventRecord) {
        queue.async { [self] in write(event) }
    }

    /// Waits for everything recorded so far to be written: before quitting, and in tests.
    public func flush() { queue.sync {} }

    /// Writes what is queued and nothing after: once Halo is being uninstalled, a late event must not bring its
    /// folder back.
    public func stop() { queue.sync { stopped = true } }

    public static func fileName(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day a file holds, from its name; nil for anything that is not one of the log's own files.
    static func day(ofFile name: String, calendar: Calendar) -> Date? {
        guard name.count == 16, name.hasSuffix(".jsonl") else { return nil }
        let parts = name.dropLast(6).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func write(_ event: EventRecord) {
        guard !stopped else { return }
        let today = Self.fileName(now(), calendar: calendar)
        let name = today
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if prunedDay != today {
                prune()
                prunedDay = today
            }
            guard fullDay != name else { return }
            let url = folder.appendingPathComponent(name)
            let (size, tail) = Self.tail(of: url)
            // Already full on an earlier run: it said so then.
            if tail.range(of: Data(#""event":"truncated""#.utf8)) != nil, size + 4096 > Self.dailyLimit {
                fullDay = name
                return
            }
            var line = Data()
            // A line cut short (Halo stopped mid-write) gets its own end, so the next line still reads.
            if let last = tail.last, last != 0x0A { line.append(0x0A) }
            var record = event.jsonLine()
            if size + line.count + record.count + 1 > Self.dailyLimit {
                fullDay = name
                record = EventRecord(t: event.t, kind: .app, event: "truncated").jsonLine()
            }
            line.append(record)
            line.append(0x0A)
            try Self.append(line, to: url)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The file's size and its last bytes.
    static func tail(of url: URL) -> (Int, Data) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, Data()) }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: UInt64(max(0, size - 128)))
        return (size, (try? handle.readToEnd()) ?? Data())
    }

    /// One write with O_APPEND, so two Halo processes writing at once (the old and new copy during a language
    /// relaunch) each land whole at the end rather than over each other.
    static func append(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A short write sets no errno; the disk is likely full.
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    /// Removes the log's own files older than `keepDays`, but never one of the `keepDays` newest: a clock that jumps
    /// ahead (a wrong date at boot, a typo in Date & Time) must not take the log with it, however long it stays wrong.
    /// With a file every day this is the same as counting back from today; with Halo run only now and then, no file
    /// stays past `longestKeep` days. Anything else in the folder stays.
    public static let longestKeep = 366

    private func prune() {
        let today = calendar.startOfDay(for: now())
        guard let oldest = calendar.date(byAdding: .day, value: -Self.keepDays, to: today),
              let limit = calendar.date(byAdding: .day, value: -Self.longestKeep, to: today),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let files = names.compactMap { name in Self.day(ofFile: name, calendar: calendar).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }
        for (index, (name, day)) in files.enumerated() where day < limit || (index >= Self.keepDays && day < oldest) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The events from `since` up to `until`, oldest first, of the given kinds (all when nil). Lines that cannot be
    /// read, such as a half-written last line or a kind from a newer Halo, are skipped. With `limit`, only the newest
    /// that many, read from the end, so an export does not decode a whole busy day.
    public static func read(folder: URL, since: Date, until: Date, kinds: Set<EventRecord.Kind>? = nil, limit: Int? = nil,
                            calendar: Calendar = .autoupdatingCurrent) -> [EventRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        // A file is named by the day it was written: a day earlier than `since` covers a change of time zone, and any
        // later file may hold a line about the past (a removal confirmed only after a night asleep).
        guard let first = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: since)) else { return [] }
        let decoder = DiagnosticsReport.decoder
        let files = names.compactMap { name in day(ofFile: name, calendar: calendar).map { (name, $0) } }
            .filter { $0.1 >= first }.sorted { $0.1 > $1.1 }
        var result: [EventRecord] = []
        for (name, _) in files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            var found: [EventRecord] = []
            for line in data.split(separator: 0x0A).reversed() {
                guard let event = try? decoder.decode(EventRecord.self, from: line),
                      event.t >= since, event.t <= until, kinds?.contains(event.kind) ?? true else { continue }
                found.append(event)
                if let limit, result.count + found.count >= limit { break }
            }
            result += found
            if let limit, result.count >= limit { break }
        }
        return result.sorted { $0.t < $1.t }.suffix(limit ?? .max)
    }

    /// Whether the log has any file yet.
    public static func exists(folder: URL, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { day(ofFile: $0, calendar: calendar) != nil }
    }

    /// A time as an agent or person types it: `15:00` (the last such time, today or yesterday), `90m`, `2h`, `3d`,
    /// `today`, `yesterday`, `2026-11-04`, `2026-11-04 15:00` or an ISO 8601 time with its offset.
    /// With `endOfDay`, a bare day (`today`, `yesterday`, `2026-11-04`) means its end rather than its start, for
    /// `--until`.
    public static func parseTime(_ text: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, endOfDay: Bool = false) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let dayEnd = { (start: Date?) -> Date? in
            guard let start, endOfDay else { return start }
            return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
        }
        if text == "now" { return now }
        if text == "today" { return dayEnd(calendar.startOfDay(for: now)) }
        if text == "yesterday" { return dayEnd(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))) }
        if let unit = text.last, let amount = Double(text.dropLast()), amount >= 0, amount.isFinite {
            let seconds: Double? = ["s": 1, "m": 60, "h": 3600, "d": 86400][unit]
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        let clock = { (part: Substring) -> (Int, Int, Int)? in
            let numbers = part.split(separator: ":").map { Int($0) }
            guard (2...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
            let h = numbers[0]!, m = numbers[1]!, s = numbers.count == 3 ? numbers[2]! : 0
            guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s) else { return nil }
            return (h, m, s)
        }
        if let (h, m, s) = clock(Substring(text)) {
            guard let today = calendar.date(bySettingHour: h, minute: m, second: s, of: now) else { return nil }
            return today > now ? calendar.date(byAdding: .day, value: -1, to: today) : today
        }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text.uppercased()) { return date }
        }
        let pieces = text.split(whereSeparator: { $0 == " " || $0 == "t" })
        guard (1...2).contains(pieces.count) else { return nil }
        let ymd = pieces[0].split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3, pieces[0].split(separator: "-").count == 3 else { return nil }
        var components = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2])
        if pieces.count == 2 {
            guard let (h, m, s) = clock(pieces[1]) else { return nil }
            components.hour = h
            components.minute = m
            components.second = s
        }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == ymd[2], calendar.component(.month, from: date) == ymd[1] else { return nil }
        return pieces.count == 1 ? dayEnd(date) : date
    }
}

/// What is there now against what was there before, by a stable key: the first update is the baseline, later ones
/// say what came and what went. Used for devices and for programs with a scroll tap.
public struct Presence<Item> {
    private var known: [String: Item]?
    /// Items missing from the last update but not yet counted as gone, with when that update was.
    private var missing: [String: Date] = [:]
    /// Counts something as gone only once it is missing from two updates in a row: a Bluetooth mouse is absent from
    /// the listing taken the moment the Mac wakes and back seconds later, which is no disconnect worth logging.
    public let confirmsRemoval: Bool

    /// With `confirmsRemoval`, how long something must have been missing: listings follow every HID change, so two can
    /// fall within the seconds a waking mouse is away, and one device can come back well after another.
    public let confirmAfter: TimeInterval

    /// Whether something missing from the last update still waits to be confirmed gone by a later one.
    public var awaitingConfirmation: Bool { !missing.isEmpty }

    public init(confirmsRemoval: Bool = false, confirmAfter: TimeInterval = 0) {
        self.confirmsRemoval = confirmsRemoval
        self.confirmAfter = confirmAfter
    }

    /// `removedAt` gives, for each removed item, when it was first missing: an item confirmed gone on a later update
    /// went at the earlier one.
    public mutating func update(_ items: [String: Item], at now: Date = Date())
        -> (present: [Item], added: [Item], removed: [Item], removedAt: [Date]) {
        guard let known else {
            known = items
            return (items.keys.sorted().map { items[$0]! }, [], [], [])
        }
        let added = items.keys.filter { known[$0] == nil }.sorted().map { items[$0]! }
        var removed: [Item] = [], removedAt: [Date] = [], waiting: [String: Item] = [:], stillMissing: [String: Date] = [:]
        for key in known.keys.sorted() where items[key] == nil {
            if !confirmsRemoval || missing[key].map({ now.timeIntervalSince($0) >= confirmAfter }) == true {
                removed.append(known[key]!)
                removedAt.append(missing[key] ?? now)
            } else {
                waiting[key] = known[key]!
                stillMissing[key] = missing[key] ?? now
            }
        }
        missing = stillMissing
        self.known = items.merging(waiting) { current, _ in current }
        return ([], added, removed, removedAt)
    }
}

/// Battery levels as last logged, so only a new level, a change in charging, or a device's first reading becomes an
/// event. The 30-second registry reads and the Bluetooth daemon's reports every few seconds stay out of the log.
public struct BatteryLedger {
    public struct Reading: Equatable {
        public let id: String
        public let name: String
        public let percent: Int
        public let charging: Bool
        public let source: String
        public init(id: String, name: String, percent: Int, charging: Bool, source: String) {
            self.id = id
            self.name = name
            self.percent = percent
            self.charging = charging
            self.source = source
        }
    }

    private var last: [String: Reading] = [:]

    public init() {}

    /// The events for one reading; empty when nothing changed.
    public mutating func note(_ reading: Reading, at time: Date = Date()) -> [EventRecord] {
        let previous = last[reading.id]
        last[reading.id] = reading
        if let previous, previous.percent == reading.percent, previous.charging == reading.charging { return [] }
        return [EventRecord(t: time, kind: .battery, event: previous == nil ? "reading" : "changed", device: reading.name, id: reading.id,
                            percent: reading.percent, charging: reading.charging, from: previous.map { String($0.percent) },
                            source: reading.source)]
    }

    /// A set of readings. One missing from it is not forgotten: a Bluetooth LE level drops out of the list and comes
    /// back every half minute or so, and coming back at the same level is no news.
    public mutating func update(_ readings: [Reading], at time: Date = Date()) -> [EventRecord] {
        readings.flatMap { note($0, at: time) }
    }

    public mutating func forget(_ id: String) { last[id] = nil }
}

/// Reads what is appended to the event log after it starts: the complete lines added to the day's file since the last
/// call, moving on to the next day's file once there is one. It is called when the file system says the folder or the
/// file changed, never on a clock.
public final class EventFollower {
    public let folder: URL
    private let calendar: Calendar
    public private(set) var file: String
    private var offset: UInt64 = 0
    private var partial = Data()

    /// Starts at the end of today's file, so only what is logged from now on comes out.
    public init(folder: URL, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.folder = folder
        self.calendar = calendar
        file = EventLog.fileName(now, calendar: calendar)
        offset = Self.size(folder.appendingPathComponent(file))
    }

    public var url: URL { folder.appendingPathComponent(file) }

    /// The events logged since the last call, oldest first; a line still being written waits for its end.
    public func next(now: Date = Date()) -> [EventRecord] {
        var events = readNew()
        let today = EventLog.fileName(now, calendar: calendar)
        if today != file {
            file = today
            offset = 0
            partial = Data()
            events += readNew()
        }
        return events
    }

    private func readNew() -> [EventRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            offset = 0
            partial = Data()
        }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        guard let end = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = partial[partial.startIndex...end]
        partial = Data(partial[partial.index(after: end)...])
        let decoder = DiagnosticsReport.decoder
        return complete.split(separator: 0x0A).compactMap { try? decoder.decode(EventRecord.self, from: $0) }
    }

    private static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
}
