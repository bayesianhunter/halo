// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import IOBluetooth
import HaloHID
import HaloCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Read once, before anything else starts.
    let firstLaunch = AppDelegate.isFirstLaunch()
    let engine = Engine()
    let updates = Updates()
    var window: NSWindow!
    /// The sheet that shows the pairing digits, while it is up.
    var compareSheet: NSAlert?
    var statusItem: NSStatusItem!
    /// The Diagnostics page's verdict, the button that fixes what it names, and the summary's copy button.
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let diagnosisButton = NSButton(title: "", target: nil, action: nil)
    let summaryButton = NSButton(title: "", target: nil, action: nil)
    var statusDot: StatusIcon.Dot?
    var dotObserver: NSObjectProtocol?
    /// Run only when an agent asks for it through `Halo --diagnostics --audio-check`.
    let audioCheck = AudioCheck()
    /// The link's recent events, for the diagnostics export only; nothing reads them otherwise.
    var linkEvents: [String] = []
    var wakeObserver: NSObjectProtocol?
    var closeObserver: NSObjectProtocol?
    /// The window refreshes on change, never on a timer: `settingsChanged` is called by whatever it shows. A change
    /// while it cannot be seen waits here until it can.
    var renderPending = false
    var renderQueued = false
    var windowObservers: [NSObjectProtocol] = []
    /// The one refresh due when text in the window changes with time alone; replaced on every refresh, never repeating.
    var timedRender: DispatchWorkItem?
    /// When the device rows next change with time alone, from the last refresh.
    var rowsChangeAt: Date?
    /// A device-list rebuild held off by a click waits for the button to come up; one held off by focus in the list
    /// waits for focus to move.
    var clickMonitors: [Any] = []
    var heldForFocus = false
    var focusObservation: NSKeyValueObservation?
    let menu = NSMenu()
    let classic = ClassicBluetooth()
    /// Open menu rows by lower-cased device name, so signals that arrive later update them in place.
    var rowInfo: [String: DeviceRowView] = [:]
    /// Ids two rows of the open menu share (two devices of one name): `rowInfo` holds only the last, so these are
    /// left as the menu opened.
    var sharedRowIDs: Set<String> = []
    let pages = NSTabView()
    let pagePicker = PillPicker(titles: [L("Devices"), L("General"), L("Diagnostics"), L("About")])
    let devicesStack = NSStackView()
    var devicesSignature = ""
    let loginSwitch = MenuSwitch(isOn: false)
    let iconSwitch = MenuSwitch(isOn: true)
    let matchSwitch = MenuSwitch(isOn: false)
    let clipSwitch = MenuSwitch(isOn: false)
    let dockSwitch = MenuSwitch(isOn: false)
    let clipDetail = NSTextField(labelWithString: "")
    var remoteSnapshotExpanded = false
    var scrollingHelpExpanded = false
    /// Findings already asked about this run.
    var promptedTools: Set<String> = []
    var pendingAlerts: [() -> Void] = []
    var quittingTools: Set<String> = []
    var alertOpen = false
    var menuOpen = false
    /// Installed only while the menu tracks; never a permanent global input monitor.
    var menuClickMonitors: [Any] = []
    /// Speaker rules turned off per device, and what the rules and alerts saw; see AudioRules.swift.
    var audioRules: [String: Bool] = [:]
    var lastMicRevert: [String: Date] = [:]
    /// Speakers the input could not be switched away from, logged once until a switch works.
    var micRevertFailed: Set<String> = []
    var revertRecheck: Set<String> = []
    var micNotified: Set<String> = []
    var audioEvents: [AudioEvent] = []
    /// Speaker and headphone levels as last logged; the daemon repeats them every few seconds.
    var audioBatteryLedger = BatteryLedger()
    /// The device whose reversed direction another program was last logged changing back.
    var loggedBlocked: String?
    var sleepObserver: NSObjectProtocol?
    /// Set while quitting, so the listener coming down is not logged as a pause after `quit`.
    var quitting = false
    /// Universal Control taking the pointer to the other Mac and back, for the event log. Its own registration, apart
    /// from the clipboard's: it wakes Halo only when the pointer crosses, whatever the clipboard switch says.
    let handoffWatch = PointerWatch()
    /// HID services as they come and go: the device list is refreshed at once, and a drop of what the other Mac
    /// lends goes to `stallWatch`.
    let serviceWatch = ServiceWatch()
    lazy var stallWatch = StallWatch(link: link, pointer: handoffWatch)
    var lastDiagnosticsExport = Date.distantPast
    /// A check an agent started through `Halo --diagnostics`, until its export is written.
    var agentRun: DiagnosticsExport.Run?
    let agentSkillButton = NSButton(title: "", target: nil, action: nil)
    let agentSkillDetail = NSTextField(labelWithString: "")
    let bluetoothLog = BluetoothLog()
    /// Consecutive link reports with heavy retransmission, and the bursts of them per device in the last ten minutes.
    var weakRun = 0
    var weakRunDevice: String?
    var weakBursts: [String: [Date]] = [:]
    var ringAt: [String: Date] = [:]
    var callStarted: [String: (at: Date, app: String?)] = [:]
    var lastCallQuality: Set<String> = []
    /// Battery levels speakers reported over their hands-free link, which the system does not show elsewhere.
    var reportedBattery: [String: (percent: Int, at: Date)] = [:]
    /// The latest alert per device, shown on its row for ten minutes; `trouble` marks one worth leading Diagnostics with.
    /// A later event for the same device, a disconnect included, replaces it.
    var deviceAlert: [String: (at: Date, text: String, trouble: Bool, device: String)] = [:]
    var bluetoothNotices: [IOBluetoothUserNotification] = []
    let launchedAt = Date()
    /// Redraws the menu-bar mark when a speaker's last battery report passes the hour after which it is not shown.
    var batteryAgeWork: DispatchWorkItem?
    let accessDetail = NSTextField(labelWithString: "")
    /// Opens the Accessibility pane; shown only while Halo is not yet allowed.
    let accessButton = NSButton(title: "", target: nil, action: nil)
    /// Sharing with one other Mac; kept apart from the engine, which it reaches only through the sharing switches.
    lazy var link = HaloLink(directory: stateURL, keychainService: "Halo")
    lazy var clipboard = ClipboardShare(link: link)
    lazy var audio = AudioRoutes()
    let linkDetail = NSTextField(labelWithString: "")
    let linkName = NSTextField(labelWithString: "")
    let linkButton = NSButton(title: "", target: nil, action: nil)
    /// The two sharing switches belong to a pairing: their rows show only while paired.
    var sharingGroup: ListGroup?
    var sharingRows: [NSView] = []
    /// What the person ticked in the Pair alert, applied once the pairing completes.
    var pairingChoice: (match: Bool, clipboard: Bool)?
    /// The Pair button on the Devices page, while it shows: keyboard focus on it does not hold that page's rebuild off.
    weak var pairCardButton: NSButton?
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The open-application event is only current here, not yet in applicationWillFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if engine.showDock { NSApp.setActivationPolicy(.regular) }
        // Started before the App menu is built, which shows "Check for Updates…" only if it did. Its first word comes
        // after an appcast fetch at the earliest, by which time the status item below exists.
        updates.start()
        // Only seen while Halo is in the Dock and in front: the usual keys for Settings, closing, quitting and editing.
        NSApp.mainMenu = mainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "\(Brand.name) \(version)"
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        updates.onChange = { [weak self] in
            self?.updateBatteryUI()
            self?.rebuildMenu()
        }
        link.snapshot = { [weak self] in self?.linkSnapshot() ?? LinkSnapshot(computer: "", active: false, devices: []) }
        link.onChange = { [weak self] in self?.linkChanged() }
        link.onUnpaired = { [weak self] in self?.pairingForgotten() }
        link.onPaired = { [weak self] in self?.paired() }
        link.log = { [weak self] line in self?.noteLinkEvent(line) }
        link.onClip = { [weak self] message in self?.clipboard.handle(message) }
        clipboard.log = { [weak self] line in self?.noteLinkEvent(line) }
        link.start()
        updateClipboard()
        buildWindow()
        watchWindow()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.timedRender?.cancel()
            self?.timedRender = nil
            // Out of the Dock again once the window has closed, unless the person keeps Halo there.
            DispatchQueue.main.async {
                guard let self, !self.engine.showDock, !self.window.isVisible else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        engine.onBatteriesChanged = { [weak self] in
            self?.updateBatteryUI()
            self?.link.snapshotChanged()
            self?.settingsChanged()
        }
        engine.onDevicesChanged = { [weak self] in
            // A device lent through Universal Control appears only once the pointer comes over, so a setting that
            // arrived earlier is taken now.
            self?.matchPeerSettings()
            self?.link.snapshotChanged()
            self?.settingsChanged()
        }
        engine.onStatusChanged = { [weak self] in self?.settingsChanged() }
        engine.onListeningChanged = { [weak self] in self?.settingsChanged() }
        engine.universalControl.onChange = { [weak self] in
            self?.engine.updateUniversalControlDevices()
            self?.settingsChanged()
        }
        engine.universalControl.start()
        // How long each battery lasts comes from the event log, read once in the background.
        BatteryHistory.shared.onChange = { [weak self] in self?.settingsChanged() }
        BatteryHistory.shared.load()
        handoffWatch.onLeave = { [weak self] in
            Events.record(EventRecord(kind: .handoff, event: "left"))
            self?.stallWatch.handedOver()
        }
        handoffWatch.onArrive = { [weak self] in
            Events.record(EventRecord(kind: .handoff, event: "arrived"))
            self?.stallWatch.arrived()
            self?.stallWatch.handedOver()
        }
        handoffWatch.start()
        stallWatch.anchor = { [weak self] in self?.statusItem.button?.window?.frame }
        stallWatch.anyLent = { [weak self] in self?.serviceWatch.anyLent ?? true }
        link.onHandoff = { [weak self] handoff in self?.stallWatch.received(handoff) }
        serviceWatch.onAdded = { [weak self] service in
            if service.lent { self?.stallWatch.lentServiceAdded() }
            self?.engine.refresh()
        }
        serviceWatch.onRemoved = { [weak self] service in
            if service.lent { self?.stallWatch.lentServiceRemoved() }
            self?.engine.refresh()
        }
        // Without the system's private callbacks, the engine keeps listing devices every minute instead.
        engine.devicesWatched = serviceWatch.start()
        loadAudio()
        startAudioWatch()
        listenForDiagnosticsRequests()
        // What already holds at launch: a speaker set as the microphone, or sound already playing.
        enforceAudioRules()
        audio.onChange = { [weak self] in
            guard let self else { return }
            self.enforceAudioRules()
            self.audioDisplayChanged()
        }
        engine.onToolsChanged = { [weak self] in self?.toolsChanged() }
        engine.onBlockedChanged = { [weak self] in self?.blockedChanged() }
        // A paused Halo shows a dimmed icon, as system menu extras do when their feature is off.
        engine.onActiveChanged = { [weak self] in
            guard let self else { return }
            self.notePaused()
            self.statusItem.button?.appearsDisabled = !self.engine.policy.enabled
            self.updateIconVisibility()
            self.link.snapshotChanged()
            self.settingsChanged()
        }
        statusItem.button?.appearsDisabled = !engine.policy.enabled
        updateIconVisibility()
        let ble = BLEBatteries()
        ble.onChange = { [weak self] in self?.engine.mergeBatteries() }
        engine.ble = ble
        engine.refreshBatteries()
        ble.onSignal = { [weak self] name, rssi in
            guard let self else { return }
            self.rowInfo[name.lowercased()]?.update(rssi: rssi)
            self.settingsChanged()
        }
        let center = NSWorkspace.shared.notificationCenter
        // Keep the tap across sleep; on wake only re-enable it if the system disabled it.
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in Events.app("sleep") }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Events.app("wake")
            self?.engine.universalControl.refresh()
            self?.engine.refresh()
            self?.engine.resume()
            self?.engine.accessibilityMaybeChanged()
            self?.engine.refreshBatteries()
        }
        // The system's own Accessibility question comes from the Allow button the window shows, not unasked at launch.
        engine.start(prompt: false)
        engine.scanTools()
        // Reversing at launch is logged as it starts; not reversing is logged here, with why.
        if !engine.policy.enabled { notePaused() }
        // Stay out of the way when the remembered switch already works; otherwise show what needs attention.
        // A hidden icon leaves no other sign that Halo started, unless it was the login item starting quietly.
        // The very first launch opens the device list once: nothing is reversed until the person turns it on, and a
        // new icon in a full menu bar (or behind the notch) is easy to miss.
        // Back from a language change: reopen where the person was, without passing through another page first.
        if CommandLine.arguments.contains("--general") {
            pagePicker.select(1)
            pickPage()
            showWindow()
        } else if firstLaunch || !engine.policy.enabled || (!engine.showIcon && !launchedAtLogin) {
            showWindow()
        }
        render()
        if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    // Into the temporary folder, not the source tree the binary was built from.
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Halo-window.png")
                    if let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
                        print(url.path)
                        NSApp.terminate(nil)
                        return
                    }
                }
                FileHandle.standardError.write(Data("Could not capture the window\n".utf8))
                exit(1)
            }
        }
    }

    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    /// True once per user account: the first launch, with no device rule saved. Someone updating from a version before
    /// this check who has turned a switch is not shown the window for it. A test run (`--smoke`, its own state folder)
    /// leaves the mark alone, so the person's real first launch still shows it.
    private static func isFirstLaunch() -> Bool {
        let key = "HaloLaunchedBefore"
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        if CommandLine.arguments.contains("--smoke") || ProcessInfo.processInfo.environment["HALO_STATE_DIR"] != nil { return false }
        UserDefaults.standard.set(true, forKey: key)
        return !FileManager.default.fileExists(atPath: stateURL.appendingPathComponent("rules.json").path)
    }

    /// Back from System Settings, perhaps having allowed Accessibility or taken it away.
    func applicationDidBecomeActive(_ notification: Notification) {
        engine.accessibilityMaybeChanged()
        engine.universalControl.refresh()
    }

    @objc func showWindow() {
        loginSwitch.setOn(SMAppService.mainApp.status == .enabled)
        // In the Dock and ⌘Tab while Settings is open, so it can be found again after switching away.
        let joiningDock = !engine.showDock && NSApp.activationPolicy() != .regular
        if joiningDock { NSApp.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Activating in the same turn as joining the Dock can leave the previous app's menus in the menu bar;
        // once more on the next turn gives Halo its own, so ⌘, ⌘W and ⌘Q work at once.
        if joiningDock { DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) } }
        render()
        // As when the menu opens: what has no notice of its own is looked at now, and shows as it comes back.
        engine.scanTools()
        engine.refreshBatteries()
        engine.ble?.readSignals()
    }

    /// A new language rebuilds every view, so Halo reopens itself in it, back on the General page.
    @objc func changeLanguage(_ sender: NSPopUpButton) {
        let chosen = Language.allCases[sender.indexOfSelectedItem]
        guard chosen != Language.current else { return }
        Language.current = chosen
        // The new copy starts only once this one has gone (10 s at most), so two never reverse at the same time;
        // if it cannot be started, this one stays.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "for i in $(seq 100); do /bin/kill -0 \"$1\" 2>/dev/null || break; sleep 0.1; done; /usr/bin/open -n \"$0\" --args --general",
                              Bundle.main.bundlePath, String(getpid())]
        do { try relaunch.run() } catch { return }
        NSApp.terminate(nil)
    }

    /// From the menu or the settings window; while the menu is open the icon waits for it to close.
    func setShowIcon(_ on: Bool) {
        engine.showIcon = on
        iconSwitch.setOn(on)
        updateIconVisibility()
    }

    /// A hidden icon comes back while a direction was found changed, a device runs low or an update waits,
    /// then leaves again.
    /// It never disappears from under its open menu.
    /// `batteries` saves a second Bluetooth query when the caller has just made one.
    func updateIconVisibility(batteries: [Battery]? = nil) {
        guard !menuOpen else { return }
        let attention = engine.blocked != nil
            || Battery.lowest(batteries ?? engine.batteries + audioBatteries()) != nil
            || updates.waiting != nil
        statusItem.isVisible = engine.showIcon || attention
    }

    @objc func start() { engine.teardown(); engine.start(); render() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkLink() { link.check() }
    /// Asks the system, which puts Halo in the Accessibility list (on a first run it is not there yet, and the pane
    /// alone would leave the person to find the app with "+"), and opens the pane too: macOS asks only once per app,
    /// so a second click would otherwise do nothing. Listening starts once allowed.
    @objc func permissions() {
        if engine.tap == nil, !AXIsProcessTrusted() { engine.start(prompt: true) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The open window; each part rebuilds only when what it shows changed.
    func render() {
        renderPending = false
        renderSettings()
        armTimedRender()
    }

    /// Something the window shows changed: refreshed once for a burst of changes while the window can be seen, else
    /// once it can be seen again.
    func settingsChanged() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else {
            renderPending = true
            return
        }
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderQueued = false
            self.render()
        }
    }

    /// Catches up when the window comes back into view, and looks again when it becomes key: the person may be back
    /// from System Settings, where clipboard access has no notice of its own.
    func watchWindow() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.window.occlusionState.contains(.visible) {
                if self.renderPending { self.settingsChanged() }
            } else if let work = self.timedRender {
                // Covered or minimised: text that ages is brought up to date when the window is seen again.
                work.cancel()
                self.timedRender = nil
                self.renderPending = true
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        })
        focusObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.heldForFocus else { return }
                self.heldForFocus = false
                self.settingsChanged()
            }
        }
    }

    /// Text that changes with time alone (a forecast, a reading's age, a notice that runs out) is refreshed when it
    /// does: one wall-clock deadline, only while the window can be seen.
    func armTimedRender() {
        timedRender?.cancel()
        timedRender = nil
        guard window.isVisible else { return }
        // Rendered while covered (an agent's change, say): what ages is caught up once it is seen.
        guard window.occlusionState.contains(.visible) else { renderPending = true; return }
        let now = Date()
        var dates = [rowsChangeAt]
        if let check = link.lastCheck, link.verdict == .tcpBlocked { dates.append(check.at.addingTimeInterval(1800)) }
        // "Last connected today, 15:03" turns into yesterday at midnight, and into a date the midnight after.
        let calendar = Calendar.current
        if !link.online, let seen = link.peer?.lastSeen, let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           seen >= calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now {
            dates.append(midnight)
        }
        dates += deviceAlert.values.map { $0.at.addingTimeInterval(600) }
        guard let next = dates.compactMap({ $0 }).filter({ $0 > now }).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.timedRender = nil
            self?.settingsChanged()
        }
        timedRender = work
        // Wall-clock, so time that passes in sleep counts; a moment past the deadline, so the text has changed.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }

    /// A rebuild held off while a mouse button is down: done once it comes up, in Halo or in another app. A control
    /// tracking the mouse (a slider being dragged) keeps the release from the monitors, so the end of that tracking
    /// is also waited for: work queued for the default run-loop mode runs only once tracking is over.
    func renderAfterClick() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            DispatchQueue.main.async { self?.clickReleased() }
            return event
        }) { clickMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.clickReleased() }) {
            clickMonitors.append(global)
        }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in self?.clickReleased() }
    }

    /// Once no button is down any more, the held rebuild happens and the monitors go.
    func clickReleased() {
        guard !clickMonitors.isEmpty, NSEvent.pressedMouseButtons == 0 else { return }
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        settingsChanged()
    }

    func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        let settings = NSMenuItem(title: L("%@ Settings…", Brand.name), action: #selector(showWindow), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: L("Quit %@", Brand.name), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        var appItems = [settings]
        if updates.available {
            let check = NSMenuItem(title: L("Check for Updates…"), action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updates
            appItems.append(check)
        }
        submenu(Brand.name, appItems + [.separator(), quit])
        submenu(L("Edit"), [NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                           NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                           NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                           NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")])
        submenu(L("Window"), [NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        return main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopMenuClickMonitors()
        Events.app("quit")
        eventLog.flush()
        bluetoothLog.stop()
        engine.universalControl.stop()
        audioCheck.stop(.cancelled)
        engine.teardown()
        link.stop()
    }
}

// MARK: The paired Mac

extension AppDelegate {
    /// What goes to the paired Mac: the rows as this menu shows them, without anything that could act on them.
    func linkSnapshot() -> LinkSnapshot {
        let rows = deviceRows()
        // A device borrowed through Universal Control belongs to the other Mac, which already lists it.
        // A remembered UC row keeps its origin even while its HID service is absent. Looking up only the live
        // borrowed devices would then advertise the remembered row as ours, echoing the peer's trackpad back to it.
        let devices = (rows.pointing + rows.others).filter { !$0.lent }.map { spec in
            LinkDevice(name: spec.title, kind: LinkDevice.Kind(symbol: spec.symbol), battery: spec.battery?.percent,
                       charging: spec.battery?.charging == true, reversed: spec.isOn == true, pointing: spec.isOn != nil, builtIn: spec.builtIn)
        }
        // One setting per device: a built-in trackpad lists several services. Sorted first, so the same state always
        // makes the same bytes and is not sent again.
        var seen = Set<String>()
        let settings = engine.devices.values.sorted { ($0.name, $0.key) < ($1.name, $1.key) }
            .compactMap { engine.setting(for: $0) }
            .filter { seen.insert(SettingSync.key(name: $0.name, builtIn: $0.builtIn, own: $0.own)).inserted }
        return LinkSnapshot(computer: link.computerName, active: engine.policy.enabled, devices: devices, settings: settings,
                            clipboard: clipboard.enabled, sharing: engine.sharing)
    }

    /// Takes the other Mac's sharing switches where they were set there after they were set here.
    func followPeerSharing() {
        guard let theirs = link.peer?.snapshot?.sharing, engine.follow(theirs) else { return }
        matchSwitch.setOn(engine.matchSettings)
        clipSwitch.setOn(engine.shareClipboard)
        updateClipboard()
        link.snapshotChanged()
    }

    /// A sharing switch was flipped here: the clipboard starts or stops, and the other Mac hears of it.
    func sharingChanged() {
        updateClipboard()
        link.snapshotChanged()
        renderLink()
        // The rows say where a device is reversed while the two Macs do not match settings.
        settingsChanged()
    }

    /// The clipboard follows only with this Mac's switch on.
    func updateClipboard() {
        let enabled = engine.shareClipboard
        guard clipboard.enabled != enabled else { return }
        clipboard.enabled = enabled
        link.snapshotChanged()
    }

    /// Takes the paired Mac's newer device settings, when this Mac is set to match them. The last snapshot is kept
    /// while the other Mac is offline, and its times keep an old setting from undoing a newer one made here.
    func matchPeerSettings() {
        guard engine.matchSettings, let snapshot = link.peer?.snapshot else { return }
        for (key, setting, _, _) in SettingSync.newer(snapshot.matchableSettings, than: engine.settingChanges) {
            guard let device = engine.devices.values.first(where: { engine.syncKey($0) == key }) else { continue }
            engine.take(setting, for: device)
        }
    }

    /// The paired Mac's devices as last reported, each with whether its tile is lit, and a note when it is paused,
    /// offline or has nothing connected. Nil until a snapshot has arrived.
    func remoteSection() -> (title: String, rows: [(RowSpec, Bool)], note: String?)? {
        Self.remoteSection(peer: link.peer, online: link.online)
    }

    static func remoteSection(peer: LinkPeer?, online: Bool) -> (title: String, rows: [(RowSpec, Bool)], note: String?)? {
        guard let peer, let remote = peer.snapshot else { return nil }
        let rows = remote.devices.enumerated().map { index, device -> (RowSpec, Bool) in
            let title = device.builtIn ? (device.kind == .trackpad ? L("Built-in Trackpad") : L("Built-in Keyboard")) : device.name
            // Offline, the section already says it is a snapshot; a row only notes that it was reversing.
            let spec = RowSpec(id: "#peer-\(index)", symbol: device.kind.symbol, title: title,
                               facts: device.reversed ? [online ? L("Reversing") : L("Was reversing at last connection")] : [],
                               battery: device.battery.map { Battery(name: title, serial: "", percent: $0, charging: device.charging) }, builtIn: device.builtIn)
            return (spec, online && remote.active && device.reversed)
        }
        var note: String?
        if !online {
            note = L("Offline")
        } else if !remote.active {
            note = L("Halo is paused on the other Mac")
        } else if remote.devices.isEmpty {
            note = L("No devices connected to the other Mac")
        }
        return (peer.name, rows, note)
    }

    func linkChanged() {
        stallWatch.linkChanged()
        followPeerSharing()
        matchPeerSettings()
        updateClipboard()
        renderLink()
        renderDiagnosis()
        settingsChanged()
    }

    /// Keeps the last 200 link events for the diagnostics export. Snapshot contents stay out of it; the pairing digits
    /// are never logged.
    func noteLinkEvent(_ line: String) {
        guard !line.hasPrefix("snapshot ") else { return }
        // A snapshot goes out on every battery or device change, and Bonjour reports the peer again and again
        // (hundreds of times a day); the event log keeps what happened to the link.
        if !line.hasPrefix("sent snapshot"), !line.hasPrefix("found peer ") {
            Events.record(EventRecord(kind: line.contains("clipboard") ? .clipboard : .link, text: line))
        }
        linkEvents.append(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime]) + " " + line)
        if linkEvents.count > 200 { linkEvents.removeFirst(linkEvents.count - 200) }
    }

    /// Logs whether Halo reverses now, and if not, why, in English for the log.
    func notePaused() {
        guard !quitting else { return }
        guard !engine.policy.enabled else { return Events.app("reversing") }
        // Reversing is off only while there is no tap.
        let reason = !HaloHID.available ? "this macOS lacks the HID functions Halo needs"
            : engine.trusted ? "not listening" : "no Accessibility permission"
        Events.app("paused", detail: reason)
    }
}
