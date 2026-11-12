// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreWLAN
import HaloCore
import IOBluetooth
import UserNotifications

/// Something that happened to a speaker or headphones: shown on its row for ten minutes and kept for the export.
struct AudioEvent {
    let at: Date
    let device: String
    let text: String
    /// A call relayed from an iPhone, which is turned off in FaceTime's settings.
    var relayedCall = false
    /// What else was going on, for finding a cause later: shown under the line and kept in the diagnostics export.
    var context: String?
}

/// The speaker rule on speaker rows, and the alerts for speakers and headphones.
///
/// A speaker plays music only: when the system makes it the microphone (it does so for a device that reconnects),
/// Halo puts the Mac's own microphone back, since a Bluetooth speaker used as a microphone drops to call quality for
/// as long as anything records. The rule is on unless turned off with the speaker row's microphone button.
/// Headphones are meant to be a microphone too, so they get no rule.
extension AppDelegate {
    private static var audioURL: URL { stateURL.appendingPathComponent("audio.json") }

    private struct AudioSettings: Codable {
        var rules: [String: Bool] = [:]
    }

    func loadAudio() {
        guard let saved = StateFiles.load(AudioSettings.self, Self.audioURL.lastPathComponent) else { return }
        audioRules = saved.rules
    }

    private func saveAudio() {
        guard StateFiles.mayWrite(Self.audioURL.lastPathComponent) else { return }
        try? FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        try? JSONEncoder().encode(AudioSettings(rules: audioRules)).write(to: Self.audioURL, options: .atomic)
    }

    /// A speaker's rule: keep the system microphone off it.
    func audioRule(_ address: String) -> Bool { audioRules[address] ?? true }

    func setAudioRule(_ on: Bool, for address: String, by: String = "person") {
        if audioRule(address) != on {
            Events.setting("speaker-mic", device: classic.connected().first { $0.address == address }?.name,
                           id: DiagnosticsReport.audioID(address, key: Events.idKey), from: Events.onOff(audioRule(address)), to: Events.onOff(on), by: by)
        }
        audioRules[address] = on ? nil : false
        saveAudio()
        enforceAudioRules()
        audioDisplayChanged()
    }

    /// "MacBook Pro", from its microphone's name, for short labels.
    var macName: String {
        let name = audio.builtInMicrophoneName ?? "Mac"
        for suffix in [" Microphone", "麦克风", " 麦克风"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Runs on every Core Audio change.
    func enforceAudioRules() {
        let state = audio.state
        let connected = classic.connected()
        trackCallMode(connected)
        // The log is read only while sound goes to a Bluetooth device.
        bluetoothLog.setActive(state.playing && state.output != nil)
        let devices = connected.filter(\.audio)
        if let input = state.input, let speaker = devices.first(where: { $0.address == input && $0.speaker }), audioRule(input) {
            // The system can make a reconnecting device the input again at once; one revert every few seconds rather
            // than a tug of war with it. A revert held back is checked once more when the few seconds are up, since
            // no further change may come to trigger it.
            let since = Date().timeIntervalSince(lastMicRevert[input] ?? .distantPast)
            if since > 5 {
                lastMicRevert[input] = Date()
                switch audio.restoreInput(lidClosed: AudioRoutes.lidClosed) {
                case let .switched(name, builtIn):
                    if micRevertFailed.remove(input) != nil { deviceAlert[input] = nil }
                    noteAudioEvent(speaker.name, L("The system made it the microphone; switched back to %@", builtIn ? macName : name))
                case .failed:
                    if micRevertFailed.insert(input).inserted {
                        noteAudioEvent(speaker.name, L("The system made it the microphone; couldn’t switch it back"), address: input, trouble: true)
                    }
                case .nowhere:
                    break  // The row says so (`describeAudio`).
                }
            } else if revertRecheck.insert(input).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.1 - since) { [weak self] in
                    self?.revertRecheck.remove(input)
                    self?.enforceAudioRules()
                }
            }
        }
        // A speaker whose microphone an app chose itself: nothing Halo can change, so it says which app, once per episode.
        // A speaker the person made the input themselves (rule off) is their choice, not news, and ends any episode.
        if let input = state.input, !audioRule(input) { micNotified.remove(input) }
        for speaker in devices where speaker.speaker && state.input != speaker.address {
            guard let app = state.micInUse[speaker.address] else {
                micNotified.remove(speaker.address)
                continue
            }
            guard micNotified.insert(speaker.address).inserted else { continue }
            let text = app.map { L("%@ is using its microphone, so it dropped to call quality", $0) } ?? L("An app is using its microphone, so it dropped to call quality")
            noteAudioEvent(speaker.name, text)
            notify(title: speaker.name, body: text)
        }
    }

    /// A speaker's or headphones' level for the event log, when it is new; the name is looked up only then.
    func noteAudioBattery(_ address: String, _ percent: Int) {
        let name = classic.connected().first { $0.address == address }?.name ?? L("Bluetooth Device")
        let reading = BatteryLedger.Reading(id: DiagnosticsReport.audioID(address, key: Events.idKey), name: name, percent: percent,
                                            charging: false, source: "bluetoothd")
        audioBatteryLedger.note(reading).forEach(Events.record)
    }

    /// The window shows the new state; an open menu keeps its snapshot until it next opens (`rebuildMenu`).
    func audioDisplayChanged() {
        settingsChanged()
    }

    func noteAudioEvent(_ device: String, _ text: String, address: String? = nil, relayedCall: Bool = false, trouble: Bool = false,
                        context: String? = nil) {
        audioEvents.append(AudioEvent(at: Date(), device: device, text: text, relayedCall: relayedCall, context: context))
        Events.record(EventRecord(kind: .audio, device: device, id: address.map { DiagnosticsReport.audioID($0, key: Events.idKey) },
                                  text: text, detail: context))
        if audioEvents.count > 100 { audioEvents.removeFirst(audioEvents.count - 100) }
        // A call from the iPhone is turned off in FaceTime; the row says where, as it is the one thing to do about it.
        if let address {
            deviceAlert[address] = (Date(), relayedCall ? text + L("; %@", L("turn off Calls from iPhone in FaceTime settings")) : text, trouble, device)
            settingsChanged()
        }
    }

    /// A speaker or headphones that had a weak signal in the last ten minutes and has not disconnected since, by name,
    /// with what its row says about it. Read from memory, on every refresh of the window.
    var recentAudioTrouble: (String, String)? {
        deviceAlert.values.filter { $0.trouble && Date().timeIntervalSince($0.at) < 600 }
            .max { $0.at < $1.at }.map { ($0.device, $0.text) }
    }

    // MARK: Alerts

    /// Connects and disconnects of audio devices, and bluetoothd's log while one plays.
    func startAudioWatch() {
        bluetoothLog.onEvent = { [weak self] event in self?.bluetoothEvent(event) }
        if let notice = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:))) {
            bluetoothNotices.append(notice)
        }
        // A speaker that connected before Halo started may have reported its battery already.
        BluetoothLog.recentBatteries { [weak self] found in
            guard let self else { return }
            for (address, reading) in found where (self.reportedBattery[address]?.at ?? .distantPast) < reading.at {
                self.reportedBattery[address] = reading
                self.noteAudioBattery(address, reading.percent)
            }
            self.audioDisplayChanged()
            self.batteryReadingsChanged()
        }
    }

    /// Called for every device that connects, and once for each already connected at registration.
    @objc func bluetoothConnected(_ notice: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) else { return }
        let name = device.name ?? L("Bluetooth Device")
        // At registration the system reports what is already connected; that is not news.
        if Date().timeIntervalSince(launchedAt) > 5 { noteAudioEvent(name, L("Connected"), address: Address.normalize(device.addressString ?? "")) }
        if let notice = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:))) {
            bluetoothNotices.append(notice)
        }
        // Headphones fill in their charge a moment after connecting; look again then.
        batteryReadingsChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.batteryReadingsChanged() }
    }

    @objc func bluetoothDisconnected(_ notice: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notice.unregister()
        bluetoothNotices.removeAll { $0 === notice }
        let address = Address.normalize(device.addressString ?? "")
        noteAudioEvent(device.name ?? L("Bluetooth Device"), L("Disconnected"), address: address)
        // Its report no longer describes anything here, even if the system still calls it connected for a moment;
        // the mark leaves it out now and looks again once the system has caught up.
        reportedBattery.removeValue(forKey: address)
        micNotified.remove(address)
        audioBatteryLedger.forget(DiagnosticsReport.audioID(address, key: Events.idKey))
        audioDisplayChanged()
        batteryReadingsChanged(gone: address)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.batteryReadingsChanged() }
    }

    private func bluetoothEvent(_ event: BluetoothLogParser.Event) {
        switch event {
        case .quality(let retransmitted):
            // Reports carry no address; they belong to whatever plays.
            guard let output = audio.state.output else { return }
            // A run belongs to one device; another one playing starts afresh.
            if weakRunDevice != output {
                weakRunDevice = output
                weakRun = 0
            }
            weakRun = retransmitted >= 65 ? weakRun + 1 : 0
            guard weakRun == 5 else { return }
            let connected = classic.connected()
            let device = connected.first { $0.address == output }
            var bursts = (weakBursts[output] ?? []).filter { Date().timeIntervalSince($0) < 600 }
            bursts.append(Date())
            weakBursts[output] = bursts
            // Position is not what helps here; reconnecting is, so that is the advice.
            noteAudioEvent(device?.name ?? L("Bluetooth Device"), bursts.count >= 3 ? L("Bluetooth link struggled %ld times in 10 minutes. Try disconnecting and reconnecting it", bursts.count)
                                                                          : L("Bluetooth link is struggling; sound may cut out"),
                           address: output, trouble: true, context: weakLinkContext(device, retransmitted: retransmitted, others: connected))
            audioDisplayChanged()
        case .ring(let address):
            ringAt[address] = Date()
        case .battery(let address, let percent):
            // Reported every few seconds; only a new level is worth redrawing for.
            // A new level, or the first report after an old one had stopped being shown.
            let previous = reportedBattery[address]
            let changed = previous?.percent != percent || Date().timeIntervalSince(previous?.at ?? .distantPast) >= 3600
            reportedBattery[address] = (percent, Date())
            if previous?.percent != percent { noteAudioBattery(address, percent) }
            if changed {
                audioDisplayChanged()
                batteryReadingsChanged()
            }
        }
    }

    /// The circumstances of a weak link: Wi-Fi band and channel (2.4 GHz Wi-Fi shares the air with Bluetooth), the
    /// speaker's charge, and the other Bluetooth devices connected. Read once per event.
    private func weakLinkContext(_ device: ClassicDevice?, retransmitted: Double, others: [ClassicDevice]) -> String {
        var parts = [L("Retransmitted %ld%%", Int(retransmitted.rounded()))]
        if let channel = CWWiFiClient.shared().interface()?.wlanChannel() {
            let band: String
            switch channel.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default: band = ""
            }
            parts.append(L("Wi‑Fi %@ channel %ld", band, channel.channelNumber).replacingOccurrences(of: "  ", with: " "))
        }
        if let battery = device.flatMap(audioBattery) { parts.append(L("Battery %ld%%", battery.percent)) }
        let rest = others.filter { $0.address != device?.address }.map(\.name)
        parts.append(rest.isEmpty ? L("No other Bluetooth devices") : L("Also connected: %@", rest.joined(separator: L("LIST_SEPARATOR"))))
        return parts.joined(separator: " · ")
    }

    /// Call mode comes and goes with the device's sample rate. The cause is settled when it ends, since the ring
    /// (read from the log) and the recording app can each be noticed a moment after the rate changes: a ring from ten
    /// seconds before the start onwards, else the first app seen recording from it during the episode.
    private func trackCallMode(_ connected: [ClassicDevice]) {
        let state = audio.state
        let now = state.callQuality
        let names = Dictionary(connected.map { ($0.address, $0.name) }, uniquingKeysWith: { first, _ in first })
        for address in now {
            let app = state.micInUse[address] ?? nil
            if let started = callStarted[address] {
                if started.app == nil, let app { callStarted[address] = (started.at, app) }
            } else {
                callStarted[address] = (Date(), app)
            }
        }
        for address in lastCallQuality.subtracting(now) {
            guard let start = callStarted.removeValue(forKey: address) else { continue }
            // A device that went away mid-call left no call to report; its disconnect is the news.
            guard names[address] != nil else { continue }
            let rang = (ringAt[address] ?? .distantPast) >= start.at.addingTimeInterval(-10)
            let seconds = max(1, Int(Date().timeIntervalSince(start.at).rounded()))
            let time = Self.clock.string(from: start.at)
            let text = rang ? L("%@ Incoming call; call mode for %ld s", time, seconds)
                : start.app.map { L("%1$@ %2$@ used its microphone; call mode for %3$ld s", time, $0, seconds) } ?? L("%@ Call mode for %ld s", time, seconds)
            noteAudioEvent(names[address] ?? L("Bluetooth Device"), text, address: address, relayedCall: rang)
        }
        lastCallQuality = now
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// One notification per `id`: a later one with the same id replaces it.
    func notify(title: String, body: String, id: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Asked for the first time it is needed, not at launch.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: id ?? "halo.mic.\(title)", content: content, trigger: nil))
        }
    }

    // MARK: Rows

    /// A speaker or headphones: lit and marked while sound goes there, a click sends it there; a speaker also gets
    /// the round microphone button for its rule.
    func describeAudio(_ spec: inout RowSpec, device: ClassicDevice) {
        let address = device.address
        let state = audio.state
        let rule = audioRule(address)
        if state.output == address {
            spec.lit = true
            spec.facts.append(state.playing ? L("Playing") : L("Sound output"))
        } else {
            spec.onClick = { [weak self] in self?.audio.useOutput(address) }
        }
        let toggle: (Bool) -> Void = { [weak self] keep in self?.setAudioRule(keep, for: address) }
        // Earbuds and case each have their own charge; the row's battery shows the lower earbud.
        if let left = device.levels["left"], let right = device.levels["right"] {
            spec.facts.append(L("Left %ld%% · Right %ld%%", left, right) + (device.levels["case"].map { L(" · Case %ld%%", $0) } ?? ""))
        }
        defer {
            // A speaker reports every few seconds, and Halo reads those reports while sound plays, so a reading is
            // current then and needs no time. After playback stops it ages: from ten minutes it says how old it is,
            // and past an hour it is not shown at all.
            if device.levels.isEmpty, let reported = reportedBattery[address] {
                let minutes = Int(Date().timeIntervalSince(reported.at) / 60)
                if (10..<60).contains(minutes) { spec.facts.append(L("Battery from about %ld min ago", minutes)) }
                // The tenth minute, each minute after it, and the hour that takes the reading away.
                if minutes < 60 { spec.changes(at: reported.at.addingTimeInterval(Double(max(minutes + 1, 10)) * 60)) }
            }
        }
        if let alert = deviceAlert[address], Date().timeIntervalSince(alert.at) < 600 {
            spec.facts.append(alert.text)
            spec.changes(at: alert.at.addingTimeInterval(600))
        }
        let mac = macName
        if let app = state.micInUse[address] {
            // Only an app's own choice is a warning; a speaker the person made the system microphone is shown below.
            if device.speaker, state.input != address {
                spec.facts.append(app.map { L("%@ is using its microphone · Call quality", $0) } ?? L("An app is using its microphone · Call quality"))
                spec.mic = .init(look: .warning, help: L("The app chose this microphone itself, which Halo can’t change. Pick %@ in the app’s audio settings", mac), toggle: nil)
                return
            }
            // Headphones are meant to be a microphone; just say it is in use.
            if !device.speaker { spec.facts.append(app.map { L("%@ is using the microphone", $0) } ?? L("Microphone in use")) }
        }
        if state.callQuality.contains(address), device.speaker {
            spec.facts.append(L("Switched to call mode"))
        }
        if device.speaker {
            if rule, state.input == address, audio.restoreTarget(lidClosed: AudioRoutes.lidClosed) == nil {
                // On a Mac with no microphone of its own (or its lid closed) and none other connected, there is nothing
                // to switch to: the row says so rather than promising music only.
                spec.facts.append(L("Also the system microphone · No other microphone to switch to"))
                spec.mic = .kept(toggle, stuck: true)
            } else if rule {
                spec.facts.append(L("Music only"))
                spec.mic = .kept(toggle, stuck: false)
            } else {
                if state.input == address {
                    spec.facts.append(state.micInUse[address] != nil ? L("Also the system microphone · Call quality") : L("Also the system microphone"))
                }
                spec.mic = .used(toggle, stuck: state.input == address && audio.restoreTarget(lidClosed: AudioRoutes.lidClosed) == nil)
            }
        }
    }

    /// A battery for an audio row: the headphones' own reading (the lower earbud), else what a speaker reported over
    /// its hands-free link.
    func audioBattery(_ device: ClassicDevice) -> Battery? {
        if let percent = device.levels["single"] ?? [device.levels["left"], device.levels["right"]].compactMap({ $0 }).min() {
            return Battery(name: device.name, serial: device.address, percent: percent)
        }
        guard let reported = reportedBattery[device.address], Date().timeIntervalSince(reported.at) < 3600 else { return nil }
        return Battery(name: device.name, serial: device.address, percent: reported.percent)
    }

    /// The menu-bar mark follows the readings now, and again when the next one still shown turns an hour old and
    /// stops counting: one timer, replaced on every change, never repeating.
    func batteryReadingsChanged(gone: String? = nil) {
        updateBatteryUI(gone: gone)
        settingsChanged()
        // The other Mac shows these too.
        link.snapshotChanged()
        batteryAgeWork?.cancel()
        guard let next = reportedBattery.values.map(\.at).filter({ Date().timeIntervalSince($0) < 3600 }).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.audioDisplayChanged()
            self?.batteryReadingsChanged()
        }
        batteryAgeWork = work
        // Wall-clock time, so an hour that passes while the Mac sleeps counts.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, next.addingTimeInterval(3601).timeIntervalSinceNow), execute: work)
    }

    /// Speakers and headphones count towards the menu bar's low-battery mark like any other peripheral; `gone` is one
    /// that just disconnected, which the system may still list for a moment.
    func audioBatteries(gone: String? = nil) -> [Battery] {
        classic.connected().filter { $0.audio && $0.address != gone }.compactMap(audioBattery)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Shown even while Halo's own window is in front, where the system would otherwise hold the banner back.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
