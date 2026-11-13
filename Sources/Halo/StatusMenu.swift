// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import HaloHID

/// The status item's menu and icon.
extension AppDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // While a dialog waits for an answer (an update check's, say), AppKit greys out Settings and Quit. Behind other
        // apps' windows nothing says why, so bring the dialog forward, without activating Halo, which could close the
        // menu.
        NSApp.modalWindow?.orderFrontRegardless()
        engine.accessibilityMaybeChanged()
        engine.scanTools()
        engine.universalControl.refresh()
        // Universal Control comes and goes without a scroll; the next open shows what this refresh finds.
        engine.refresh()
        engine.checkDirection()
        engine.refreshBatteries()
        rebuildMenu(force: true)
        startMenuClickMonitors()
        engine.ble?.readSignals()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMenuClickMonitors()
        rowInfo = [:]
        sharedRowIDs = []
        menuOpen = false
        updateIconVisibility()
        showNextAlert()
    }

    /// Custom controls must not leave the status menu stranded when another app receives the click. Observe only
    /// while tracking, keep clicks inside the menu and its status item alone, and never swallow an outside click.
    private func startMenuClickMonitors() {
        stopMenuClickMonitors()
        guard menuOpen else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self, self.menuOpen else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.menu.cancelTracking(); return nil }
            } else { self.closeMenuIfOutside(event) }
            return event
        }) { menuClickMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.closeMenuIfOutside(event)
        }) { menuClickMonitors.append(global) }
    }

    private func closeMenuIfOutside(_ event: NSEvent) {
        guard menuOpen else { return }
        let windows = menu.items.compactMap { $0.view?.window }.filter(\.isVisible)
        guard !windows.isEmpty else { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        if windows.contains(where: { $0.frame.contains(point) }) { return }
        if let button = statusItem.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        menu.cancelTracking()
    }

    func stopMenuClickMonitors() {
        menuClickMonitors.forEach(NSEvent.removeMonitor)
        menuClickMonitors = []
    }

    /// One device row as both the menu and the settings window show it.
    struct RowSpec {
        let id: String
        var symbol: String
        var title: String
        var facts: [String] = []
        var battery: Battery?
        /// How long the battery lasts at its recent rate, and what that rests on. The window always shows it; the menu
        /// shows it on hover, and under the name too when `timeLeftSoon`.
        var timeLeft: (short: String, basis: String)?
        /// Under two weeks left, as the text says it: soon enough to plan a charge, so the menu says it unasked.
        var timeLeftSoon = false
        static let soonDays = 14
        var rssi: Int?
        var isOn: Bool?
        /// Part of this Mac, so not counted as a peripheral.
        var builtIn = false
        /// The pointing device the row is for; nil for other peripherals and the paired Mac's rows.
        var device: Device?
        /// Lent by another Mac through Universal Control (`Device.lent`).
        var lent: Bool { device?.lent == true }
        var onToggle: ((Bool) -> Void)?
        /// Lit without a switch: the speaker or headphones sound plays through.
        var lit = false
        /// What clicking the row does, for rows that do something; the menu highlights them.
        var onClick: (() -> Void)?
        /// The round microphone button of a speaker or headphones row.
        var mic: MicButton.Spec?
        /// The wheel speed, for mice; trackpads and other devices have none.
        var speed: Double?
        var onSpeed: ((Double) -> Void)?
        /// When what the row says next changes with time alone (a day fewer left, a reading a minute older, a notice
        /// running out), so an open window refreshes then, once.
        var changesAt: Date?

        mutating func changes(at date: Date?) {
            guard let date else { return }
            changesAt = min(changesAt ?? date, date)
        }

        mutating func show(_ forecast: BatteryForecast?) {
            timeLeft = forecast.map(BatteryHistory.text)
            switch forecast?.shown {
            case .days(let count)?: timeLeftSoon = count < Self.soonDays
            case .hours?, .almostEmpty?: timeLeftSoon = true
            case nil: timeLeftSoon = false
            }
            changes(at: forecast?.nextChange(after: Date()))
        }

        /// Changes whenever the row would look different, so the window rebuilds only then.
        var signature: String { "\(id)|\(device?.key ?? "")|\(title)|\(symbol)|\(facts)|\(timeLeft?.short ?? "")|\(battery?.percent ?? -1)\(battery?.charging == true ? "+" : "")|\(rssi.map { DeviceRowView.signalText($0) ?? "" } ?? "")|\(isOn.map(String.init) ?? "-")|\(speed ?? 0)|\(lit)|\(mic.map { "\($0.look)\($0.help)" } ?? "")" }
    }

    /// Pointing devices with their reverse switch, then other connected peripherals such as keyboards and speakers.
    func deviceRows() -> (pointing: [RowSpec], others: [RowSpec]) {
        let links = classic.connected()
        var usedAddresses = Set<String>(), usedBatteries = Set<String>(), listed = Set<String>()
        var pointing: [RowSpec] = [], others: [RowSpec] = []
        let selection = engine.selectionPolicy
        for device in engine.menuDevices {
            let link = links.first { !device.serial.isEmpty && $0.address == Address.normalize(device.serial) }
            if let link { usedAddresses.insert(link.address) }
            let battery = engine.battery(for: device)
            if let battery { usedBatteries.insert(battery.name) }
            listed.insert(device.name.lowercased())
            let builtIn = device.local && device.name.hasPrefix("Apple Internal")
            var spec = RowSpec(id: device.name.lowercased(), symbol: device.trackpad ? "rectangle.and.hand.point.up.left" : "computermouse.fill",
                               title: Self.displayName(device), facts: [],
                               battery: battery, rssi: link?.rssi ?? engine.ble?.signals[device.name],
                               isOn: [false, true].contains { selection.rule(for: device, continuous: $0) == .reverse }, builtIn: builtIn) { [weak self] on in
                self?.engine.setRule(on ? .reverse : .unchanged, for: device)
            }
            // Speed applies to wheel steps only. A mouse is offered it from the start, so the setting can be found before
            // the first scroll; only one seen scrolling smoothly and never in steps (a Magic Mouse) goes without.
            let smoothOnly = engine.sightings[device.sourceKey(continuous: true)] != nil && !engine.sentWheel(device)
            if !device.trackpad, !smoothOnly || selection.speed(for: device) != 1 {
                spec.speed = selection.speed(for: device)
                spec.onSpeed = { [weak self] speed in self?.engine.setSpeed(speed, for: device) }
            }
            spec.show(battery.flatMap { BatteryHistory.shared.forecast(Events.batteryLogIDs($0, among: engine.batteries)) })
            spec.device = device
            pointing.append(spec)
        }
        // Keyboards, speakers and headphones get no switch: they do not scroll. Each group is in name order, as the
        // pointing devices are within theirs (`Device.listOrder`).
        let byName = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        var lowEnergyInputs: Set<String>?
        for link in links.sorted(by: { byName($0.name, $1.name) })
            where !usedAddresses.contains(link.address) && !listed.contains(link.name.lowercased()) {
            let battery = engine.batteries.first { !link.address.isEmpty && Address.normalize($0.serial) == link.address }
                ?? engine.batteries.first { $0.name.caseInsensitiveCompare(link.name) == .orderedSame }
            // A phone or watch linked over Bluetooth Low Energy for Handoff is not a peripheral. The registry is asked
            // only for a link without a class or charge, and once. Matched by name, as `BLEBatteries` does: assumed,
            // not yet seen, that a renamed Bluetooth LE device keeps its name there.
            if link.major == 0, battery == nil, lowEnergyInputs == nil { lowEnergyInputs = Set(HaloHID.lowEnergyInputNames().map { $0.lowercased() }) }
            guard BluetoothClass.listedAlone(major: link.major, lowEnergyInput: lowEnergyInputs?.contains(link.name.lowercased()) ?? false,
                                             hasBattery: battery != nil) else { continue }
            if let battery { usedBatteries.insert(battery.name) }
            listed.insert(link.name.lowercased())
            var spec = RowSpec(id: link.name.lowercased(), symbol: link.symbol, title: link.name,
                               battery: battery ?? (link.audio ? audioBattery(link) : nil), rssi: link.rssi)
            if link.audio { describeAudio(&spec, device: link) }
            let logIDs = battery.map { Events.batteryLogIDs($0, among: engine.batteries) }
                ?? (link.audio ? [DiagnosticsReport.audioID(link.address, key: Events.idKey)] : nil)
            spec.show(spec.battery == nil ? nil : logIDs.flatMap { BatteryHistory.shared.forecast($0) })
            others.append(spec)
        }
        for battery in engine.batteries.sorted(by: { byName($0.name, $1.name) })
            where !usedBatteries.contains(battery.name) && !listed.contains(battery.name.lowercased()) {
            var spec = RowSpec(id: battery.name.lowercased(), symbol: "dot.radiowaves.left.and.right", title: battery.name,
                               battery: battery, rssi: engine.ble?.signals[battery.name])
            spec.show(BatteryHistory.shared.forecast(Events.batteryLogIDs(battery, among: engine.batteries)))
            others.append(spec)
        }
        return (pointing, others)
    }

    /// Menu, in the system Bluetooth menu's shape: Halo and what it is reversing, pointing devices with their own reverse switch,
    /// other connected peripherals, then settings.
    func rebuildMenu(force: Bool = false) {
        // Replacing custom views during AppKit's tracking can detach the window from the tracked items. Keep this
        // opening stable (controls update themselves); the next opening takes a fresh snapshot of all sections.
        guard force || !menuOpen else { return }
        menu.removeAllItems()
        rowInfo = [:]
        sharedRowIDs = []
        let groups = deviceGroups()
        let header = NSMenuItem()
        header.view = MenuHeaderView(title: Brand.name, status: scrollingSummary(groups.allPointing), state: headerState(groups.allPointing),
                                     version: "\(version) (\(build))", versionDetail: "· " + DiagnosticsExport.macOSVersion)
        menu.addItem(header)
        if engine.tap == nil, !engine.trusted {
            addRow(RowSpec(id: "#access", symbol: "hand.raised.fill", title: L("Allow Halo in System Settings…"),
                           facts: [L("Starts on its own once allowed")], onClick: { [weak self] in self?.permissions() }))
        }
        for (tool, kind) in conflictCards {
            let item = NSMenuItem()
            item.view = conflictView(tool, kind, inMenu: true)
            menu.addItem(item)
        }
        // Grouped by the Mac each device is attached to, each device once: this one, the paired one, then what
        // Universal Control lends from a Mac that is not paired. A switch is this Mac's, wherever its row sits.
        menu.addItem(.separator())
        // "This Mac" is only needed once another Mac is in the picture, paired or lending devices through Universal
        // Control; to everyone else the title would draw a distinction they have no reason to know. Otherwise just "Reverse".
        let otherMac = link.peer != nil || engine.universalControlConnected
        addHeader(otherMac ? link.computerName : "", identity: otherMac ? L("This Mac") : nil,
                  trailing: groups.minePointing.isEmpty ? nil : L("Reverse"))
        groups.mine.forEach(addRow)
        if groups.allPointing.isEmpty { addNote(L("No mouse or trackpad found yet")) }
        if let peer = link.peer {
            let lent = groups.peer?.rows.map(\.0).filter(\.lent) ?? []
            if !link.online {
                menu.addItem(.separator())
                let item = NSMenuItem()
                let view = DeviceRowView(symbol: "laptopcomputer", title: peer.name, facts: [], isOn: nil, accessory: L("Offline"))
                view.onClick = { [weak self] in self?.showPeerDevices() }
                item.view = view
                menu.addItem(item)
                // Universal Control can lend a device while Halo's link is down; its switch stays in reach.
                lent.forEach(addRow)
                // The last clipboard from it, to put back.
                addClipboardRows(peer: peer.name)
            } else if let remote = groups.peer {
                menu.addItem(.separator())
                addHeader(remote.title, trailing: L("Online"))
                for (spec, lit) in remote.rows {
                    if spec.lent { addRow(spec); continue }
                    // No switch: the other Mac's rules are only shown here, never changed.
                    let item = NSMenuItem()
                    item.view = DeviceRowView(symbol: spec.symbol, title: spec.title, facts: [], battery: spec.battery, isOn: nil, active: lit)
                    menu.addItem(item)
                }
                if let note = remote.note { addNote(note) }
                addClipboardRows(peer: remote.title)
            }
        }
        let showPairing = pairCardShown(universalControl: engine.universalControlConnected)
        if showPairing || !groups.universalControl.isEmpty {
            menu.addItem(.separator())
            addHeader(L("Universal Control"), trailing: groups.universalControl.isEmpty ? nil : L("Reverse"))
            if showPairing {
                let idle = link.pairing == .idle
                let title = idle ? L("Pair with Another Mac…") : L("Pairing…")
                let detail = idle ? L("Sync settings and clipboard") : pairCardContent().detail
                let item = NSMenuItem()
                item.target = self
                item.action = #selector(pairFromMenu)
                item.view = MenuPairingActionView(title: title, detail: detail,
                                                 buttonTitle: idle ? L("Pair…") : L("Pairing…"),
                                                 target: self, action: #selector(pairFromMenu))
                menu.addItem(item)
            }
            groups.universalControl.forEach(addRow)
        }
        menu.addItem(.separator())
        if let version = updates.waiting {
            let item = NSMenuItem(title: L("%@ %@ Available…", Brand.name, version), action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
            menu.addItem(item)
            item.target = updates
        }
        menu.addItem(withTitle: L("%@ Settings…", Brand.name), action: #selector(showWindow), keyEquivalent: ",")
        menu.addItem(withTitle: L("Quit %@", Brand.name), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
    }

    private func addHeader(_ title: String, identity: String? = nil, trailing: String? = nil) {
        let item = NSMenuItem()
        item.view = SectionHeading(name: title, identity: identity, trailing: trailing, inMenu: true)
        menu.addItem(item)
    }

    /// A line of text under a group, lined up with the device names rather than indented as a plain menu item would be.
    private func addNote(_ text: String) {
        let item = NSMenuItem()
        item.view = MenuNoteView(text: text)
        item.isEnabled = false
        menu.addItem(item)
    }

    /// The header's dot: orange when `menuNote` explains why nothing is reversed, green while something is.
    func headerState(_ pointing: [RowSpec]) -> MenuHeaderView.State {
        if menuNote != nil { return .attention }
        return engine.policy.enabled && pointing.contains { $0.isOn == true } ? .working : .idle
    }

    /// The local rules, not the cached peer snapshot, determine this status.
    func scrollingSummary(_ pointing: [RowSpec]) -> String {
        if let menuNote { return menuNote }
        let reversing = pointing.filter { $0.isOn == true }.map(\.title)
        return reversing.isEmpty ? L("No devices reversed") : L("Reversing %@", reversing.joined(separator: L("LIST_SEPARATOR")))
    }

    @objc func showPeerDevices() {
        pagePicker.select(0)
        pickPage()
        showWindow()
        if let page = pages.selectedTabViewItem?.view as? SettingsScrollView {
            page.scrollToBottom()
        }
    }

    /// A menu action must first give the existing pairing sheet a visible parent. If pairing or a sheet is already
    /// underway, bring that flow forward instead of starting it again or resetting the sharing choices.
    @objc func pairFromMenu() {
        menu.cancelTracking()
        pagePicker.select(0)
        pickPage()
        showWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.link.peer == nil, self.link.pairing == .idle, self.window.attachedSheet == nil else { return }
            self.pairLink()
        }
    }

    /// The devices by the Mac they are attached to, each listed once. A device the paired Mac lends through Universal
    /// Control goes under that Mac, in its place in that Mac's list, with this Mac's switch for it and the charge that
    /// Mac reports; one that cannot be told to come from it (nothing is paired, or the paired Mac does not report it,
    /// as for an iPad or a third Mac) goes under Universal Control.
    struct DeviceGroups {
        /// This Mac's own: its pointing devices, then its other peripherals.
        var mine: [RowSpec]
        var minePointing: [RowSpec]
        /// Lent here but not known to come from the paired Mac.
        var universalControl: [RowSpec]
        /// The paired Mac's section; a row is lit when that Mac is reversing it.
        var peer: (title: String, rows: [(RowSpec, Bool)], note: String?)?
        /// Every pointing device usable here, for the summary line.
        var allPointing: [RowSpec]
    }

    func deviceGroups() -> DeviceGroups {
        let rows = deviceRows()
        let minePointing = rows.pointing.filter { !$0.lent }
        var unplaced = rows.pointing.filter(\.lent)
        var peer: (title: String, rows: [(RowSpec, Bool)], note: String?)?
        if let snapshot = link.peer?.snapshot, let remote = remoteSection() {
            var merged = remote.rows
            let lent = unplaced
            let slots = snapshot.slots(ofLent: lent.compactMap(\.device))
            unplaced = []
            for (position, spec) in lent.enumerated() {
                guard let index = slots[position], merged.indices.contains(index) else { unplaced.append(spec); continue }
                let there = snapshot.devices[index]
                // Named and drawn as the lending Mac lists it; the switch, speed and id are this Mac's.
                var row = spec
                row.title = merged[index].0.title
                row.symbol = merged[index].0.symbol
                row.battery = row.battery ?? merged[index].0.battery
                // Only while the two Macs keep their own settings: matched, any difference is about to go away.
                if !engine.matchSettings, link.online, there.reversed != (spec.isOn == true) {
                    row.facts = [there.reversed ? L("Reversed on %@", remote.title) : L("Not reversed on %@", remote.title)]
                }
                merged[index] = (row, merged[index].1)
            }
            peer = (remote.title, merged, remote.note)
        }
        // Named as their rows are, so the summary line and a merged row never disagree.
        let placed = peer?.rows.map(\.0).filter(\.lent) ?? []
        return DeviceGroups(mine: minePointing + rows.others, minePointing: minePointing, universalControl: unplaced, peer: peer,
                            allPointing: minePointing + placed + unplaced)
    }

    /// In the paired Mac's group, one row: what last came over from it, a picture or the first line of text. Clicking
    /// it pulls the other Mac's clipboard as it is now, for when a copy did not follow; offline, it puts the last one
    /// back. Before anything came over it just offers to pull.
    private func addClipboardRows(peer: String) {
        guard clipboard.enabled else { return }
        let canPull = link.online && clipboard.peerClipboard == true
        let row: DeviceRowView
        if let received = clipboard.received {
            let age = Date().timeIntervalSince(received.at) < 60 ? L("Just now") : Language.current.dateText(received.at)
            let size = received.pixels.map { "\(Int($0.width))×\(Int($0.height))" }
            let title = received.concealed ? L("Password · Hidden") : received.text ?? (received.thumbnail != nil ? L("Image") : L("Clipboard"))
            // The click does one of two things, so the row says which: online it fetches what is there now,
            // offline it puts this one back.
            row = DeviceRowView(symbol: "doc.on.clipboard", title: title, facts: [size, age].compactMap { $0 }, isOn: nil,
                                accessory: canPull ? L("Get Latest") : nil, chevron: false, thumbnail: received.thumbnail)
            row.toolTip = canPull ? L("Click to get %@’s clipboard as it is now", peer) : L("Click to put it back on the clipboard")
        } else if canPull {
            row = DeviceRowView(symbol: "doc.on.clipboard", title: L("Get Clipboard from %@", peer), facts: [], isOn: nil)
        } else {
            return
        }
        row.onClick = { [weak self] in
            guard let self else { return }
            canPull ? self.clipboard.fetch() : self.clipboard.reuse()
        }
        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)
        if let problem = clipboard.problem { addNote(problem) }
    }

    private func addRow(_ spec: RowSpec) {
        let item = NSMenuItem()
        let view = rowView(spec)
        item.view = view
        menu.addItem(item)
        if rowInfo[spec.id] != nil { sharedRowIDs.insert(spec.id) }
        rowInfo[spec.id] = view
    }

    func rowView(_ spec: RowSpec) -> DeviceRowView {
        let view = DeviceRowView(symbol: spec.symbol, title: spec.title, facts: spec.facts + [Self.timeLeftFact(spec)].compactMap { $0 },
                                 battery: spec.battery, timeLeft: spec.timeLeft?.short, rssi: spec.rssi, isOn: spec.isOn,
                                 active: (spec.isOn == true && engine.policy.enabled) || spec.lit,
                                 dimmed: !engine.policy.enabled,
                                 toggleLabel: L("Reverse scrolling for %@", spec.title), mic: spec.mic)
        view.timeLeftFact = Self.timeLeftFact(spec)
        view.onToggle = spec.onToggle
        view.onClick = spec.onClick
        return view
    }

    /// The time left, on the detail line under the name, once it is soon.
    static func timeLeftFact(_ spec: RowSpec) -> String? {
        spec.timeLeftSoon ? spec.timeLeft?.short : nil
    }

    /// The rows of an open menu take new charges in place, since the menu is not rebuilt while open (`rebuildMenu`):
    /// a cable plugged in while looking shows at once, and so does what the opening's own battery read finds. Rows
    /// are found by id, which is the device's name; an id two rows shared at opening is left alone (`sharedRowIDs`).
    private func updateOpenRows() {
        guard menuOpen, !rowInfo.isEmpty else { return }
        let groups = deviceGroups()
        let lent = groups.peer?.rows.map(\.0).filter(\.lent) ?? []
        for spec in groups.mine + lent + groups.universalControl where !sharedRowIDs.contains(spec.id) {
            rowInfo[spec.id]?.update(battery: spec.battery, timeLeft: spec.timeLeft?.short, timeLeftFact: Self.timeLeftFact(spec))
        }
    }

    /// Why nothing is reversed right now, when that is the case.
    var menuNote: String? {
        if engine.tap == nil { return engine.trusted ? L("Not listening") : L("Needs Accessibility access") }
        if let blocked = engine.blocked { return L("Another app changed the direction of %@", Self.displayName(blocked.device)) }
        return nil
    }

    /// The name the person gave the device in Bluetooth settings, as the system Bluetooth menu shows it, so two
    /// keyboards stay told apart. Only built-in devices, which have no such name, and the "V-" Universal Control puts
    /// before a device it mirrors from another Mac are rewritten. A built-in device is named by its kind wherever it
    /// sits, so the other Mac's trackpad has the same name here, in its own list and in the Universal Control row.
    static func displayName(_ device: Device) -> String {
        let lent = !device.local && device.name.hasPrefix("V-")
        let name = lent ? String(device.name.dropFirst(2)) : device.name
        guard name.hasPrefix("Apple Internal"), device.local || lent else { return name }
        return device.trackpad ? L("Built-in Trackpad") : L("Built-in Keyboard")
    }

    /// Where a device sits and what kind it is, for the diagnostics table and the probe output.
    static func category(_ device: Device) -> String {
        switch (device.local, device.trackpad) {
        case (true, true): return L("Local trackpad")
        case (true, false): return L("Local pointing device")
        case (false, true): return L("Virtual/remote trackpad")
        case (false, false): return L("Virtual/remote pointing device")
        }
    }

    /// A low or charging device turns the ring into its charge; otherwise the plain mark.
    func updateBatteryUI(gone: String? = nil) {
        // The arc says how much charge. A device running low keeps the mark in the menu bar's own colour and turns only
        // the dot red: something to see to. A charging one colours the whole mark by its charge: something under way.
        // No number: the menu has it.
        updateOpenRows()
        let batteries = engine.batteries + audioBatteries(gone: gone)
        let button = statusItem.button
        button?.title = ""
        button?.imagePosition = .imageOnly
        if let charging = Battery.charging(batteries) {
            showDot(nil)
            button?.image = StatusIcon.make(level: Double(charging.percent) / 100, tint: StatusIcon.color(charging: charging.percent))
            button?.toolTip = L("%@ is charging, %ld%%", charging.name, charging.percent)
        } else if let low = Battery.lowest(batteries) {
            button?.image = StatusIcon.make(level: Double(low.percent) / 100, dot: false)
            button?.toolTip = L("%@: %ld%% battery", low.name, low.percent)
            showDot(.systemRed)
        } else if let waiting = updates.waiting {
            // An update found in the background: the dot in the accent colour until the person looks at it.
            button?.image = StatusIcon.make(dot: false)
            button?.toolTip = L("%@ %@ Available", Brand.name, waiting)
            showDot(.controlAccentColor)
        } else {
            showDot(nil)
            button?.image = StatusIcon.make()
            button?.toolTip = "\(Brand.name) \(version)"
        }
        updateIconVisibility(batteries: batteries)
    }

    /// Colours the mark's dot, or with nil leaves the dot to the template image again.
    private func showDot(_ color: NSColor?) {
        guard let button = statusItem.button else { return }
        guard let color else {
            statusDot?.removeFromSuperlayer()
            statusDot = nil
            return
        }
        button.wantsLayer = true
        if statusDot == nil {
            let dot = StatusIcon.Dot()
            button.layer?.addSublayer(dot)
            statusDot = dot
            // The image moves when the percentage beside it appears or changes; the dot moves with it.
            button.postsFrameChangedNotifications = true
            dotObserver = dotObserver ?? NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                                                                queue: .main) { [weak self] _ in self?.placeDot() }
        }
        statusDot?.fillColor = color.cgColor
        // Placed once the button has laid out its new image and title.
        DispatchQueue.main.async { [weak self] in self?.placeDot() }
    }

    private func placeDot() {
        guard let button = statusItem.button, let dot = statusDot else { return }
        button.layoutSubtreeIfNeeded()
        let rect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.place(in: rect, flipped: button.isFlipped)
        CATransaction.commit()
    }
}
