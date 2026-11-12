// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import HaloCore

/// The event log in Halo's state folder. Only the running app writes it; `Halo --events` only reads it.
let eventLog = EventLog(folder: stateURL.appendingPathComponent("events", isDirectory: true))

/// The app's side of the event log: names and ids as the diagnostics export gives them.
enum Events {
    /// Read once: the export's key, so a device has the same id in both.
    static let idKey: SymmetricKey = DiagnosticsExport.idKey

    /// Main thread: the battery history the window's estimates come from follows every battery line.
    static func record(_ event: EventRecord) {
        eventLog.record(event)
        if event.kind == .battery { BatteryHistory.shared.add(event) }
    }

    static func launched() {
        let info = Bundle.main.infoDictionary
        record(EventRecord(kind: .app, event: "launched",
                           text: "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "dev"))"))
    }

    static func app(_ event: String, detail: String? = nil) { record(EventRecord(kind: .app, event: event, detail: detail)) }

    static func deviceID(_ device: Device) -> String { DiagnosticsReport.deviceID(device, key: idKey) }

    /// A device without a serial gets a new sender, and so a new key, each time it connects; its profile stays the
    /// same, so waking from sleep is not logged as a new device.
    static func presenceKey(_ device: Device) -> String { device.sessionOnly ? device.profileKey : device.key }

    /// `at`: when it happened, if earlier than now (a removal is confirmed on the listing after the one it went missing from).
    static func device(_ device: Device, _ event: String, at: Date = Date()) {
        let parts = [device.trackpad ? "trackpad" : "pointer", device.transport, device.local ? nil : "Universal Control"]
        record(EventRecord(t: at, kind: .device, event: event, device: AppDelegate.displayName(device), id: deviceID(device),
                           detail: parts.compactMap { $0 }.joined(separator: ", ")))
    }

    /// The serials registry readings have shown this run; see `BatterySerials`. Main thread only.
    static var batterySerials = BatterySerials()

    /// One id per battery whichever way it was read, by serial where one is known. It tells a battery's lines apart;
    /// it is not a `--set` id.
    static func batteryID(_ battery: Battery) -> String {
        DiagnosticsReport.shortID(batterySerials.key(for: battery), key: idKey, length: 6)
    }

    /// The ids whose lines a forecast for this battery reads; see `BatterySerials.keys`.
    static func batteryLogIDs(_ battery: Battery, among batteries: [Battery]) -> [String] {
        batterySerials.keys(for: battery, among: batteries).map { DiagnosticsReport.shortID($0, key: idKey, length: 6) }
    }

    static func setting(_ name: String, device: String? = nil, id: String? = nil, from: String, to: String, by: String) {
        record(EventRecord(kind: .setting, event: name, device: device, id: id, from: from, to: to, by: by))
    }

    static func onOff(_ on: Bool) -> String { on ? "on" : "off" }
    static func speed(_ value: Double) -> String { (value.rounded() == value ? String(Int(value)) : String(value)) + "×" }
}

/// Every battery's levels over the log's 30 days, kept in memory so the window can show how long each lasts without
/// reading files while it refreshes. Loaded once in the background at launch; afterwards each new battery line is
/// added as it is logged. Main thread only.
final class BatteryHistory {
    static let shared = BatteryHistory()
    private var history = BatteryHistoryWindow()
    private var cache: [String: BatteryForecast?] = [:]
    private(set) var loaded = false
    var onChange: (() -> Void)?

    /// Reads the log's battery lines off the main thread, then merges in any logged meanwhile.
    func load() {
        let folder = eventLog.folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            eventLog.flush()
            let now = Date()
            let old = EventLog.read(folder: folder, since: now.addingTimeInterval(-Double(EventLog.keepDays) * 86400), until: now, kinds: [.battery])
            DispatchQueue.main.async {
                guard let self else { return }
                var merged: [String: [EventRecord]] = [:]
                for event in old { if let id = event.id { merged[id, default: []].append(event) } }
                // The file keeps milliseconds; compare as written, or a launch reading read back from it would count twice.
                for (id, recent) in self.history.events {
                    let known = Set((merged[id] ?? []).map { DiagnosticsReport.timestamp($0.t) })
                    merged[id, default: []] += recent.filter { !known.contains(DiagnosticsReport.timestamp($0.t)) }
                }
                self.history = BatteryHistoryWindow(events: merged)
                self.cache = [:]
                self.loaded = true
                self.onChange?()
            }
        }
    }

    func add(_ event: EventRecord) {
        guard let id = event.id else { return }
        let trimmed = history.append(event)
        // A forecast over several ids is cached under all of them joined.
        cache = trimmed ? [:] : cache.filter { !$0.key.split(separator: "+").contains(Substring(id)) }
        if loaded { onChange?() }
    }

    /// How long the battery with this log id lasts, if its log says enough yet.
    func forecast(_ id: String, now: Date = Date()) -> BatteryForecast? { forecast([id], now: now) }

    /// The same over lines logged under several ids for one battery (its serial, and its name from before).
    func forecast(_ ids: [String], now: Date = Date()) -> BatteryForecast? {
        guard loaded, let first = ids.first else { return nil }
        if history.trimIfNeeded(at: now) { cache = [:] }
        let key = ids.joined(separator: "+")
        if let cached = cache[key] { return cached?.at(now) }
        let lines = ids.count == 1 ? history.events[first] ?? [] : ids.flatMap { history.events[$0] ?? [] }.sorted { $0.t < $1.t }
        let forecast = BatteryForecast.estimate(BatteryForecast.readings(lines), now: now)
        cache[key] = forecast
        return forecast
    }

    /// "About 9 days left" for the window and the menu, with what it rests on for the window's tooltip.
    static func text(_ forecast: BatteryForecast) -> (short: String, basis: String) {
        let short: String
        switch forecast.shown {
        case .days(let count): short = L("About %ld days left", count)
        case .hours(let count): short = L("About %ld h left", count)
        case .almostEmpty: short = L("Almost empty")
        }
        return (short, L("Estimated from the last %ld days, about %@%% a day", forecast.basedOnDays, String(format: "%.1f", forecast.perDay)))
    }
}

/// `Halo --events`: prints the event log for a time window. It reads the files only, so it works whether or not Halo
/// runs, never asks the app anything and never starts it.
enum EventsCommand {
    static let usage = """
        Halo --events [--since <time>] [--until <time>] [--kind <kinds>] [--json]
          <time>: 15:00 (today, or yesterday if later than now), 90m, 2h, 3d, today, yesterday, 2026-11-04,
                  "2026-11-04 15:00" or ISO 8601. A bare day starts --since and ends --until.
                  Default: the 24 hours up to --until, or up to now.
          <kinds>: comma-separated, from \(EventRecord.Kind.allCases.map(\.rawValue).joined(separator: ", ")).
          --json prints one JSON object per line, as stored.
        Halo --watch [--kind <kinds>] [--json] [--since <time>] [--for <seconds>]
          Prints each event as Halo logs it, until stopped (Ctrl-C) or for that many seconds. With --since it
          first prints what was logged since then. It waits on the file system, without polling.
        """

    static func run(_ arguments: [String]) -> Int32 {
        let fail = { (text: String) -> Int32 in
            FileHandle.standardError.write(Data((text + "\n").utf8))
            return 2
        }
        func value(_ flag: String) -> String?? {
            guard let index = arguments.firstIndex(of: flag) else { return .none }
            let next = arguments.index(after: index)
            return .some(next < arguments.endIndex && !arguments[next].hasPrefix("--") ? arguments[next] : nil)
        }
        let now = Date()
        let watching = arguments.contains("--watch")
        var until = now
        if watching, arguments.contains("--until") { return fail("--watch runs from now on; --until does not apply.") }
        var seconds: Double?
        if case let .some(text) = value("--for") {
            guard watching, let value = text.flatMap(Double.init), value >= 1, value <= 86400 else {
                return fail("--for takes 1 to 86400 seconds, with --watch.\n\n\(usage)")
            }
            seconds = value
        }
        if case let .some(text) = value("--until") {
            guard let text, let date = EventLog.parseTime(text, now: now, endOfDay: true) else { return fail("--until needs a time.\n\n\(usage)") }
            until = date
        }
        // Without --since, the 24 hours before the end.
        var since = until.addingTimeInterval(-86400)
        if case let .some(text) = value("--since") {
            guard let text, let date = EventLog.parseTime(text, now: now) else { return fail("--since needs a time.\n\n\(usage)") }
            since = date
        }
        guard since <= until else { return fail("--since is later than --until.") }
        var kinds: Set<EventRecord.Kind>?
        if case let .some(text) = value("--kind") {
            guard let text else { return fail("--kind needs a kind.\n\n\(usage)") }
            let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let found = names.compactMap(EventRecord.Kind.init(rawValue:))
            guard found.count == names.count, !found.isEmpty else {
                return fail("Unknown kind in \(text); the kinds are \(EventRecord.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            kinds = Set(found)
        }
        let folder = eventLog.folder
        if watching {
            return watch(folder: folder, kinds: kinds, json: arguments.contains("--json"),
                         since: arguments.contains("--since") ? since : nil, seconds: seconds)
        }
        guard EventLog.exists(folder: folder) else {
            print("No event log yet. Halo writes one while running, in \(folder.path).")
            return 0
        }
        let events = EventLog.read(folder: folder, since: since, until: until, kinds: kinds)
        if arguments.contains("--json") {
            for event in events { print(String(decoding: event.jsonLine(), as: UTF8.self)) }
            return 0
        }
        let filter = kinds.map { " of kind " + $0.map(\.rawValue).sorted().joined(separator: ", ") } ?? ""
        print("Halo events \(DiagnosticsReport.timestamp(since)) to \(DiagnosticsReport.timestamp(until))\(filter): \(events.count)")
        print("Log: \(folder.path) (one file a day, kept \(EventLog.keepDays) days). Local time.")
        print("")
        if events.isEmpty { print("Nothing recorded in that time.") }
        for event in events { print(event.line()) }
        return 0
    }

    /// Follows the log: the folder is watched for a new day's file, today's file for appended lines.
    private static func watch(folder: URL, kinds: Set<EventRecord.Kind>?, json: Bool, since: Date?, seconds: Double?) -> Int32 {
        // Each event reaches a pipe as it happens, not when a buffer fills.
        setlinebuf(stdout)
        let show = { (event: EventRecord) in
            guard kinds?.contains(event.kind) ?? true else { return }
            print(json ? String(decoding: event.jsonLine(), as: UTF8.self) : event.line())
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data("Cannot open \(folder.path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        // The follower starts first, so nothing logged during the catch-up is missed; what the catch-up already printed
        // is not printed again.
        let follower = EventFollower(folder: folder)
        var printed = Set<Data>()
        if let since {
            for event in EventLog.read(folder: folder, since: since, until: Date(), kinds: kinds) {
                show(event)
                printed.insert(event.jsonLine())
            }
        }
        let running = DiagnosticsExport.appRunning
        FileHandle.standardError.write(Data(("Watching \(folder.path)" + (seconds.map { " for \(Int($0)) s" } ?? "; Ctrl-C to stop")
            + (running ? "." : ". Halo is not running, so nothing is logged until it starts.") + "\n").utf8))
        var fileSource: DispatchSourceFileSystemObject?
        func arm() {
            fileSource?.cancel()
            fileSource = nil
            let fd = open(follower.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
            // Today's file deleted or replaced: watch the one that takes its place.
            source.setEventHandler { [weak source] in drain(rearm: source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false) }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileSource = source
        }
        func drain(rearm: Bool = false) {
            let file = follower.file
            for event in follower.next() {
                if !printed.isEmpty, printed.remove(event.jsonLine()) != nil { continue }
                show(event)
            }
            if rearm || follower.file != file || fileSource == nil { arm() }
        }
        let folderFD = open(folder.path, O_EVTONLY)
        guard folderFD >= 0 else { return 1 }
        // A new day's file, or today's first, shows up as a write to the folder.
        let folderSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folderFD, eventMask: .write, queue: .main)
        folderSource.setEventHandler { drain() }
        folderSource.resume()
        arm()
        // Whatever was written between starting the follower and watching the file.
        drain()
        if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) } }
        withExtendedLifetime(folderSource) { dispatchMain() }
    }
}
