// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices
import CryptoKit
import HaloCore
import HaloHID

/// The diagnostics export: one fixed place, so an agent finds it without being told, and only the latest export.
/// Nothing is gathered until someone asks: the Diagnostics page's button, or `Halo --diagnostics`, which asks the
/// running app over a distributed notification; the app only listens, so nothing runs between requests.
enum DiagnosticsExport {
    static let request = Notification.Name("com.liuzhekan.Halo.diagnostics.export")
    static let started = Notification.Name("com.liuzhekan.Halo.diagnostics.started")
    static let done = Notification.Name("com.liuzhekan.Halo.diagnostics.exported")
    /// How long `--diagnostics` waits for the app to take the request before falling back to what it can read itself.
    static let answerWithin: TimeInterval = 3

    /// A check an agent can start before the export, each on its own clock and stopped when it is over.
    enum Run: String {
        /// Turns scroll recording on for a while (and back off, if it was off) so the person can reproduce a problem.
        case record
        /// The 30-second audio link check; it needs music playing to a Bluetooth speaker or headphones.
        case audio
        /// One connection check to the paired Mac; it needs nobody.
        case link

        static let recordSeconds: ClosedRange<Double> = 5...120

        /// How long to wait for the export after the app took the request.
        func timeout(seconds: Double) -> TimeInterval {
            switch self {
            case .record: return seconds + 5
            case .audio: return AudioCheck.duration + 10
            case .link: return 30
            }
        }
    }
    static var folder: URL { stateURL.appendingPathComponent("diagnostics", isDirectory: true) }
    static var json: URL { folder.appendingPathComponent(DiagnosticsReport.jsonName) }
    static var markdown: URL { folder.appendingPathComponent(DiagnosticsReport.markdownName) }

    static func write(_ report: DiagnosticsReport) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DiagnosticsReport.encoder.encode(report).write(to: json, options: .atomic)
        try report.markdown.write(to: markdown, atomically: true, encoding: .utf8)
    }

    /// The secret behind exported device ids: random, made on the first export and kept beside Halo's settings, outside
    /// the export folder, so a shared export cannot be hashed back.
    static var idKey: SymmetricKey {
        let url = stateURL.appendingPathComponent("diagnostics-key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        // Created private, never readable by others even for a moment, and linked into place only if no other Halo
        // process made one meanwhile; then that one is used, so both give the same ids.
        let temporary = stateURL.appendingPathComponent("diagnostics-key.\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
            close(fd)
            if written == data.count {
                // A key of the wrong length is no key: replaced. Without hard links (a state folder on exFAT or a
                // network share) the rename stands in.
                if let old = try? Data(contentsOf: url), old.count != 32 { unlink(url.path) }
                if link(temporary.path, url.path) != 0, errno != EEXIST { _ = rename(temporary.path, url.path) }
            }
            unlink(temporary.path)
        }
        if let kept = try? Data(contentsOf: url), kept.count == 32 { return SymmetricKey(data: kept) }
        return key
    }

    /// macOS's Natural Scrolling, which Halo's reverse rule is relative to; on unless turned off.
    static var naturalScrolling: Bool { UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true }

    static func app(now: Date = Date()) -> DiagnosticsReport.App {
        let info = Bundle.main.infoDictionary
        return .init(version: info?["CFBundleShortVersionString"] as? String ?? "dev", build: info?["CFBundleVersion"] as? String ?? "dev",
                     macOS: macOSVersion, language: Language.current.rawValue, exportedAt: now, uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// "macOS 27.2 (26B123)", always in English: the system's own version string follows the language Halo runs in.
    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "macOS \(number)" }
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else { return "macOS \(number)" }
        return "macOS \(number) (\(String(cString: build)))"
    }

    enum Answer { case exported(change: String?, refreshed: Bool), refused(String), noAnswer }

    /// What the command asks the running app for.
    enum Command {
        case export
        case run(Run, seconds: Double)
        /// A setting, as `what`, the device id from an export (if any) and the new value.
        case set(what: String, target: String?, value: String)

        var info: [String: Any] {
            switch self {
            case .export: return [:]
            case let .run(run, seconds): return ["run": run.rawValue, "seconds": seconds]
            case let .set(what, target, value): return ["set": what, "target": target ?? "", "value": value]
            }
        }
        var timeout: TimeInterval {
            switch self {
            case .export, .set: return answerWithin
            case let .run(run, seconds): return run.timeout(seconds: seconds)
            }
        }
    }

    static let usage = """
        Halo runs in the menu bar: it reverses scrolling per device, shows peripheral batteries, keeps Bluetooth
        speakers for music and links to a second paired Mac. These commands talk to the running app.

        Read
          Halo --diagnostics                      Export the current state and print its summary
          Halo --events [--since 2h] [--kind battery,link] [--json]
                                                  What happened: the event log, by default the last 24 hours
          Halo --watch [--kind battery,link] [--for 60]
                                                  Each event as it happens
        Check, then export
          Halo --diagnostics --record [5-120]     Record scrolling for that many seconds (default 30)
          Halo --diagnostics --link-check         Check the connection to the other Mac
          Halo --diagnostics --audio-check        Check the Bluetooth audio link while music plays
        Change, then export
          Halo --set reverse <device id> on|off
          Halo --set speed <device id> 0.5|1|1.5|2|3|4
          Halo --set speaker-mic <audio device id> on|off
        Device ids are in the export: ~/Library/Application Support/Halo/diagnostics/latest.{md,json}.

        Without the app
          Halo --probe                            List devices and permissions
          Halo --observe [seconds]                Watch scrolling, listen-only (default 10, at most 60)
          Halo --uninstall                        List everything Halo put on this Mac; removes nothing

        """ + EventsCommand.usage

    /// Posts the request and waits: first for the app to take it, then, for a check, for the check and the export.
    private static func askRunningApp(_ command: Command) -> Answer {
        var took = false
        var answer: Answer?
        let center = DistributedNotificationCenter.default()
        // Replies go to every listener; each command keeps only those to its own request.
        let id = UUID().uuidString
        let mine = { (note: Notification) in note.userInfo?["id"] as? String == id }
        let observers = [
            center.addObserver(forName: started, object: nil, queue: nil) { note in if mine(note) { took = true } },
            center.addObserver(forName: done, object: nil, queue: nil) { note in
                guard mine(note) else { return }
                took = true
                let changed = note.userInfo?["changed"] as? String
                let error = note.userInfo?["error"] as? String
                if let error, changed == nil {
                    answer = .refused(error)
                } else {
                    // A change can succeed even if writing the diagnostics export fails.
                    answer = .exported(change: changed, refreshed: error == nil)
                    if let error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
                }
            }
        ]
        defer { observers.forEach(center.removeObserver) }
        var info = command.info
        info["id"] = id
        center.postNotificationName(request, object: nil, userInfo: info, deliverImmediately: true)
        let wait = { (until: Date, done: () -> Bool) in
            // Each notification wakes the run loop, so this sleeps until a reply or the deadline.
            while !done(), Date() < until { _ = RunLoop.current.run(mode: .default, before: until) }
        }
        wait(Date().addingTimeInterval(answerWithin)) { took }
        guard took else { return .noAnswer }
        if case let .run(.record, seconds) = command { FileHandle.standardError.write(Data("Recording scrolls for \(Int(seconds)) s.\n".utf8)) }
        wait(Date().addingTimeInterval(command.timeout)) { answer != nil }
        return answer ?? .noAnswer
    }

    /// Whether the menu-bar app runs, other than this process.
    /// Read from the process list rather than from Launch Services, which an agent's sandbox (Codex's, for one) hides.
    static var appRunning: Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(max(count, 0)).contains { pid in
            pid > 0 && pid != getpid() && proc_pidpath(pid, &path, UInt32(path.count)) > 0
                && String(cString: path).hasSuffix(".app/Contents/MacOS/Halo")
        }
    }

    static let unreachable = "Halo is running but did not answer in time."
    /// The request is a distributed notification, which a sandbox refuses to post; asked before posting, so the
    /// system's long refusal report does not bury the answer.
    static let sandboxed = "This command runs inside a sandbox (an agent's, such as Codex's default one), which blocks the request "
        + "to Halo: run it again outside the sandbox. Export requests write diagnostics; action requests can change settings or run checks."
    static var inSandbox: Bool {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: Check.self)(getpid(), nil, 0) != 0
    }

    /// `Halo --diagnostics`: asks the running app for a fresh export and prints where it is and its summary. It never
    /// starts the app. Without an answer it keeps the last export, or, if there is none, writes one from what it can
    /// read itself, marked "cold".
    static func runCommand(_ arguments: [String]) -> Int32 {
        let fail = { (text: String) -> Int32 in
            FileHandle.standardError.write(Data((text + "\n").utf8))
            return 2
        }
        var command = Command.export
        if let index = arguments.firstIndex(of: "--set") {
            let rest = Array(arguments.dropFirst(index + 1))
            switch rest.first {
            case let what? where ["reverse", "speed", "speaker-mic"].contains(what) && rest.count == 3:
                command = .set(what: what, target: rest[1], value: rest[2])
            default: return fail(usage)
            }
        } else if let index = arguments.firstIndex(of: "--record") {
            var seconds: Double = 30
            if let value = arguments.dropFirst(index + 1).first.flatMap(Double.init) {
                guard Run.recordSeconds.contains(value) else { return fail("--record takes 5 to 120 seconds") }
                seconds = value
            }
            command = .run(.record, seconds: seconds)
        } else if arguments.contains("--audio-check") {
            command = .run(.audio, seconds: 0)
        } else if arguments.contains("--link-check") {
            command = .run(.link, seconds: 0)
        }
        let acts: Bool
        if case .export = command { acts = false } else { acts = true }
        let running = appRunning
        let sandbox = running && inSandbox
        var change: String?
        var refreshed = false
        if sandbox {
            FileHandle.standardError.write(Data("\(sandboxed)\n".utf8))
            if acts { return 1 }
        } else if running {
            switch askRunningApp(command) {
            case .exported(let changed, let didRefresh):
                change = changed
                refreshed = didRefresh
            case .refused(let reason):
                FileHandle.standardError.write(Data("Halo did not do it: \(reason)\n".utf8))
                return 1
            case .noAnswer:
                FileHandle.standardError.write(Data("\(unreachable)\n".utf8))
                if acts { return 1 }
            }
        } else if acts {
            FileHandle.standardError.write(Data("Halo is not running, so it can neither check nor change anything. Ask the person to open Halo first.\n".utf8))
            return 1
        }
        if !FileManager.default.fileExists(atPath: markdown.path) {
            let settings = (try? Data(contentsOf: stateURL.appendingPathComponent("settings.json")))
                .flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
            var policy = Policy()
            if let data = try? Data(contentsOf: stateURL.appendingPathComponent("rules.json")),
               let rules = try? JSONDecoder().decode([String: ScrollRule].self, from: data) { policy.rules = rules }
            if let data = try? Data(contentsOf: stateURL.appendingPathComponent("speeds.json")),
               let speeds = try? JSONDecoder().decode([String: Double].self, from: data) { policy.speeds = speeds }
            let devices = HaloHID.devices().map(Device.init(properties:)).filter { $0.sender != 0 }
            policy.updateDevices(devices)
            var report = DiagnosticsReport(source: "cold", app: app(), state: .init(
                appRunning: running, accessibility: nil,
                recordScrolls: false, showIcon: settings["showIcon"] ?? true))
            report.state.matchSettings = settings["matchSettings"] ?? false
            report.state.clipboard = settings["clipboard"] ?? false
            let idKey = idKey
            report.devices = devices.map { DiagnosticsReport.DeviceEntry($0, displayName: AppDelegate.displayName($0), policy: policy, idKey: idKey) }
            report.state.naturalScrolling = naturalScrolling
            report.batteries = HaloHID.batteries().compactMap(Battery.init(properties:)).map(DiagnosticsReport.BatteryEntry.init)
            report.addEvents()
            report.notes = report.gaps()
            do { try write(report) } catch {
                FileHandle.standardError.write(Data("Could not write \(folder.path): \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        guard let text = try? String(contentsOf: markdown, encoding: .utf8) else { return 1 }
        let saved = (try? Data(contentsOf: json)).flatMap { try? DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: $0) }
        let age = Date().timeIntervalSince(saved?.app.exportedAt ?? .distantPast)
        let ago = age < 3600 ? "\(Int(age / 60)) min" : age < 86400 ? "\(Int(age / 3600)) h" : "\(Int(age / 86400)) d"
        if let change { print(change.hasPrefix("Unchanged: ") ? change : "Changed: \(change)") }
        let current = refreshed && saved?.source == "live" && age <= 60
        let source = saved?.source == "live" && !current ? "cached live" : saved?.source ?? "unknown"
        print("Halo diagnostics (\(source), exported \(ago) ago)")
        print("Summary: \(markdown.path)")
        print("Data:    \(json.path)")
        if !current {
            if change != nil && !refreshed {
                print(change?.hasPrefix("Unchanged: ") == true ? "Not current: Halo changed nothing and could not refresh the export."
                                                                : "Not current: Halo applied the change but could not refresh the export.")
            } else if sandbox {
                print("Not current. " + sandboxed)
            } else if running {
                print("Not current. " + unreachable + " Ask the person to click Copy (拷贝) beside Diagnostics Summary (诊断摘要) on Halo's Diagnostics page.")
            } else {
                print("Not current: Halo is not running. Ask the person to open Halo, then run this again.")
            }
        }
        print("")
        print(text)
        return 0
    }
}

extension AppDelegate {
    /// The Diagnostics page's export, made by its Copy button; whether it was written.
    func exportForPerson() -> Bool {
        let now = Date()
        do {
            try writeDiagnostics(.init(kind: "button", startedAt: now, endedAt: now))
            return true
        } catch {
            notice(L("Couldn’t export diagnostics: %@", error.localizedDescription))
            return false
        }
    }

    /// A passing line under the Diagnostics verdict (a change an agent made, a skill added, something that failed),
    /// gone after a few seconds unless something newer replaced it.
    func notice(_ text: String) {
        engine.status = text
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.engine.status == text else { return }
            self.engine.status = nil
            self.render()
        }
    }

    private func writeDiagnostics(_ request: DiagnosticsReport.RequestEntry) throws {
        try DiagnosticsExport.write(diagnosticsReport(request))
        // The log this export replaced; left behind, it would read as current.
        try? FileManager.default.removeItem(at: stateURL.appendingPathComponent("scroll-events.log"))
    }

    /// Lets `Halo --diagnostics` and `Halo --set` reach the running app without anyone clicking. Delivered even while
    /// Halo is in the background; costs nothing until a request comes.
    func listenForDiagnosticsRequests() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(diagnosticsRequested), name: DiagnosticsExport.request,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func diagnosticsRequested(_ note: Notification) {
        let center = DistributedNotificationCenter.default()
        let id = note.userInfo?["id"] as? String ?? ""
        let started = Date()
        let answer = { (error: String?, changed: String?) in
            var info = ["id": id]
            info["error"] = error
            info["changed"] = changed
            center.postNotificationName(DiagnosticsExport.done, object: nil, userInfo: info, deliverImmediately: true)
        }
        let refuse = { (reason: String) in answer(reason, nil) }
        if let what = note.userInfo?["set"] as? String {
            return applySetting(what, target: note.userInfo?["target"] as? String ?? "", value: note.userInfo?["value"] as? String ?? "",
                                started: started, answer: answer)
        }
        guard let name = note.userInfo?["run"] as? String else {
            // Any local process can ask; a burst of requests writes once and is answered with that export.
            if Date().timeIntervalSince(lastDiagnosticsExport) > 1 {
                guard (try? writeDiagnostics(.init(kind: "export", startedAt: started, endedAt: started))) != nil else {
                    return refuse("could not write the export")
                }
                lastDiagnosticsExport = Date()
            }
            return answer(nil, nil)
        }
        guard let run = DiagnosticsExport.Run(rawValue: name) else { return refuse("unknown check \(name)") }
        guard agentRun == nil else { return refuse("another check is running") }
        let finish = { [weak self] (seconds: Double?, result: String?) in
            guard let self else { return }
            self.agentRun = nil
            let request = DiagnosticsReport.RequestEntry(kind: run.rawValue, startedAt: started, endedAt: Date(), seconds: seconds, result: result)
            let wrote = (try? self.writeDiagnostics(request)) != nil
            if wrote { self.lastDiagnosticsExport = Date() }
            answer(wrote ? nil : "could not write the export", nil)
        }
        switch run {
        case .record:
            // Any local process can post this; a NaN would never come due and hold recording on for good.
            let seconds = note.userInfo?["seconds"] as? Double ?? 30
            guard seconds.isFinite else { return refuse("seconds must be a number") }
            let clamped = min(max(seconds, DiagnosticsExport.Run.recordSeconds.lowerBound), DiagnosticsExport.Run.recordSeconds.upperBound)
            setRecording(true)
            agentRun = run
            let before = engine.total
            DispatchQueue.main.asyncAfter(deadline: .now() + clamped) { [weak self] in
                guard let self else { return }
                finish(clamped, "\(self.engine.total - before) scrolls arrived")
                self.setRecording(false)
            }
        case .audio:
            guard !audioCheck.running else { return refuse("an audio check is already running") }
            // Without music the daemon reports nothing; say so now rather than after the check's 10-second wait.
            guard audio.state.playing, audio.state.output != nil else {
                return refuse("nothing is playing to a Bluetooth speaker or headphones: ask the person to play music on one, then run this again")
            }
            let previous = audioCheck.onEnd
            audioCheck.onEnd = { [weak self] outcome in
                previous?(outcome)
                self?.audioCheck.onEnd = previous
                finish(nil, "\(outcome)")
            }
            agentRun = run
            audioCheck.start()
        case .link:
            guard link.peer != nil else { return refuse("not paired with another Mac") }
            let previous = link.onChange
            link.onChange = { [weak self] in
                previous?()
                guard let self, !self.link.checking else { return }
                self.link.onChange = previous
                finish(nil, "verdict \(self.link.verdict?.rawValue ?? "none")")
            }
            agentRun = run
            link.check()
        }
        center.postNotificationName(DiagnosticsExport.started, object: nil, userInfo: ["id": id], deliverImmediately: true)
    }

    /// A change an agent asked for, by the ids in the export. It goes through the same paths as the switches, so the
    /// menu and window follow; the person gets a notification naming it, since nobody clicked anything.
    private func applySetting(_ what: String, target: String, value: String, started: Date,
                              answer: @escaping (String?, String?) -> Void) {
        let key = DiagnosticsExport.idKey
        let on: Bool? = ["on": true, "off": false][value]
        // The devices Halo shows; one it hides (a Universal Control helper) gets no rule an agent could not see either.
        let device = engine.menuDevices.first { DiagnosticsReport.deviceID($0, key: key) == target }
        var english: String
        let shown: String
        // A value already in place is not set again: setting it would stamp it as the newest and carry it to the
        // paired Mac. No notification for it either, and the answer says so.
        var unchanged = false
        switch what {
        case "reverse":
            guard let device else { return answer("no pointing device with id \(target); the ids are in the export", nil) }
            guard let on else { return answer("value must be on or off", nil) }
            let name = Self.agentName(device)
            // Both kinds of scroll: one set apart from the other is not yet what was asked.
            unchanged = [false, true].allSatisfy { engine.policy.rule(for: device, continuous: $0) == (on ? .reverse : .unchanged) }
            english = "\(name) reverse \(engine.isReversed(device) ? "on" : "off") → \(value)"
            shown = L("%@ reverse: %@", name, on ? L("on") : L("off"))
            if !unchanged { engine.setRule(on ? .reverse : .unchanged, for: device, by: "agent") }
        case "speed":
            guard let device else { return answer("no pointing device with id \(target); the ids are in the export", nil) }
            guard let speed = Double(value), Policy.speedSteps.contains(speed) else {
                return answer("speed must be one of " + Policy.speedSteps.map { "\($0)" }.joined(separator: ", "), nil)
            }
            guard !device.trackpad else { return answer("a trackpad has no wheel speed", nil) }
            // As in the window: speed applies to wheel steps, so a mouse that has sent none would show no change.
            guard engine.sentWheel(device) || engine.policy.speed(for: device) != 1 else {
                return answer("this device has sent no wheel steps since it connected, and speed applies only to those; ask the person to scroll it once", nil)
            }
            let name = Self.agentName(device)
            let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(value) }
            unchanged = engine.policy.speed(for: device) == speed
            english = "\(name) wheel speed \(format(engine.policy.speed(for: device)))× → \(format(speed))×"
            shown = L("%@ wheel speed: %@×", name, value)
            if !unchanged { engine.setSpeed(speed, for: device, by: "agent") }
        case "speaker-mic":
            guard let speaker = classic.connected().first(where: { $0.audio && $0.speaker && DiagnosticsReport.audioID($0.address, key: key) == target })
            else { return answer("no connected speaker with id \(target); the ids are in the export", nil) }
            guard let on else { return answer("value must be on or off", nil) }
            unchanged = audioRule(speaker.address) == on
            english = "\(speaker.name) microphone rule \(audioRule(speaker.address) ? "on" : "off") → \(value)"
            shown = L("%@ microphone rule: %@", speaker.name, on ? L("on") : L("off"))
            if !unchanged { setAudioRule(on, for: speaker.address, by: "agent") }
        default:
            return answer("unknown setting \(what)", nil)
        }
        if unchanged {
            english = "Unchanged: \(english) (already so)"
        } else {
            notice(L("An agent changed: %@", shown))
            notify(title: L("An agent changed Halo’s settings"), body: shown, id: "halo.agent.\(UUID().uuidString)")
        }
        audioDisplayChanged()
        render()
        let request = DiagnosticsReport.RequestEntry(kind: "set", startedAt: started, endedAt: Date(), result: english)
        guard (try? writeDiagnostics(request)) != nil else { return answer(unchanged ? "nothing changed, and could not write the export" : "changed, but could not write the export", english) }
        lastDiagnosticsExport = Date()
        answer(nil, english)
    }

    /// A device as a change made by an agent names it: the shown name, and for a device lent by the other Mac, whose
    /// built-in trackpad is named like this Mac's own, where it comes from.
    static func agentName(_ device: Device) -> String {
        device.local ? displayName(device) : displayName(device) + " · " + L("From another Mac")
    }

    /// Keeps the last scrolls for the export; turned on only for an agent's recording.
    func setRecording(_ on: Bool) {
        engine.recordScrolls = on
    }

    /// The running app's state as it is now. Reads what is already in memory, plus one listing of connected
    /// Bluetooth devices; starts no check.
    func diagnosticsReport(_ request: DiagnosticsReport.RequestEntry? = nil) -> DiagnosticsReport {
        let now = Date()
        let app = DiagnosticsExport.app(now: now)
        var state = DiagnosticsReport.State(appRunning: true, accessibility: engine.trusted,
                                            recordScrolls: engine.recordScrolls, showIcon: engine.showIcon)
        state.matchSettings = engine.matchSettings
        state.clipboard = engine.shareClipboard
        state.listening = engine.tap != nil
        state.reversing = engine.policy.enabled
        state.scrollsSeen = engine.total
        state.scrollsReversed = engine.reversed
        state.statusText = engine.stateText
        let declined = link.keyDeclined ? L("Halo wasn’t allowed to read the pairing key from the keychain; it will ask again when reopened") : nil
        let notices = [engine.status, declined].compactMap { $0 } + StateFiles.problems
        state.notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        state.naturalScrolling = DiagnosticsExport.naturalScrolling
        var report = DiagnosticsReport(source: "live", app: app, state: state)
        report.request = request

        let sightings = engine.sightings.values
        let idKey = DiagnosticsExport.idKey
        report.devices = engine.devices.values.sorted { $0.name < $1.name }.map { device in
            let seen = { (continuous: Bool) in sightings.first { $0.device == device && $0.continuous == continuous }?.count }
            return DiagnosticsReport.DeviceEntry(device, displayName: Self.displayName(device), policy: engine.policy, idKey: idKey,
                                                 wheelScrolls: seen(false), continuousScrolls: seen(true))
        }
        report.batteries = engine.batteries.map(DiagnosticsReport.BatteryEntry.init)
        report.scrollTools = engine.tools.map {
            .init(name: $0.name, bundleID: $0.bundleID, modifies: $0.modifies, isHalo: $0.isSelf)
        }
        report.directionCheck = .init(running: engine.check != nil, suspects: engine.check.map { $0.suspects.sorted() } ?? [],
                                      blockedDevice: engine.blocked.map { Self.displayName($0.device) },
                                      blockedBy: engine.blocked?.tools.map(\.name) ?? [])
        report.scrolls = engine.recentScrolls().map { s in
            .init(at: Date(timeIntervalSinceReferenceDate: s.wall), uptime: s.time, sender: s.sender, device: s.name,
                  continuous: s.continuous, input: s.input, output: s.output, phase: s.phase, momentum: s.momentum, reversed: s.reversed)
        }
        if let peer = link.peer {
            report.link = .init(peer: peer.name, lastSeen: peer.lastSeen, online: link.online, path: link.path.map { "\($0)" },
                                directAllowed: link.direct, checking: link.checking, verdict: link.verdict?.rawValue,
                                lastCheck: link.lastCheck, peerCheck: link.peerCheck, events: linkEvents)
        }
        let audioState = audio.state
        report.audioDevices = classic.connected().filter(\.audio).map { device in
            .init(name: device.name, address: device.address, idKey: idKey, speaker: device.speaker, output: audioState.output == device.address,
                  input: audioState.input == device.address, callQuality: audioState.callQuality.contains(device.address),
                  micInUseBy: audioState.micInUse[device.address].map { $0 ?? "unknown" },
                  micRule: device.speaker ? audioRule(device.address) : nil, battery: audioBattery(device)?.percent, rssi: device.rssi)
        }
        report.audioEvents = audioEvents.map {
            .init(at: $0.at, device: $0.device, text: $0.text, relayedCall: $0.relayedCall, context: $0.context)
        }
        if let started = audioCheck.started {
            report.audioCheck = .init(started: started, outcome: audioCheck.outcome.map { "\($0)" } ?? "running",
                                      samples: audioCheck.samples)
        }
        report.addEvents()
        var forecasts: [DiagnosticsReport.ForecastEntry] = []
        for battery in engine.batteries {
            let id = Events.batteryID(battery)
            if let forecast = BatteryHistory.shared.forecast(Events.batteryLogIDs(battery, among: engine.batteries)) { forecasts.append(.init(name: battery.name, id: id, forecast: forecast)) }
        }
        for device in classic.connected() where device.audio {
            let id = DiagnosticsReport.audioID(device.address, key: idKey)
            if let forecast = BatteryHistory.shared.forecast(id) { forecasts.append(.init(name: device.name, id: id, forecast: forecast)) }
        }
        // Before the history has loaded there is nothing to say either way.
        report.batteryForecasts = BatteryHistory.shared.loaded ? forecasts : nil
        let groups = deviceGroups()
        let entry = { (spec: RowSpec) in
            DiagnosticsReport.RowEntry(title: spec.title, facts: spec.facts, battery: spec.battery?.percent, on: spec.isOn, speed: spec.speed,
                                       lent: spec.lent)
        }
        let universalControl = engine.universalControlConnected
        let pageNotes = devicesNotes(groups.allPointing, universalControl: universalControl)
        let card = pairCardShown(universalControl: universalControl) ? pairCardContent() : nil
        report.page = .init(windowOpen: window?.isVisible == true, firstLaunch: firstLaunch, pairing: pairingStep,
                            rows: groups.mine.map(entry), notes: [pageNotes.above, pageNotes.below].compactMap { $0 },
                            pairCard: card.map { .init(title: $0.title, detail: $0.detail, button: $0.button) },
                            universalControlRows: groups.universalControl.map(entry),
                            universalControlConnected: engine.universalControl.connected,
                            universalControlCurrent: engine.universalControl.current, pointerHere: handoffWatch.here, menuOpen: menuOpen,
                            peerTitle: groups.peer?.title, peerRows: groups.peer?.rows.map { entry($0.0) }, peerNote: groups.peer?.note)
        report.notes = report.gaps()
        return report
    }
}

extension DiagnosticsReport {
    /// The last day of the event log, read from its files: the running app's and a cold export alike.
    mutating func addEvents(now: Date = Date()) {
        let folder = eventLog.folder
        guard EventLog.exists(folder: folder) else { return }
        eventLog.flush()
        // Only the newest, read from the end of the files: an export does not decode a whole busy day on the main thread.
        events = EventLog.read(folder: folder, since: now.addingTimeInterval(-86400), until: now, limit: Self.eventLimit)
        // With ~ for the home folder: the export is pasted into chats, and the full path names the account.
        eventsFolder = (folder.path as NSString).abbreviatingWithTildeInPath
        eventsError = eventLog.lastError
    }
}

/// The skill that tells agents on this Mac about the export and the checks: links to the copy inside the app, so
/// they follow the installed version; made from the Diagnostics page, or by an agent following the README (a link into
/// any copy of Halo's bundled skill counts as Halo's own). Two places cover the agents
/// whose sources were checked: `~/.agents/skills` (Codex, Gemini CLI, OpenCode, Copilot CLI) and `~/.claude/skills`
/// (Claude Code, Copilot in VS Code, OpenCode). All of them follow a linked folder.
enum AgentSkill {
    static var source: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("AgentSkill") }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) ? $0 : nil }
    }
    static var links: [URL] { Footprint(home: FileManager.default.homeDirectoryForCurrentUser).skillLinks }

    /// A link Halo made: one into some copy of Halo's bundled skill, made by the app or by an agent following the
    /// README. Anyone else's link or folder is theirs.
    private static func isOurs(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map(Footprint.isHaloSkill) == true
    }
    /// Any of the links points into this app.
    static var installed: Bool {
        guard let source else { return false }
        return links.contains {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path) else { return false }
            return URL(fileURLWithPath: target).standardizedFileURL.path == source.standardizedFileURL.path
        }
    }

    struct Taken: LocalizedError {
        let path: String
        var errorDescription: String? { L("%@ already holds a folder with that name; left it alone", path) }
    }

    /// Makes every link it can; a place holding someone's own folder of that name is left alone and reported.
    static func install() throws {
        guard let source else { return }
        let files = FileManager.default
        var taken: URL?
        for link in links {
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A link left by a Halo installed elsewhere is replaced; anything else there, a broken link included, stays.
            if isOurs(link) {
                try files.removeItem(at: link)
            } else if (try? files.attributesOfItem(atPath: link.path)) != nil {
                taken = link
                continue
            }
            try files.createSymbolicLink(at: link, withDestinationURL: source)
        }
        if let taken { throw Taken(path: (taken.path as NSString).abbreviatingWithTildeInPath) }
    }

    static func remove() throws {
        for link in links where isOurs(link) { try FileManager.default.removeItem(at: link) }
    }
}

extension AppDelegate {
    func agentSkillRow() -> NSView {
        agentSkillButton.target = self
        agentSkillButton.action = #selector(toggleAgentSkill)
        renderAgentSkill()
        return settingRow(title: L("Agent Skill"), detail: nil, control: agentSkillButton, detailField: agentSkillDetail, symbol: "terminal")
    }

    func renderAgentSkill() {
        agentSkillButton.title = AgentSkill.installed ? L("Remove") : L("Add")
        // Once added, the row says where it works rather than what it would do.
        agentSkillDetail.stringValue = AgentSkill.installed ? L("Available to new agent sessions") : L("Read diagnostics and adjust settings")
        agentSkillDetail.textColor = .secondaryLabelColor
        agentSkillButton.isEnabled = AgentSkill.source != nil
    }

    @objc func toggleAgentSkill() {
        do {
            if AgentSkill.installed {
                try AgentSkill.remove()
                notice(L("Removed; agents no longer load it"))
            } else {
                try AgentSkill.install()
                notice(L("Added; new agent sessions can use it"))
            }
        } catch {
            notice(L("Couldn’t change it: %@", error.localizedDescription))
        }
        renderAgentSkill()
        render()
    }
}
