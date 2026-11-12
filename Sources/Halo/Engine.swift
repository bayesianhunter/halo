// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloHID
import HaloCore

final class Engine {
    let universalControl = UniversalControlWatch()
    private var universalControlDevices = UniversalControlDevices()
    /// Configuration rows can outlive an absent UC service; the actual source catalog remains live devices only.
    var configurationDevices: [Device] {
        universalControlDevices.displayed(alongside: Array(devices.values), connected: universalControl.connected)
    }
    var selectionPolicy: Policy {
        var selection = policy
        selection.updateDevices(configurationDevices)
        return selection
    }
    func updateUniversalControlDevices() {
        universalControlDevices.update(Array(devices.values), connected: universalControl.connected, session: universalControl.session)
    }
    var policy = Policy()
    var sources = SourceCatalog()
    var devices: [UInt64: Device] { sources.devices }
    var sightings: [String: SourceSighting] { sources.sightings }
    /// A transient notice (errors, an export); the steady state is `stateText`.
    var status: String? {
        didSet { if status != oldValue { onStatusChanged?() } }
    }
    var onStatusChanged: (() -> Void)?
    /// The tap was created or removed: listening started or stopped, whether or not reversing did.
    var onListeningChanged: (() -> Void)?
    /// Whether the last scrolls are kept for the export; on only while an agent records (`--record`). Never saved: a
    /// recording cut short by a crash or a forced quit must not stay on into every later launch.
    var recordScrolls = false {
        didSet {
            guard recordScrolls != oldValue else { return }
            if !recordScrolls {
                recent = []
                recentNext = 0
            }
        }
    }
    /// Whether the menu bar icon stays visible; hidden, it still appears while something needs attention.
    var showIcon = true {
        didSet {
            guard showIcon != oldValue else { return }
            persistSettings()
        }
    }
    /// Whether Halo stays in the Dock, where a click opens Settings; off, it is there only while Settings is open.
    var showDock = false {
        didSet {
            guard showDock != oldValue else { return }
            persistSettings()
        }
    }
    /// Whether a device's reverse switch and wheel speed follow changes made on the paired Mac. Off until the person
    /// turns it on, since it is the one thing the link may change here.
    var matchSettings = false {
        didSet {
            guard matchSettings != oldValue else { return }
            persistSettings()
        }
    }
    /// Whether the clipboard follows the person to the paired Mac and back. Off until turned on.
    var shareClipboard = false {
        didSet {
            guard shareClipboard != oldValue else { return }
            persistSettings()
        }
    }
    /// When each device's settings were last changed here or taken from the paired Mac, by `SettingSync` key.
    private(set) var settingChanges: [String: Date] = [:]
    var trusted = AXIsProcessTrusted()
    /// The most recent scrolls as raw numbers, a fixed ring the event tap writes into without formatting anything;
    /// text is made only when the diagnostics page or an export asks for it.
    struct Scroll {
        /// Seconds since boot, for pairing with the event tap; `wall` is the clock time, which keeps counting while
        /// the Mac sleeps, so exported scrolls line up with link and audio events.
        var time: TimeInterval
        var wall: CFAbsoluteTime
        var sender: UInt64
        var continuous: Bool
        var input: Int64
        var output: Int64
        var phase: Int64
        var momentum: Int64
        var reversed: Bool
        /// The device as known when it scrolled: a sender listed only later still reads as unknown here.
        var name: String?
    }
    static let recentCapacity = 512
    private var recent: [Scroll] = []
    private var recentNext = 0
    var total = 0
    var reversed = 0
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var safetyTimer: Timer?
    /// Device arrivals and removals are told by `ServiceWatch`; once it runs, the minute-by-minute listing started at
    /// launch is stopped, and a device that goes missing is listed once more after `confirmAfter` to log its disconnect.
    var devicesWatched = false {
        didSet {
            guard devicesWatched else { return }
            safetyTimer?.invalidate()
            safetyTimer = nil
        }
    }
    /// One listing after a device went missing, while nothing lists devices every minute.
    private var confirmTimer: Timer?
    /// Peripheral batteries as the system announces them: a new level, a cable in or out, a device coming or going.
    let batteryWatch = BatteryWatch()
    private var accessibilityObserver: NotificationRelay?
    /// When the last scroll came, so the first one after a pause looks at the event taps again.
    private var lastScroll: TimeInterval = 0
    static let scrollPause: TimeInterval = 1
    var refreshing = false
    var refreshAgain = false
    /// When each unlisted sender was last looked up, so it triggers a lookup every few seconds rather than one per event.
    /// A handoff can scroll before the system lists the device, so one lookup is not always enough.
    var unresolved: [UInt64: TimeInterval] = [:]
    static let lookupRetry: TimeInterval = 2
    /// Devices the event tap looked up by sender itself, until the next full listing includes them.
    var quick: [UInt64: Device] = [:]
    /// Every process tapping scroll events, Halo included, as of the last scan.
    var tools: [ScrollTool] = []
    private var tapSummary: [pid_t: Bool] = [:]
    var onToolsChanged: (() -> Void)?
    /// A running direction check, and what the last one found.
    var check: DirectionCheck?
    /// The last check ended without a single scroll that Halo reversed (nobody scrolled such a device in time). The
    /// next one starts another, so a program that undoes Halo is still found when two login items start together and
    /// nobody scrolls for a minute. A check that saw reversed scrolls and still could not judge is not repeated this
    /// way, so a running tool never costs standing taps. With a device already found blocked, only its scroll counts.
    var recheckOnReversedScroll = false
    var blocked: Blocked?
    var onBlockedChanged: (() -> Void)?
    var batteries: [Battery] = []
    private var registryBatteries: [Battery] = []
    /// Created only by the app, never by the command-line modes, so the Bluetooth prompt comes from the bundle.
    var ble: BLEBatteries?
    var onBatteriesChanged: (() -> Void)?
    var onActiveChanged: (() -> Void)?
    /// After a device refresh or a rule change; the link uses it to tell the paired Mac, if the list changed.
    var onDevicesChanged: (() -> Void)?
    var appsObservation: NSKeyValueObservation?
    let inventoryQueue = DispatchQueue(label: "halo.inventory", qos: .utility)
    /// What the event log last said was there, so only arrivals, departures and new battery levels are logged.
    private var devicePresence = Presence<Device>(confirmsRemoval: true, confirmAfter: 60)
    private var toolPresence = Presence<ScrollTool>()
    private var batteryLedger = BatteryLedger()

    init() {
        if let rules = StateFiles.load([String: ScrollRule].self, "rules.json") { policy.rules = rules }
        if let speeds = StateFiles.load([String: Double].self, "speeds.json") { policy.speeds = speeds }
        if let changes = StateFiles.load([String: Date].self, "changes.json") { settingChanges = changes }
        if let settings = StateFiles.load([String: Bool].self, "settings.json") {
            showIcon = settings["showIcon"] ?? true
            matchSettings = settings["matchSettings"] ?? false
            shareClipboard = settings["clipboard"] ?? false
            showDock = settings["showDock"] ?? false
        }
        scanTools()
        // Devices are listed once and cached; they are listed again only when something changes: the system adds or
        // removes a HID service, an unlisted sender scrolls, a wake, or (without those callbacks) the slow safety check.
        // Other scroll tools are mostly menu-bar apps, and NSWorkspace posts no launch or quit notifications for those,
        // so watch the running-application list itself. A new app installs its tap a moment after launching.
        appsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            for delay in [0.2, 1.5, 4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scanTools() }
            }
        }
        HaloHID.prepareLookup()
        refresh()
        refreshBatteries()
        // Until `devicesWatched` says the system's callbacks run, which stops it.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        safetyTimer?.tolerance = 15
        // Bluetooth LE batteries push their own changes (`BLEBatteries`); the registry's are announced by the system.
        batteryWatch.onChange = { [weak self] in self?.refreshRegistryBatteries() }
        if !batteryWatch.start() { Events.app("battery notifications unavailable") }
    }

    /// Lists who taps scroll events. Whether another one undoes Halo's direction is measured (`checkDirection`), not
    /// guessed from its name.
    func scanTools() {
        let taps = ScrollTool.taps()
        guard taps != tapSummary else { return }
        tapSummary = taps
        let suspects = suspectKeys
        tools = ScrollTool.describe(taps)
        noteTools()
        // Only a change in who could interfere calls for a new check, not a listen-only tap coming and going.
        if suspectKeys != suspects { checkDirection() }
        onToolsChanged?()
    }

    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        // HID enumeration stays outside the event callback.
        inventoryQueue.async { [weak self] in
            let records = HaloHID.devices()
            let list = records.map(Device.init(properties:))
            DispatchQueue.main.async {
                guard let self else { return }
                let before = self.sources.revision
                self.sources.updateDevices(list)
                self.updateUniversalControlDevices()
                self.noteDevices(list)
                let devicesChanged = self.sources.revision != before
                if devicesChanged {
                    self.unresolved.removeAll()
                    self.quick.removeAll()
                    self.refreshBatteries()
                }
                let policyChanged = self.policy.updateDevices(list)
                if policyChanged { self.persistRules(); self.persistSpeeds() }
                self.refreshing = false
                self.applyEnabled()
                self.dropStaleBlocked()
                if devicesChanged || policyChanged { self.onDevicesChanged?() }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    func refreshBatteries() {
        ble?.refresh()
        refreshRegistryBatteries()
    }

    /// The registry alone, without asking Bluetooth LE devices anything: cheap enough to notice a cable often.
    func refreshRegistryBatteries() {
        inventoryQueue.async { [weak self] in
            let list = HaloHID.batteries().compactMap(Battery.init(properties:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.registryBatteries = list
                Events.batterySerials.update(list)
                self.mergeBatteries()
            }
        }
    }

    func mergeBatteries() {
        let merged = Battery.merge(registryBatteries, ble.map { Array($0.levels.values) } ?? [])
        guard merged != batteries else { return }
        batteries = merged
        onBatteriesChanged?()
        // Registry readings carry the serial; the rest came over Bluetooth LE.
        let fromRegistry = Set(registryBatteries.map { $0.name.lowercased() })
        let readings = merged.map { battery in
            BatteryLedger.Reading(id: Events.batteryID(battery), name: battery.name, percent: battery.percent, charging: battery.charging,
                                  source: fromRegistry.contains(battery.name.lowercased()) ? "registry" : "ble")
        }
        batteryLedger.update(readings).forEach(Events.record)
    }

    /// Pointing devices the person would recognise, attached here or lent by the other Mac; Universal Control's own
    /// helpers stay out. Called after every listing; only a difference becomes an event.
    private func noteDevices(_ list: [Device]) {
        var shown: [String: Device] = [:]
        for device in list where device.sender != 0
            && (device.local || (device.name.hasPrefix("V-") && device.transport != "UniversalControl")) {
            let key = Events.presenceKey(device)
            if shown[key] == nil { shown[key] = device }
        }
        let change = devicePresence.update(shown)
        change.present.forEach { Events.device($0, "present") }
        change.added.forEach { Events.device($0, $0.local ? "connected" : "lent") }
        for (device, at) in zip(change.removed, change.removedAt) { Events.device(device, device.local ? "disconnected" : "returned", at: at) }
        // A removal needs a second listing a minute later to count. Without the minute-by-minute listing, nothing else
        // may list devices for hours, so one is scheduled; any listing before it moves it later.
        confirmTimer?.invalidate()
        confirmTimer = nil
        if devicesWatched, devicePresence.awaitingConfirmation {
            confirmTimer = Timer.scheduledTimer(withTimeInterval: devicePresence.confirmAfter + 5, repeats: false) { [weak self] _ in self?.refresh() }
            confirmTimer?.tolerance = 5
        }
    }

    /// Other programs with a scroll tap, as they come and go.
    private func noteTools() {
        var shown: [String: ScrollTool] = [:]
        for tool in tools where !tool.isSelf { shown[tool.bundleID ?? tool.name] = tool }
        let change = toolPresence.update(shown)
        let note = { (tool: ScrollTool, event: String) in
            Events.record(EventRecord(kind: .tool, event: event, device: tool.name, text: tool.bundleID,
                                      detail: tool.modifies ? "can modify scrolling" : "listen-only"))
        }
        change.present.forEach { note($0, "present") }
        change.added.forEach { note($0, "started") }
        change.removed.forEach { note($0, "stopped") }
    }

    func battery(for device: Device) -> Battery? {
        if !device.serial.isEmpty,
           let match = batteries.first(where: { $0.serial.caseInsensitiveCompare(device.serial) == .orderedSame }) {
            return match
        }
        return batteries.first { $0.serial.isEmpty && $0.name.caseInsensitiveCompare(device.name) == .orderedSame }
    }

    /// One switch per device: both scroll kinds follow it, so a mouse with smooth scrolling cannot end up half reversed.
    func setRule(_ rule: ScrollRule, for device: Device, by: String = "person") {
        var selection = selectionPolicy
        let before = [false, true].contains { selection.rule(for: device, continuous: $0) == .reverse }
        for continuous in [false, true] { selection.setRule(rule, for: device, continuous: continuous) }
        policy.rules = selection.rules
        if before != (rule == .reverse) {
            Events.setting("reverse", device: AppDelegate.displayName(device), id: Events.deviceID(device),
                           from: Events.onOff(before), to: Events.onOff(rule == .reverse), by: by)
        }
        persistRules()
        noteChange(device, SettingSync.reverseKey)
        check?.restart()
        checkDirection()
        onDevicesChanged?()
    }

    func setSpeed(_ speed: Double, for device: Device, by: String = "person") {
        var selection = selectionPolicy
        if selection.speed(for: device) != speed {
            Events.setting("speed", device: AppDelegate.displayName(device), id: Events.deviceID(device),
                           from: Events.speed(selection.speed(for: device)), to: Events.speed(speed), by: by)
        }
        selection.setSpeed(speed, for: device)
        policy.speeds = selection.speeds
        persistSpeeds()
        noteChange(device, SettingSync.speedKey)
        onDevicesChanged?()
    }

    /// How the paired Mac names this device in its settings: an attached one by its own name, one lent through
    /// Universal Control by the name without "V-". Nil for anything else, which never follows the other Mac.
    func syncKey(_ device: Device) -> String? {
        SettingSync.localKey(for: device, among: configurationDevices)
    }

    /// The setting as it stands here, for the paired Mac: each value only once the person has set it on either Mac.
    /// Wheel and smooth scrolling set apart in the Diagnostics table do not follow, since one switch cannot say both.
    func setting(for device: Device) -> LinkSetting? {
        guard let key = syncKey(device) else { return nil }
        let rules = [false, true].map { policy.rule(for: device, continuous: $0) }
        let reversedChanged = rules[0] == rules[1] ? settingChanges[SettingSync.reverseKey(key)] : nil
        let speedChanged = device.trackpad ? nil : settingChanges[SettingSync.speedKey(key)]
        guard reversedChanged != nil || speedChanged != nil else { return nil }
        let name = device.local ? device.name : String(device.name.dropFirst(2))
        return LinkSetting(name: name, builtIn: name.hasPrefix("Apple Internal"), own: device.local,
                           reversed: reversedChanged.map { _ in rules[0] == .reverse }, reversedChanged: reversedChanged,
                           natural: DiagnosticsExport.naturalScrolling,
                           speed: speedChanged.map { _ in policy.speed(for: device) }, speedChanged: speedChanged)
    }

    /// Applies the newer values of a setting from the paired Mac, keeping their times so they are not sent back as
    /// newer ones. Checked again here: taking one setting lists the devices again, which may already have taken it.
    func take(_ setting: LinkSetting, for device: Device) {
        guard let key = syncKey(device) else { return }
        var took = false
        let reverseKey = SettingSync.reverseKey(key), speedKey = SettingSync.speedKey(key)
        if let reversed = setting.reversed(naturalHere: DiagnosticsExport.naturalScrolling), let at = setting.reversedChanged,
           SettingSync.takes(at, over: settingChanges[reverseKey]),
           policy.rule(for: device, continuous: false) == policy.rule(for: device, continuous: true) {
            let before = isReversed(device)
            for continuous in [false, true] { policy.setRule(reversed ? .reverse : .unchanged, for: device, continuous: continuous) }
            if before != reversed {
                Events.setting("reverse", device: AppDelegate.displayName(device), id: Events.deviceID(device),
                               from: Events.onOff(before), to: Events.onOff(reversed), by: "other Mac")
            }
            persistRules()
            settingChanges[reverseKey] = at
            took = true
        }
        if let speed = setting.speed, let at = setting.speedChanged, !device.trackpad, SettingSync.takes(at, over: settingChanges[speedKey]) {
            if policy.speed(for: device) != speed {
                Events.setting("speed", device: AppDelegate.displayName(device), id: Events.deviceID(device),
                               from: Events.speed(policy.speed(for: device)), to: Events.speed(speed), by: "other Mac")
            }
            policy.setSpeed(speed, for: device)
            persistSpeeds()
            settingChanges[speedKey] = at
            took = true
        }
        guard took else { return }
        persistChanges()
        check?.restart()
        checkDirection()
        onDevicesChanged?()
    }

    /// The pair's sharing switches as this Mac has them, each with when it was last set here or taken from the other Mac.
    var sharing: LinkSharing {
        LinkSharing(match: settingChanges[Self.matchKey].map { _ in matchSettings }, matchChanged: settingChanges[Self.matchKey],
                    clipboard: settingChanges[Self.clipboardKey].map { _ in shareClipboard }, clipboardChanged: settingChanges[Self.clipboardKey])
    }
    private static let matchKey = "#sharing.match", clipboardKey = "#sharing.clipboard"

    /// The person flipped a sharing switch here; the other Mac follows.
    func setMatchSettings(_ on: Bool) {
        Events.setting("match-settings", from: Events.onOff(matchSettings), to: Events.onOff(on), by: "person")
        matchSettings = on
        settingChanges[Self.matchKey] = SettingSync.stamp(after: settingChanges[Self.matchKey])
        persistChanges()
    }

    func setShareClipboard(_ on: Bool) {
        Events.setting("clipboard", from: Events.onOff(shareClipboard), to: Events.onOff(on), by: "person")
        shareClipboard = on
        settingChanges[Self.clipboardKey] = SettingSync.stamp(after: settingChanges[Self.clipboardKey])
        persistChanges()
    }

    /// What the person ticked when pairing; ticked differently on the two Macs, off wins (`SettingSync.pairingStamp`).
    func choosePairSharing(match: Bool, clipboard: Bool) {
        if matchSettings != match { Events.setting("match-settings", from: Events.onOff(matchSettings), to: Events.onOff(match), by: "pairing") }
        if shareClipboard != clipboard { Events.setting("clipboard", from: Events.onOff(shareClipboard), to: Events.onOff(clipboard), by: "pairing") }
        matchSettings = match
        shareClipboard = clipboard
        settingChanges[Self.matchKey] = SettingSync.pairingStamp(on: match)
        settingChanges[Self.clipboardKey] = SettingSync.pairingStamp(on: clipboard)
        persistChanges()
    }

    /// Takes each of the other Mac's switches that was set there later; whether anything changed.
    func follow(_ theirs: LinkSharing) -> Bool {
        var took = false
        if let on = theirs.match, let at = theirs.matchChanged, SettingSync.takes(at, over: settingChanges[Self.matchKey]) {
            if matchSettings != on { Events.setting("match-settings", from: Events.onOff(matchSettings), to: Events.onOff(on), by: "other Mac") }
            matchSettings = on
            settingChanges[Self.matchKey] = at
            took = true
        }
        if let on = theirs.clipboard, let at = theirs.clipboardChanged, SettingSync.takes(at, over: settingChanges[Self.clipboardKey]) {
            if shareClipboard != on { Events.setting("clipboard", from: Events.onOff(shareClipboard), to: Events.onOff(on), by: "other Mac") }
            shareClipboard = on
            settingChanges[Self.clipboardKey] = at
            took = true
        }
        if took { persistChanges() }
        return took
    }

    /// After unpairing: both switches off and their times gone, so a Mac paired later starts from its own.
    func resetSharing() {
        matchSettings = false
        shareClipboard = false
        settingChanges[Self.matchKey] = nil
        settingChanges[Self.clipboardKey] = nil
        persistChanges()
    }

    private func noteChange(_ device: Device, _ suffix: (String) -> String) {
        guard let key = syncKey(device).map(suffix) else { return }
        settingChanges[key] = SettingSync.stamp(after: settingChanges[key])
        persistChanges()
    }

    /// Writes one of the state files; a failure is shown on the Diagnostics page, and what was set still applies.
    private func save<Value: Encodable>(_ value: Value, as file: String, failure: (String) -> String) {
        // A file that could not be read and is still in place keeps what is in it; the notice already says so.
        guard StateFiles.mayWrite(file) else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: stateURL.appendingPathComponent(file), options: .atomic)
        } catch {
            status = failure(error.localizedDescription)
        }
    }

    private func persistChanges() { save(settingChanges, as: "changes.json") { L("The rule applies until Halo quits, but couldn’t be saved: %@", $0) } }
    private func persistSpeeds() { save(policy.speeds, as: "speeds.json") { L("The rule applies until Halo quits, but couldn’t be saved: %@", $0) } }
    private func persistRules() { save(policy.rules, as: "rules.json") { L("The rule applies until Halo quits, but couldn’t be saved: %@", $0) } }

    /// Whether the device has scrolled with wheel steps since it connected.
    func sentWheel(_ device: Device) -> Bool { sightings[device.sourceKey(continuous: false)] != nil }

    func isReversed(_ device: Device) -> Bool {
        [false, true].contains { policy.rule(for: device, continuous: $0) == .reverse }
    }

    /// Connected pointing devices people would recognise, in `Device.listOrder`: local ones and those another Mac lends
    /// through Universal Control, as soon as they are lent, so a mouse can be set up here before its first scroll here.
    /// Lent services may disappear while input is on the other Mac. Other virtual
    /// ones only once they have scrolled or carry a rule, which keeps out Universal Control's helper "UC Automouse".
    var menuDevices: [Device] {
        var seen = Set<String>()
        let scrolled = Set(sightings.values.map(\.device.key))
        return configurationDevices.filter { device in
            device.listed(scrolled: scrolled.contains(device.key), ruled: isReversed(device))
                && seen.insert(device.key).inserted
        }
        .sorted(by: Device.listOrder(shown: AppDelegate.displayName))
    }

    /// The UC session, not the temporary list of devices it lends here. On systems whose connection event cannot be
    /// read, a currently present UC HID service is still positive evidence; an empty HID list proves nothing.
    var universalControlConnected: Bool {
        universalControl.connected ?? devices.values.contains { !$0.local && $0.name.hasPrefix("V-") }
    }

    /// Devices another Mac lends this one through Universal Control (`Device.lent`).
    var borrowedDevices: [Device] {
        var seen = Set<String>()
        return devices.values.filter { device in
            device.lent && seen.insert(device.key).inserted
        }
        .sorted(by: Device.listOrder(shown: AppDelegate.displayName))
    }

    /// Follows the Accessibility grant for as long as Halo runs. The system announces every change to the
    /// Accessibility list; the answer is asked for then, and again a moment later, as it can trail the announcement.
    /// Delivered at once although Halo is in the background (the person is in System Settings): by default a
    /// background app's distributed notifications wait until it is active.
    private func watchAccessibility() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = NotificationRelay(name: "com.apple.accessibility.api") { [weak self] in
            for delay in [0.3, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.accessibilityMaybeChanged() }
            }
        }
    }

    /// Starts listening once Accessibility is allowed, and lets go of the tap once it is taken away: the tap stays
    /// in place without the permission and sees nothing, while the menu would go on saying reversing is on. Asked on
    /// every Accessibility change, when Halo comes to the front, when the menu opens, on wake, and when the system
    /// disables the tap.
    func accessibilityMaybeChanged() {
        let was = trusted
        trusted = AXIsProcessTrusted()
        if trusted, tap == nil {
            start(prompt: false)
        } else if !trusted, tap != nil {
            // Logged as `paused`, with why, by the change it makes (`applyEnabled`); allowed again, it starts by itself.
            teardown()
        } else if trusted != was {
            // No tap to start or stop (it could not be made): the window still shows the permission as it is now.
            onListeningChanged?()
        }
    }

    func applyEnabled() {
        // No main switch: each device's own switch says whether it is reversed. Halo steps aside only while it cannot
        // listen.
        let active = tap != nil
        guard active != policy.enabled else { return }
        policy.enabled = active
        checkDirection()
        onActiveChanged?()
    }

    var stateText: String {
        if tap == nil {
            return trusted ? L("Not listening; scrolling is unchanged") : L("Needs Accessibility access: allow Halo in System Settings and it starts on its own")
        }
        if let blocked {
            let device = AppDelegate.displayName(blocked.device)
            return blocked.sole ? L("%2$@ changed the direction of %1$@ after it was reversed", device, blocked.tools[0].name)
                                : L("Another app changed the direction of %@ after it was reversed", device)
        }
        return L("Reversing is on; unrecognized devices are left as they are")
    }

    private func persistSettings() {
        save(["showIcon": showIcon, "matchSettings": matchSettings,
              "clipboard": shareClipboard, "showDock": showDock], as: "settings.json") { L("Couldn’t save settings: %@", $0) }
    }

    func start(prompt: Bool = true) {
        watchAccessibility()
        guard tap == nil else { return }
        guard HaloHID.available else {
            status = L("This version of macOS lacks the HID interface; not listening, scrolling unchanged")
            return
        }
        trusted = AXIsProcessTrusted()
        guard trusted else {
            if prompt {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Re-enable in place and keep the user's rules.
                    engine.resume()
                    return Unmanaged.passUnretained(event)
                }
                if type == .scrollWheel { engine.handle(event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: context) else {
            status = L("Couldn’t start listening; scrolling unchanged. Check Accessibility access.")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
        status = nil
        applyEnabled()
        onListeningChanged?()
    }

    /// Re-enables a tap the system disabled (timeout, sleep) without touching the enabled state.
    func resume() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        guard AXIsProcessTrusted() else {
            // Taken away: let go of the tap once this callback is over, not from inside it.
            DispatchQueue.main.async { [weak self] in self?.accessibilityMaybeChanged() }
            return
        }
        guard CFMachPortIsValid(tap) else {
            // An invalidated port cannot be re-enabled: recreate it; the switch is unchanged.
            teardown()
            start(prompt: false)
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Removes the tap without touching the user's switch, so a relaunch or reconnect restores it.
    func teardown() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        applyEnabled()
        onListeningChanged?()
    }

    func handle(_ event: CGEvent) {
        let sender = HaloHID.sender(of: event)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var device = devices[sender] ?? quick[sender]
        let now = ProcessInfo.processInfo.systemUptime
        // A tap comes and goes without any app launching (another tool switching itself off, or just allowed) and
        // nothing announces it. It matters only to scrolling, so the first scroll after a pause looks again, after
        // this event is on its way.
        if now - lastScroll > Self.scrollPause { DispatchQueue.main.async { [weak self] in self?.scanTools() } }
        lastScroll = now
        if device == nil, sender != 0, now - (unresolved[sender] ?? -.infinity) >= Engine.lookupRetry {
            // A Bluetooth device back from sleep or a Universal Control handoff brings a new sender. It is looked up
            // at once (microseconds) so its first scroll already follows its rule; the full listing follows.
            unresolved[sender] = now
            if let info = HaloHID.device(sender: sender) {
                device = Device(properties: info)
                quick[sender] = device
            }
            refresh()
        }
        let input = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        var changed = false
        let factor = policy.factor(device: device, continuous: continuous)
        if factor != 1 {
            changed = HaloHID.scaleVertical(event, by: factor) && factor < 0
        }
        total += 1
        if changed {
            reversed += 1
            if recheckOnReversedScroll, check == nil, blocked.map({ $0.device.sender == sender }) ?? true {
                recheckOnReversedScroll = false
                DispatchQueue.main.async { [weak self] in self?.checkDirection() }
            }
        }
        // A mouse first seen scrolling smoothly loses its wheel-speed row; the window shows that.
        if sources.observe(sender: sender, continuous: continuous) { DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?() } }
        guard recordScrolls else { return }
        let scroll = Scroll(time: now, wall: CFAbsoluteTimeGetCurrent(), sender: sender, continuous: continuous, input: input,
                            output: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                            phase: phase, momentum: momentum, reversed: changed, name: device?.name)
        if recent.count < Self.recentCapacity {
            recent.append(scroll)
        } else {
            recent[recentNext] = scroll
        }
        recentNext = (recentNext + 1) % Self.recentCapacity
    }

    /// The last `count` scrolls, oldest first.
    func recentScrolls(_ count: Int = recentCapacity) -> ArraySlice<Scroll> {
        let ordered = recent.count < Self.recentCapacity ? recent : Array(recent[recentNext...] + recent[..<recentNext])
        return ordered.suffix(count)
    }


}

/// A distributed notification delivered as it is posted, whether or not Halo is the active app, until released.
final class NotificationRelay: NSObject {
    private let action: () -> Void

    init(name: String, action: @escaping () -> Void) {
        self.action = action
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(fire), name: .init(name), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func fire() { DispatchQueue.main.async(execute: action) }
}
