// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// What Halo knows about itself at one moment, written only when someone asks, for an agent or a person to debug
/// with. It holds measurements and settings, never keystrokes, screen content, sound, pairing digits, keys, serial
/// numbers or Bluetooth addresses. Devices carry ids keyed with a secret kept on this Mac, so an id tells devices
/// apart across exports without leading back to a serial number or address.
/// The text is English whatever the app's language, so exports compare across Macs and versions; texts the app made
/// for people (status lines, audio events) stay as the app showed them.
public struct DiagnosticsReport: Codable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion = DiagnosticsReport.currentSchema
    /// "live" from the running app; "cold" from `Halo --diagnostics` without one, so only what can be read afresh:
    /// devices, batteries, the permission and the saved settings.
    public var source: String
    public var app: App
    public var state: State
    public var devices: [DeviceEntry] = []
    public var batteries: [BatteryEntry] = []
    /// Live only, like everything below: the running app's memory.
    public var scrollTools: [ToolEntry]?
    public var directionCheck: DirectionEntry?
    public var scrolls: [ScrollEntry]?
    public var link: LinkEntry?
    public var audioDevices: [AudioDeviceEntry]?
    public var audioEvents: [AudioEventEntry]?
    public var audioCheck: AudioCheckEntry?
    /// The event log's last 24 hours, at most `eventLimit` of the newest; nil when there is no log yet.
    public var events: [EventRecord]?
    /// Where the log's daily files are, for `Halo --events` and for reading further back.
    public var eventsFolder: String?
    /// Why the running app could not write its last event, when it could not.
    public var eventsError: String?
    /// How long each connected battery lasts at its rate since its last charge, for those whose log says enough.
    public var batteryForecasts: [ForecastEntry]?
    public static let eventLimit = 300
    /// What asked for this export, and what it did first; nil in a cold export.
    public var request: RequestEntry?
    /// What is missing or empty, and what would fill it.
    public var notes: [String] = []
    /// Live only: the Devices page as it reads, in its order, so an agent can check it without a screenshot.
    public var page: PageEntry?

    public init(source: String, app: App, state: State) {
        self.source = source
        self.app = app
        self.state = state
    }

    public struct App: Codable, Equatable {
        public var version: String
        public var build: String
        public var macOS: String
        public var language: String
        public var exportedAt: Date
        /// Seconds since boot at export; scroll times are on this clock too.
        public var uptime: Double
        public init(version: String, build: String, macOS: String, language: String, exportedAt: Date, uptime: Double) {
            self.version = version
            self.build = build
            self.macOS = macOS
            self.language = language
            self.exportedAt = exportedAt
            self.uptime = uptime
        }
    }

    public struct State: Codable, Equatable {
        public var appRunning: Bool
        /// Nil in a cold export: the command-line process would read its own launcher's permission, not Halo's.
        public var accessibility: Bool?
        public var recordScrolls: Bool
        public var showIcon: Bool
        /// Whether device settings follow changes made on the paired Mac.
        public var matchSettings: Bool?
        /// Whether the clipboard follows the person to the paired Mac.
        public var clipboard: Bool?
        /// macOS's own Natural Scrolling setting; Halo's reverse rule flips scrolling relative to it.
        public var naturalScrolling: Bool?
        /// Live only.
        public var listening: Bool?
        public var reversing: Bool?
        public var scrollsSeen: Int?
        public var scrollsReversed: Int?
        /// The status line the Diagnostics page shows, and a transient notice under it, in the app's language.
        public var statusText: String?
        public var notice: String?
        public init(appRunning: Bool, accessibility: Bool?, recordScrolls: Bool, showIcon: Bool) {
            self.appRunning = appRunning
            self.accessibility = accessibility
            self.recordScrolls = recordScrolls
            self.showIcon = showIcon
        }
    }

    public struct DeviceEntry: Codable, Equatable {
        /// The system's name for it, and the name Halo shows the person.
        public var name: String
        public var displayName: String
        /// A virtual device Universal Control mirrors from another Mac (the system prefixes such devices with "V-").
        public var universalControl: Bool
        /// A keyed hash of Halo's identity hash: stable on this Mac, not reversible to the serial number.
        public var id: String
        public var sender: String
        public var transport: String
        public var local: Bool
        public var trackpad: Bool
        public var sessionOnly: Bool
        public var wheelRule: String
        public var continuousRule: String
        public var speed: Double
        /// Scrolls seen this run, by kind; live only.
        public var wheelScrolls: Int?
        public var continuousScrolls: Int?

        public init(_ device: Device, displayName: String, policy: Policy, idKey: SymmetricKey, wheelScrolls: Int? = nil,
                    continuousScrolls: Int? = nil) {
            name = device.name
            self.displayName = displayName
            universalControl = !device.local && device.name.hasPrefix("V-")
            id = DiagnosticsReport.deviceID(device, key: idKey)
            sender = String(device.sender, radix: 16)
            transport = device.transport
            local = device.local
            trackpad = device.trackpad
            sessionOnly = device.sessionOnly
            wheelRule = policy.rule(for: device, continuous: false).rawValue
            continuousRule = policy.rule(for: device, continuous: true).rawValue
            speed = policy.speed(for: device)
            self.wheelScrolls = wheelScrolls
            self.continuousScrolls = continuousScrolls
        }
    }

    /// What made this export: a plain request, the Diagnostics page's button, a check an agent started, or a change it
    /// asked for. Times bound what the check covered.
    public struct RequestEntry: Codable, Equatable {
        /// "export", "button", "record", "link", "audio" or "set".
        public var kind: String
        public var startedAt: Date
        public var endedAt: Date
        public var seconds: Double?
        /// How the check ended, or what changed.
        public var result: String?
        public init(kind: String, startedAt: Date, endedAt: Date, seconds: Double? = nil, result: String? = nil) {
            self.kind = kind
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.seconds = seconds
            self.result = result
        }
    }

    public struct BatteryEntry: Codable, Equatable {
        public var name: String
        public var percent: Int
        public var charging: Bool
        public init(_ battery: Battery) {
            name = battery.name
            percent = battery.percent
            charging = battery.charging
        }
    }

    public struct ForecastEntry: Codable, Equatable {
        public var name: String
        /// The event log's battery id.
        public var id: String
        public var percent: Int
        public var daysLeft: Double
        public var percentPerDay: Double
        /// The start of the discharge the rate comes from, and the last reading.
        public var since: Date
        public var readAt: Date
        public init(name: String, id: String, forecast: BatteryForecast) {
            self.name = name
            self.id = id
            percent = forecast.percent
            daysLeft = (forecast.days * 10).rounded() / 10
            percentPerDay = (forecast.perDay * 100).rounded() / 100
            since = forecast.since
            readAt = forecast.readAt
        }
    }

    /// A process with a tap on scroll events.
    public struct ToolEntry: Codable, Equatable {
        public var name: String
        public var bundleID: String?
        public var modifies: Bool
        public var isHalo: Bool
        public init(name: String, bundleID: String?, modifies: Bool, isHalo: Bool) {
            self.name = name
            self.bundleID = bundleID
            self.modifies = modifies
            self.isHalo = isHalo
        }
    }

    public struct DirectionEntry: Codable, Equatable {
        public var running: Bool
        /// Programs that could change scrolling when the running check began.
        public var suspects: [String]
        /// A device whose reversed direction another program changed back, and who could have.
        public var blockedDevice: String?
        public var blockedBy: [String]
        public init(running: Bool, suspects: [String], blockedDevice: String?, blockedBy: [String]) {
            self.running = running
            self.suspects = suspects
            self.blockedDevice = blockedDevice
            self.blockedBy = blockedBy
        }
    }

    public struct ScrollEntry: Codable, Equatable {
        public var at: Date
        public var uptime: Double
        public var sender: String
        public var device: String?
        public var continuous: Bool
        public var input: Int64
        public var output: Int64
        public var phase: Int64
        public var momentum: Int64
        public var reversed: Bool
        public init(at: Date, uptime: Double, sender: UInt64, device: String?, continuous: Bool, input: Int64, output: Int64,
                    phase: Int64, momentum: Int64, reversed: Bool) {
            self.at = at
            self.uptime = uptime
            self.sender = String(sender, radix: 16)
            self.device = device
            self.continuous = continuous
            self.input = input
            self.output = output
            self.phase = phase
            self.momentum = momentum
            self.reversed = reversed
        }
    }

    public struct LinkEntry: Codable, Equatable {
        public var peer: String
        public var lastSeen: Date?
        public var online: Bool
        /// "network", "direct", or nil while not connected.
        public var path: String?
        public var directAllowed: Bool
        public var checking: Bool
        public var verdict: String?
        public var lastCheck: LinkCheck?
        public var peerCheck: LinkCheck?
        /// The last 200 link events, without snapshot contents; pairing digits are never logged.
        public var events: [String]
        public init(peer: String, lastSeen: Date?, online: Bool, path: String?, directAllowed: Bool, checking: Bool,
                    verdict: String?, lastCheck: LinkCheck?, peerCheck: LinkCheck?, events: [String]) {
            self.peer = peer
            self.lastSeen = lastSeen
            self.online = online
            self.path = path
            self.directAllowed = directAllowed
            self.checking = checking
            self.verdict = verdict
            self.lastCheck = lastCheck
            self.peerCheck = peerCheck
            self.events = events
        }
    }

    /// The Devices page in the words it shows: this Mac's rows, the paired Mac's, and the notes and card between them.
    public struct PageEntry: Codable, Equatable {
        /// Whether Settings is on screen now, and whether this run is the account's first (it opens the page itself).
        public var windowOpen: Bool
        public var firstLaunch: Bool
        /// "idle", "searching", "comparing" or "confirmed" (this Mac clicked Match and waits for the other).
        public var pairing: String
        public var rows: [RowEntry]
        /// Notes with this Mac's list: one above it when there is no mouse or trackpad, or one below it on a first launch.
        public var notes: [String]
        /// The "Another Mac Connected" card while Universal Control connects an unpaired Mac: its detail and button.
        public var pairCard: CardEntry?
        /// Devices Universal Control lends here that are not the paired Mac's (nothing is paired, or that Mac does not
        /// report them), each with its switch.
        public var universalControlRows: [RowEntry]?
        /// UC's session state and whether its last read succeeded, independent of pointer location and HID rows.
        public var universalControlConnected: Bool?
        public var universalControlCurrent: Bool?
        public var pointerHere: Bool?
        public var menuOpen: Bool?
        /// The paired Mac's section: its title and rows, or nil while unpaired. A device it lends here through Universal
        /// Control is listed there once, in its place, with this Mac's switch (`lent`).
        public var peerTitle: String?
        public var peerRows: [RowEntry]?
        public var peerNote: String?
        public init(windowOpen: Bool, firstLaunch: Bool, pairing: String, rows: [RowEntry], notes: [String], pairCard: CardEntry?,
                    universalControlRows: [RowEntry]? = [], universalControlConnected: Bool? = nil,
                    universalControlCurrent: Bool? = nil, pointerHere: Bool? = nil, menuOpen: Bool? = nil,
                    peerTitle: String?, peerRows: [RowEntry]?, peerNote: String?) {
            self.windowOpen = windowOpen
            self.firstLaunch = firstLaunch
            self.pairing = pairing
            self.rows = rows
            self.notes = notes
            self.pairCard = pairCard
            self.universalControlRows = universalControlRows
            self.universalControlConnected = universalControlConnected
            self.universalControlCurrent = universalControlCurrent
            self.pointerHere = pointerHere
            self.menuOpen = menuOpen
            self.peerTitle = peerTitle
            self.peerRows = peerRows
            self.peerNote = peerNote
        }
    }

    public struct RowEntry: Codable, Equatable {
        public var title: String
        /// The line under the name: what a speaker is set to, or that the other Mac reverses a lent device differently.
        public var facts: [String]
        public var battery: Int?
        /// The reverse switch; nil for a row without one.
        public var on: Bool?
        public var speed: Double?
        /// Lent by the other Mac through Universal Control.
        public var lent: Bool
        public init(title: String, facts: [String], battery: Int?, on: Bool?, speed: Double?, lent: Bool = false) {
            self.title = title
            self.facts = facts
            self.battery = battery
            self.on = on
            self.speed = speed
            self.lent = lent
        }
    }

    public struct CardEntry: Codable, Equatable {
        public var title: String
        public var detail: String
        public var button: String
        public init(title: String, detail: String, button: String) {
            self.title = title
            self.detail = detail
            self.button = button
        }
    }

    /// A connected Bluetooth speaker or headphones.
    public struct AudioDeviceEntry: Codable, Equatable {
        public var name: String
        public var id: String
        public var speaker: Bool
        public var output: Bool
        public var input: Bool
        public var callQuality: Bool
        /// The app recording from its microphone, "unknown" when some app is but cannot be named.
        public var micInUseBy: String?
        /// The speaker rule: keep the system microphone off it. Speakers only.
        public var micRule: Bool?
        public var battery: Int?
        public var rssi: Int?
        public init(name: String, address: String, idKey: SymmetricKey, speaker: Bool, output: Bool, input: Bool, callQuality: Bool,
                    micInUseBy: String?, micRule: Bool?, battery: Int?, rssi: Int?) {
            self.name = name
            id = DiagnosticsReport.audioID(address, key: idKey)
            self.speaker = speaker
            self.output = output
            self.input = input
            self.callQuality = callQuality
            self.micInUseBy = micInUseBy
            self.micRule = micRule
            self.battery = battery
            self.rssi = rssi
        }
    }

    public struct AudioEventEntry: Codable, Equatable {
        public var at: Date
        public var device: String
        public var text: String
        public var relayedCall: Bool
        public var context: String?
        public init(at: Date, device: String, text: String, relayedCall: Bool, context: String?) {
            self.at = at
            self.device = device
            self.text = text
            self.relayedCall = relayedCall
            self.context = context
        }
    }

    /// The last on-demand audio link check.
    public struct AudioCheckEntry: Codable, Equatable {
        public var started: Date?
        /// "running", "finished", "cancelled", "noData" or "failed".
        public var outcome: String
        public var samples: [Sample]
        public struct Sample: Codable, Equatable {
            public var second: Double
            public var retransmitted: Double
            public var dropped: Int
            public var rssi: Int
            public var noise: Int?
        }
        public init(started: Date?, outcome: String, samples: [(time: TimeInterval, sample: LinkQualitySample)]) {
            self.started = started
            self.outcome = outcome
            self.samples = samples.map {
                Sample(second: ($0.time * 10).rounded() / 10, retransmitted: $0.sample.retransmitted, dropped: $0.sample.dropped,
                       rssi: $0.sample.rssi, noise: $0.sample.noise)
            }
        }
    }

    /// The same device across exports, without a way back to what identifies it: an unkeyed hash of a Bluetooth
    /// address could be reversed by trying the few million addresses left once the vendor's prefix is known.
    public static func shortID(_ identity: String, key: SymmetricKey, length: Int) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: key).prefix(length).map { String(format: "%02x", $0) }.joined()
    }
    /// The ids an agent passes back to `--set`.
    public static func deviceID(_ device: Device, key: SymmetricKey) -> String { shortID(device.key, key: key, length: 6) }
    public static func audioID(_ address: String, key: SymmetricKey) -> String {
        shortID(address.lowercased().replacingOccurrences(of: "-", with: ":"), key: key, length: 4)
    }

    /// The command an agent runs to fill a gap; the notes name it so the agent can act rather than ask.
    public static let command = "/Applications/Halo.app/Contents/MacOS/Halo"

    /// What an agent should know before reading the rest: what this export covers, sections that are empty, and the
    /// command that would fill each one.
    public func gaps() -> [String] {
        var notes: [String] = []
        if source == "cold" {
            notes.append(state.appRunning
                ? "Halo is running but did not answer: run `\(Self.command) --diagnostics` outside any agent sandbox, which blocks the request. This file has no live state."
                : "Halo is not running, so there is no live state (scroll tools, scrolls, the other Mac, audio): ask the person to open Halo.")
        }
        if state.accessibility == false { notes.append("Accessibility permission is not granted: Halo cannot see or change scrolling. Only the person can grant it, in System Settings › Privacy & Security › Accessibility.") }
        guard source == "live" else { return notes }
        if let request, request.kind == "record" {
            if scrolls?.contains(where: { $0.at >= request.startedAt }) != true {
                notes.append("Nothing scrolled during the \(Int(request.seconds ?? 0)) s recording: tell the person to scroll the device in question, then run `\(Self.command) --diagnostics --record` again.")
            }
        } else if scrolls?.isEmpty != false {
            notes.append("No scrolls recorded: tell the person to scroll the device in question, and run `\(Self.command) --diagnostics --record 30` meanwhile.")
        }
        if let eventsError { notes.append("The event log could not be written: \(eventsError). Events since then are missing.") }
        if link == nil { notes.append("Not paired with another Mac.") }
        else if link?.lastCheck == nil { notes.append("The connection to the other Mac has not been checked: run `\(Self.command) --diagnostics --link-check`.") }
        if audioCheck == nil, audioDevices?.isEmpty == false {
            notes.append("The audio link has not been checked: ask the person to play music to the speaker or headphones, then run `\(Self.command) --diagnostics --audio-check`.")
        }
        return notes
    }

    // MARK: Files

    public static let jsonName = "latest.json"
    public static let markdownName = "latest.md"

    /// Local time with its offset and milliseconds, the way the link and audio lines are written.
    public static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    // MARK: Summary

    /// A one-screen summary that points to the JSON for the rest.
    public var markdown: String {
        var lines = ["# Halo diagnostics", "",
                     "Halo \(app.version) (\(app.build)) · \(app.macOS) · language \(app.language)",
                     "Exported \(Self.timestamp(app.exportedAt)) · source: \(source) · schema \(schemaVersion)",
                     "Everything below and more is in `\(Self.jsonName)` next to this file. Times are local with their offset.", ""]
        if let request { lines += ["**This export:** " + Self.describe(request), ""] }
        if !notes.isEmpty {
            lines += ["## Missing or empty", ""] + notes.map { "- \($0)" } + [""]
        }
        lines += ["## State", ""]
        var flags = ["accessibility \(state.accessibility.map(Self.yes) ?? "unknown")",
                     "macOS natural scrolling \(state.naturalScrolling.map(Self.on) ?? "unknown")",
                     "recording scrolls \(Self.on(state.recordScrolls))", "menu bar icon \(Self.on(state.showIcon))"]
        if let match = state.matchSettings { flags.append("match the other Mac's device settings \(Self.on(match))") }
        if let clipboard = state.clipboard { flags.append("clipboard follows \(Self.on(clipboard))") }
        if let listening = state.listening { flags.append("listening \(Self.yes(listening))") }
        if let reversing = state.reversing { flags.append("reversing \(Self.yes(reversing))") }
        lines.append("- " + flags.joined(separator: " · "))
        if let seen = state.scrollsSeen, let reversed = state.scrollsReversed { lines.append("- Scrolls this run: \(seen), reversed \(reversed)") }
        if let text = state.statusText { lines.append("- Status line: \(text)") }
        if let notice = state.notice { lines.append("- Notice: \(notice)") }
        lines.append("")
        if let page {
            lines += ["## Devices page", "",
                      "As the window reads: this Mac's rows and notes, Universal Control's rows and card, then the other Mac's section. Settings \(page.windowOpen ? "open" : "closed") · first launch \(Self.yes(page.firstLaunch)) · pairing \(page.pairing)", ""]
            lines += page.rows.map { "- " + Self.describe($0) }
            lines += page.notes.map { "- Note: \($0)" }
            let universalControl = page.universalControlRows ?? []
            if !universalControl.isEmpty || page.pairCard != nil {
                lines.append("- Universal Control:")
                lines += universalControl.map { "  - " + Self.describe($0) }
                if let card = page.pairCard { lines.append("  - Card: \(card.title) · \(card.detail) · [\(card.button)]") }
            }
            if let title = page.peerTitle {
                lines.append("- \(title):")
                lines += (page.peerRows ?? []).map { "  - " + Self.describe($0) }
                if let note = page.peerNote { lines.append("  - Note: \(note)") }
            }
            lines.append("")
        }
        if !devices.isEmpty {
            lines += ["## Pointing devices", "",
                      "Halo shows each by its display name. Reverse flips scrolling relative to macOS natural scrolling; `--set reverse <id> on|off` changes it.", "",
                      "| Device (as Halo shows it) | System name | Id | Kind | Wheel | Continuous | Speed | Scrolls this run |", "|---|---|---|---|---|---|---|---|"]
            for d in devices {
                let kind = (d.universalControl ? "Universal Control (another Mac's) " : d.local ? "this Mac's " : "virtual ")
                    + (d.trackpad ? "trackpad" : "pointer") + (d.sessionOnly ? ", no serial" : "") + ", \(d.transport)"
                let scrolls = [d.wheelScrolls.map { "\($0) wheel" }, d.continuousScrolls.map { "\($0) continuous" }].compactMap { $0 }
                lines.append("| \(Self.cell(d.displayName)) | \(Self.cell(d.name)) | \(d.id) | \(Self.cell(kind)) | \(d.wheelRule) | \(d.continuousRule) | \(Self.number(d.speed))× | \(scrolls.isEmpty ? "–" : scrolls.joined(separator: ", ")) |")
            }
            lines.append("")
        }
        if !batteries.isEmpty {
            lines += ["## Batteries", ""] + batteries.map { "- \($0.name): \($0.percent)%\($0.charging ? ", charging" : "")" } + [""]
        }
        if let forecasts = batteryForecasts {
            lines += ["## Days left", ""]
            lines += forecasts.isEmpty ? ["- No battery has an estimate yet."] : forecasts.map { f in
                "- \(f.name): \(f.percent)%, about \(Self.number(f.daysLeft)) days left, losing \(Self.number(f.percentPerDay)) points a day since \(Self.timestamp(f.since)) (last read \(Self.timestamp(f.readAt)))"
            }
            lines.append("")
        }
        if let tools = scrollTools {
            lines += ["## Programs with a scroll tap", ""]
            lines += tools.isEmpty ? ["- none"] : tools.map { t in
                let role = t.isHalo ? "Halo" : t.modifies ? "can modify scrolling" : "listen-only"
                return "- \(t.name)\(t.bundleID.map { " (\($0))" } ?? ""): \(role)"
            }
            if let check = directionCheck {
                if check.running { lines.append("- Direction check running; suspects: \(check.suspects.isEmpty ? "none" : check.suspects.joined(separator: ", "))") }
                if let device = check.blockedDevice { lines.append("- **\(device)**: reversed direction changed back by \(check.blockedBy.joined(separator: " or "))") }
            }
            lines.append("")
        }
        if let link {
            lines += ["## Other Mac", "",
                      "- \(link.peer): \(link.online ? "online over \(link.path ?? "?")" : "offline")\(link.lastSeen.map { ", last seen \(Self.timestamp($0))" } ?? "")\(link.directAllowed ? ", direct link allowed" : "")\(link.checking ? ", check running" : "")"]
            if let verdict = link.verdict { lines.append("- Verdict from both sides: \(verdict)") }
            for (side, check) in [("From this Mac", link.lastCheck), ("From the other Mac", link.peerCheck)] {
                guard let check else { continue }
                let age = app.exportedAt.timeIntervalSince(check.at)
                lines.append("- \(side), \(Self.timestamp(check.at))\(age > 3600 ? " (\(Int(age / 3600)) h before this export)" : ""): ping \(check.ping.rawValue)\(check.pingMilliseconds.map { " \($0) ms" } ?? ""), Halo port \(check.peerTCP.rawValue), router \(check.gatewayTCP.rawValue), seen on the network \(Self.yes(check.found)), timeouts \(check.dialTimeouts), handshake failures \(check.handshakeFailures), refused without forward secrecy \(check.noForwardSecrecy)")
            }
            if !link.events.isEmpty { lines += ["- Last link events:", ""] + link.events.suffix(10).map { "      \($0)" } }
            lines.append("")
        }
        if let audio = audioDevices, !audio.isEmpty || audioEvents?.isEmpty == false || audioCheck != nil {
            lines += ["## Bluetooth audio", ""]
            for a in audio {
                var parts = [a.speaker ? "speaker" : "headphones"]
                if a.output { parts.append("playing to it") }
                if a.input { parts.append("system microphone") }
                if a.callQuality { parts.append("**call quality**") }
                if let app = a.micInUseBy { parts.append("microphone used by \(app)") }
                if let rule = a.micRule { parts.append("mic rule \(Self.on(rule))") }
                if let battery = a.battery { parts.append("battery \(battery)%") }
                lines.append("- \(a.name) [\(a.id)]: " + parts.joined(separator: ", "))
            }
            if let events = audioEvents, !events.isEmpty {
                lines += ["- Last audio events:", ""] + events.suffix(15).map {
                    "      \(Self.timestamp($0.at)) \($0.device): \($0.text)" + ($0.context.map { " [\($0)]" } ?? "")
                }
            }
            if let check = audioCheck {
                let dropped = check.samples.reduce(0) { $0 + $1.dropped }
                let average = check.samples.isEmpty ? 0 : check.samples.map(\.retransmitted).reduce(0, +) / Double(check.samples.count)
                lines.append("- Audio link check \(check.outcome)\(check.started.map { " at \(Self.timestamp($0))" } ?? ""): \(check.samples.count) reports, retransmitted \(Self.number(average))% on average, \(dropped) packets dropped")
            }
            lines.append("")
        }
        if let events {
            lines += ["## Recent events", "",
                      (events.count >= Self.eventLimit ? "The newest \(events.count) of the last 24 hours" : "\(events.count) in the last 24 hours")
                        + " are in the JSON. `\(Self.command) --events --since 2h` prints the log itself; `--kind battery,link` narrows it.", ""]
            lines += events.isEmpty ? ["- none"] : events.suffix(15).map { "      " + $0.line() }
            lines.append("")
        }
        if let scrolls, !scrolls.isEmpty {
            lines += ["## Recent scrolls", "", "\(scrolls.count) kept, \(Self.timestamp(scrolls[0].at)) to \(Self.timestamp(scrolls[scrolls.count - 1].at)). By device:", ""]
            var order: [String] = []
            var groups: [String: [ScrollEntry]] = [:]
            for scroll in scrolls {
                let name = scroll.device ?? "unknown sender \(scroll.sender)"
                if groups[name] == nil { order.append(name) }
                groups[name, default: []].append(scroll)
            }
            for name in order {
                let group = groups[name]!
                let wheel = group.filter { !$0.continuous }, continuous = group.filter(\.continuous)
                let part = { (label: String, items: [ScrollEntry]) -> String? in
                    items.isEmpty ? nil : "\(items.count) \(label) (\(items.filter(\.reversed).count) reversed, \(items.filter { !$0.reversed }.count) passed)"
                }
                lines.append("- \(name): " + [part("wheel", wheel), part("continuous", continuous)].compactMap { $0 }.joined(separator: ", "))
            }
            lines += ["", "The last 10:", ""] + scrolls.suffix(10).map {
                "      \(Self.timestamp($0.at)) \($0.device ?? "unknown sender \($0.sender)") \($0.continuous ? "continuous" : "wheel") y \($0.input) → \($0.output)\($0.reversed ? " reversed" : "")"
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ row: RowEntry) -> String {
        var parts = [row.title] + row.facts
        if row.lent { parts.append("lent here") }
        if let battery = row.battery { parts.append("\(battery)%") }
        if let on = row.on { parts.append("reverse \(Self.on(on))") }
        if let speed = row.speed { parts.append("speed " + String(format: "%g", speed) + "×") }
        return parts.joined(separator: " · ")
    }

    static func describe(_ request: RequestEntry) -> String {
        let span = "\(timestamp(request.startedAt)) to \(timestamp(request.endedAt))"
        let result = request.result.map { ": \($0)" } ?? ""
        switch request.kind {
        case "record": return "a \(Int(request.seconds ?? 0)) s scroll recording, \(span)\(result)."
        case "link": return "a connection check to the other Mac, \(span)\(result)."
        case "audio": return "an audio link check, \(span)\(result)."
        case "set": return "a change an agent asked for, \(timestamp(request.endedAt))\(result)."
        case "button": return "the Copy button beside Diagnostics Summary on the Diagnostics page."
        default: return "a plain export, no check run."
        }
    }

    private static func yes(_ value: Bool) -> String { value ? "yes" : "no" }
    private static func on(_ value: Bool) -> String { value ? "on" : "off" }
    private static func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
