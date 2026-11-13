// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import IOBluetooth

/// A connected classic Bluetooth device as the menu shows it.
struct ClassicDevice {
    let name: String
    /// Lower-case, colon-separated, to match HID SerialNumber values such as "aa:bb:cc:dd:ee:01".
    let address: String
    let symbol: String
    let rssi: Int?
    /// A speaker or headphones: something sound can be sent to.
    var audio = false
    /// For audio devices: a speaker plays music only; headphones are a microphone too.
    var speaker = false
    /// Charge the system keeps for some audio devices (AirPods and Beats: left, right, case), by part.
    var levels: [String: Int] = [:]
    /// The major class of its class of device (`BluetoothClass`); none (0) for one connected over Bluetooth Low Energy.
    var major: UInt32 = 0
}

enum Address {
    static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: ":").lowercased()
    }
}

/// Connected classic Bluetooth devices (keyboard, trackpad, speakers) and their link signal.
final class ClassicBluetooth {
    /// Phones and computers keep a Bluetooth link for Handoff and hotspot, and offer a battery service too; the
    /// system's Bluetooth list knows them by class, and they are not peripherals.
    static func isPeripheral(_ device: IOBluetoothDevice) -> Bool {
        ![BluetoothClass.phone, BluetoothClass.computer].contains(device.deviceClassMajor)
    }

    /// Reads the current signal of each connected device; the controller answers locally, without radio traffic.
    func connected() -> [ClassicDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.filter { $0.isConnected() && Self.isPeripheral($0) }.map { device in
            let raw = Int(device.rawRSSI())
            let symbol = Self.symbol(of: device)
            return ClassicDevice(name: device.name ?? L("Bluetooth Device"), address: Address.normalize(device.addressString ?? ""),
                                 symbol: symbol, rssi: raw == 127 || raw == 0 ? nil : raw,
                                 audio: device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio),
                                 speaker: symbol == "hifispeaker.fill", levels: Self.levels(of: device), major: device.deviceClassMajor)
        }
    }

    /// The per-part charge IOBluetooth keeps for Apple and Beats headphones; not public API, so read only where the
    /// device answers to it, and a zero means not reported.
    static func levels(of device: IOBluetoothDevice) -> [String: Int] {
        guard device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) else { return [:] }
        var levels: [String: Int] = [:]
        for (key, part) in [("batteryPercentSingle", "single"), ("batteryPercentLeft", "left"), ("batteryPercentRight", "right"),
                            ("batteryPercentCase", "case")] where device.responds(to: NSSelectorFromString(key)) {
            if let value = device.value(forKey: key) as? Int, (1...100).contains(value) { levels[part] = value }
        }
        return levels
    }

    static func symbol(of device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) {
            // The device's own class says speaker or headphones, as the system's Bluetooth details do.
            switch device.deviceClassMinor {
            case UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker), UInt32(kBluetoothDeviceClassMinorAudioPortable),
                 UInt32(kBluetoothDeviceClassMinorAudioHiFi): return "hifispeaker.fill"
            case UInt32(kBluetoothDeviceClassMinorAudioHeadphones), UInt32(kBluetoothDeviceClassMinorAudioHeadset),
                 UInt32(kBluetoothDeviceClassMinorAudioHandsFree): return "headphones"
            // Anything else (uncategorised, car, microphone) counts as headphones: a speaker gets the microphone
            // rule by default, and a headset mistaken for one would have its microphone switched away every time.
            default: return "headphones"
            }
        }
        if name.contains("keyboard") || name.contains("键盘") { return "keyboard.fill" }
        if name.contains("trackpad") || name.contains("触控板") { return "rectangle.and.hand.point.up.left" }
        if name.contains("mouse") || name.contains("鼠标") { return "computermouse.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

/// One menu row, shaped like the system Bluetooth menu: a round glyph tile, lit in the accent colour while the device
/// is being reversed; the name, with a detail line only when there is something to say; then on the right the
/// signal bars, the charge as a percentage and battery glyph, and for pointing devices a switch.
/// Without a symbol it is the title row: the app icon, the name in bold and what is being reversed.
final class DeviceRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bars = NSImageView()
    private let charge = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let trailing = NSStackView()
    private var plug: PlugView?
    private var tile: RoundTile?
    let toggle: MenuSwitch?
    var onToggle: ((Bool) -> Void)?

    /// `timeLeft` is shown on hover over the name and the charge, and is part of what VoiceOver reads.
    init(symbol: String, title text: String, facts: [String], battery: Battery? = nil, timeLeft: String? = nil, rssi: Int? = nil,
         isOn: Bool?, active: Bool = false, dimmed: Bool = false, toggleLabel: String? = nil,
         accessory: String? = nil, chevron: Bool = true, mic: MicButton.Spec? = nil, thumbnail: NSImage? = nil) {
        toggle = isOn.map(MenuSwitch.init(isOn:))
        let micButton = mic.map(MicButton.init)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        title.stringValue = text
        title.font = .menuFont(ofSize: 13)
        // Cut in the middle: the owner at the start and the model at the end are what tell two devices apart.
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.stringValue = facts.joined(separator: " · ")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = facts.isEmpty
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        bars.contentTintColor = .secondaryLabelColor
        // Right side, as in the system menu: charge as "62%" then the battery glyph, red when low and not charging.
        charge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        glyph.setAccessibilityElement(false)
        [bars, charge, glyph].forEach(trailing.addArrangedSubview)
        trailing.spacing = 6
        trailing.setCustomSpacing(0, after: glyph)
        show(battery, timeLeft: timeLeft)
        if let accessory {
            let status = NSTextField(labelWithString: accessory)
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.addArrangedSubview(status)
            // A chevron where the row opens a page; plain text where it acts in place.
            if chevron {
                let mark = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
                mark.contentTintColor = .secondaryLabelColor
                mark.symbolConfiguration = .init(pointSize: 10, weight: .medium)
                trailing.addArrangedSubview(mark)
            }
        }

        var views: [NSView] = [labels, trailing]
        let leading: NSView
        if let thumbnail {
            // A picture in the tile's place, cornered rather than round so it reads as the image itself.
            let picture = NSImageView(image: thumbnail)
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.wantsLayer = true
            picture.layer?.cornerRadius = 4
            picture.layer?.masksToBounds = true
            picture.setAccessibilityElement(false)
            picture.widthAnchor.constraint(equalToConstant: RoundTile.side).isActive = true
            picture.heightAnchor.constraint(equalToConstant: RoundTile.side).isActive = true
            leading = picture
        } else {
            let tile = RoundTile(symbol: symbol, lit: active)
            self.tile = tile
            leading = tile
        }
        views.append(leading)
        if let micButton {
            views.append(micButton)
            // An open menu is not rebuilt (`rebuildMenu`), so the row's words follow the button at once.
            micButton.onFlip = { [weak self] look in
                guard let self else { return }
                var shown = self.facts.filter { !MicButton.ruleFacts.union(MicButton.inputFacts).contains($0) }
                shown.append(contentsOf: MicButton.facts(look, stuck: micButton.stuck))
                self.facts = shown
                self.detail.stringValue = shown.joined(separator: " · ")
                self.detail.isHidden = shown.isEmpty
                self.accessibilityBase = self.spokenBase(shown)
                self.update(rssi: self.rssi)
            }
        }
        if let toggle {
            // The tile follows the switch at once, without waiting for the menu to be rebuilt.
            toggle.onChange = { [weak self] on in
                self?.tile?.lit = on && !dimmed
                self?.onToggle?(on)
            }
            toggle.setAccessibilityLabel(toggleLabel ?? text)
            toggle.alphaValue = dimmed ? 0.45 : 1
            views.append(toggle)
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.menuLead),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: Layout.menuTileGap),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Layout.gap),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
        if let toggle {
            constraints += [toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.menuEdge),
                            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
                            trailing.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -Layout.gap)]
        } else if let micButton {
            // In the switch column, centred on it, so it lines up with the reverse switches above.
            constraints += [micButton.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.switchCentre),
                            micButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.beforeSwitch)]
        } else {
            // Rows without a switch keep their charge in the same column as rows with one.
            constraints.append(trailing.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                                   constant: accessory == nil ? -Layout.beforeSwitch : -Layout.menuEdge))
        }
        NSLayoutConstraint.activate(constraints)
        // Wide enough for the full Bluetooth name, up to a limit past which the name is cut in the middle; the menu
        // takes its widest row and stretches the others to match. Signal bars may arrive after the menu opens, when
        // the width is already fixed, so every device row is measured without them and given a fixed slot for them.
        autoresizingMask = [.width]
        bars.isHidden = true
        let leadingWidth = Layout.menuTextLead
        let barsSlot = Self.barsWidth + trailing.spacing
        let needed = leadingWidth + max(title.intrinsicContentSize.width, detail.isHidden ? 0 : detail.intrinsicContentSize.width)
            + Layout.gap + trailing.fittingSize.width + barsSlot + Layout.beforeSwitch
        frame.size.width = min(Self.maxWidth, max(320, ceil(needed)))
        // One element for VoiceOver: the row reads as a whole, and its switch is the only thing inside it.
        for part in [title, detail, charge, bars] as [NSView] { part.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        self.facts = facts
        spokenBase = { [unowned self] facts in
            Self.spoken([text] + facts + [facts.contains { $0 == self.timeLeft } ? nil : self.timeLeft, accessory], battery: self.battery)
        }
        accessibilityBase = spokenBase(facts)
        update(rssi: rssi)
    }

    /// The charge and how long it lasts, with a plug in the battery's terminal while charging.
    private func show(_ battery: Battery?, timeLeft: String?) {
        self.battery = battery
        self.timeLeft = timeLeft
        if let battery {
            let color: NSColor = battery.needsCharge ? .systemRed : .secondaryLabelColor
            charge.stringValue = "\(battery.percent)%"
            charge.textColor = color
            glyph.image = NSImage(systemSymbolName: Self.batterySymbol(battery.percent), accessibilityDescription: nil)
            glyph.contentTintColor = battery.charging ? .systemGreen : color
        }
        charge.isHidden = battery == nil
        glyph.isHidden = battery == nil
        charge.toolTip = timeLeft
        glyph.toolTip = timeLeft
        // Not on the row itself: its tooltip would also be its accessibility help, read after the label that says it.
        title.toolTip = [title.stringValue, timeLeft].compactMap { $0 }.joined(separator: "\n")
        // Charging: a plug in the battery's terminal, with the charge trickling in along its cable.
        if let plug, battery?.charging != true || plug.connector != battery?.connector {
            trailing.removeArrangedSubview(plug)
            plug.removeFromSuperview()
            self.plug = nil
        }
        if plug == nil, let battery, battery.charging, let index = trailing.arrangedSubviews.firstIndex(of: glyph) {
            let plug = PlugView(connector: battery.connector)
            trailing.insertArrangedSubview(plug, at: index + 1)
            self.plug = plug
        }
    }

    /// The time left as the detail line shows it, when it is soon (`RowSpec.timeLeftSoon`); the row's other facts
    /// stay as the menu opened with them.
    var timeLeftFact: String?

    /// An open menu is not rebuilt (`rebuildMenu`), so a row takes a new charge in place: a cable plugged in while
    /// the menu is open shows its plug at once. Only the charge and the time left change; the rest of the row stays
    /// as it opened, as the menu always has.
    func update(battery: Battery?, timeLeft: String?, timeLeftFact newFact: String?) {
        guard battery != self.battery || timeLeft != self.timeLeft || newFact != timeLeftFact else { return }
        show(battery, timeLeft: timeLeft)
        let shown = facts.filter { $0 != timeLeftFact } + [newFact].compactMap { $0 }
        timeLeftFact = newFact
        facts = shown
        detail.stringValue = shown.joined(separator: " · ")
        detail.isHidden = shown.isEmpty
        accessibilityBase = spokenBase(shown)
        update(rssi: rssi)
    }

    private var accessibilityBase = ""
    private var facts: [String] = []
    private var rssi: Int?
    private var battery: Battery?
    private var timeLeft: String?
    private var spokenBase: ([String]) -> String = { _ in "" }

    /// How VoiceOver reads a device row, in the menu and in the window alike: name, facts, then the charge.
    static func spoken(_ parts: [String?], battery: Battery?, rssi: Int? = nil) -> String {
        (parts + [battery.map { L("Battery %ld%%", $0.percent) }, battery?.charging == true ? L("Charging") : nil, signalText(rssi)])
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: L("CLAUSE_SEPARATOR"))
    }
    /// Makes the whole row a button, highlighted under the pointer as menu items are; clicking it closes the menu.
    var onClick: (() -> Void)? {
        didSet {
            setAccessibilityRole(onClick == nil ? .group : .button)
            updateTrackingAreas()
        }
    }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onClick != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        hovered = false
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    /// The cellularbars glyph's width at menu size, reserved on every device row.
    private static let barsWidth: CGFloat = 20

    required init?(coder: NSCoder) { nil }

    func update(rssi: Int?) {
        self.rssi = rssi
        setAccessibilityLabel(Self.spoken([accessibilityBase], battery: nil, rssi: rssi))
        if let rssi {
            let signal = L("Signal %ld dBm", rssi)
            bars.image = NSImage(systemSymbolName: "cellularbars", variableValue: Self.strength(rssi), accessibilityDescription: signal)
            bars.toolTip = signal
            bars.isHidden = false
        } else {
            bars.isHidden = true
        }
    }

    /// Past this the menu stops growing and long names are cut in the middle instead.
    static let maxWidth: CGFloat = 440

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// A rounded track filled to the charge: the label colour normally, red when low and not charging. Drawn when shown,
    /// so it follows light and dark.
    static func chargeBar(_ battery: Battery, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: 4)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            (battery.needsCharge ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.75)).setFill()
            let filled = NSRect(x: 0, y: 0, width: max(size.height, rect.width * CGFloat(battery.percent) / 100), height: rect.height)
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.accessibilityDescription = L("Battery %ld%%", battery.percent)
        return image
    }

    /// Bars by received signal: -55 dBm or better is full, -85 dBm or worse is one bar.
    static func strength(_ rssi: Int) -> Double {
        min(1, max(0.25, Double(rssi + 95) / 40))
    }

    static func signalText(_ rssi: Int?) -> String? {
        guard let rssi else { return nil }
        return rssi >= -60 ? L("Strong signal") : rssi >= -75 ? L("Fair signal") : L("Weak signal")
    }
}

/// A charging plug seen from the side, pushed into the battery glyph's terminal on its left: the plug's tip (a thin
/// blade for Lightning, a rounded one for USB-C), its housing, then the cable, along which small green beads drift
/// into the device for a moment when the row appears, then rest: nothing keeps moving.
final class PlugView: NSView {
    static let size = NSSize(width: 26, height: 14)
    private let body = CAShapeLayer()
    private let cable = CAShapeLayer()
    private let current = CAShapeLayer()
    let connector: Battery.Connector?

    init(connector: Battery.Connector?) {
        self.connector = connector
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        setAccessibilityElement(false)
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        let mid = Self.size.height / 2
        let shape = CGMutablePath()
        switch connector {
        case .lightning?:
            shape.addRoundedRect(in: CGRect(x: 0, y: mid - 1.4, width: 6, height: 2.8), cornerWidth: 0.6, cornerHeight: 0.6)
        default:
            shape.addRoundedRect(in: CGRect(x: 0, y: mid - 2.1, width: 6, height: 4.2), cornerWidth: 2.1, cornerHeight: 2.1)
        }
        shape.addRoundedRect(in: CGRect(x: 6, y: mid - 3.5, width: 6, height: 7), cornerWidth: 1.6, cornerHeight: 1.6)
        body.path = shape
        let line = CGMutablePath()
        line.move(to: CGPoint(x: Self.size.width, y: mid))
        line.addLine(to: CGPoint(x: 12, y: mid))
        cable.path = line
        cable.lineWidth = 1.5
        cable.lineCap = .round
        current.path = line
        current.lineWidth = 1.5
        current.lineCap = .round
        current.lineDashPattern = [0.1, 4]
        for layer in [cable, body, current] { layer.fillColor = nil; self.layer?.addSublayer(layer) }
    }

    required init?(coder: NSCoder) { nil }

    /// The beads drift once the row is in an open menu or window, so the moment is not spent before anyone sees it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, current.animation(forKey: "flow") == nil else { return }
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = 0
        flow.toValue = -4.1
        flow.duration = 0.6
        flow.repeatCount = 4
        current.add(flow, forKey: "flow")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            body.fillColor = NSColor.secondaryLabelColor.cgColor
            cable.strokeColor = NSColor.tertiaryLabelColor.cgColor
            current.strokeColor = NSColor.systemGreen.cgColor
        }
        current.lineWidth = 2.4
    }
}

/// A line of quiet text in the menu (nothing found yet, the other Mac paused, a clipboard problem), starting where
/// device names start rather than indented as a plain menu item would be.
final class MenuNoteView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.menuTextLead),
                                     label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.menuEdge),
                                     label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        frame.size.width = min(DeviceRowView.maxWidth, ceil(Layout.menuTextLead + label.intrinsicContentSize.width + Layout.menuEdge))
    }

    required init?(coder: NSCoder) { nil }
}

/// The round tile behind a device glyph, as in the system Bluetooth menu: lit in the accent colour with a white
/// glyph while the device is being reversed, a faint grey otherwise.
final class RoundTile: NSView {
    static let side: CGFloat = 26
    private let glyph: NSImageView
    var lit: Bool {
        didSet {
            glyph.contentTintColor = lit ? .white : .labelColor
            needsDisplay = true
        }
    }

    init(symbol: String, lit: Bool) {
        self.lit = lit
        glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        glyph.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        glyph.contentTintColor = lit ? .white : .labelColor
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: centerXAnchor), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Self.side / 2
        layer?.backgroundColor = (lit ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(isDark ? 0.14 : 0.08)).cgColor
    }
}

/// The round microphone button on a speaker row. Its glyph says whether the speaker's microphone gets used: crossed
/// out while Halo keeps the system microphone off it, plain while it may be used, orange while an app records from it
/// on its own choosing, which Halo cannot change (then it does nothing when clicked). Otherwise clicking turns the
/// speaker's rule on or off; it is not a switch, since the switch column means reverse scrolling.
final class MicButton: NSButton {
    struct Spec {
        enum Look { case kept, used, warning }
        var look: Look
        var help: String
        /// Turns the speaker's rule on (keep the microphone off it) or off.
        var toggle: ((Bool) -> Void)?
        /// The speaker is the system microphone with nothing else to switch to, so it stays one whatever the rule.
        var stuck = false

        static func kept(_ toggle: @escaping (Bool) -> Void, stuck: Bool) -> Spec {
            Spec(look: .kept, help: MicButton.help(.kept, stuck: stuck), toggle: toggle, stuck: stuck)
        }
        static func used(_ toggle: @escaping (Bool) -> Void, stuck: Bool) -> Spec {
            Spec(look: .used, help: MicButton.help(.used, stuck: stuck), toggle: toggle, stuck: stuck)
        }
    }

    static func help(_ look: Spec.Look, stuck: Bool) -> String {
        switch (look, stuck) {
        case (.kept, true): L("Music only is on, but there is no other microphone to switch to. Click to turn off")
        case (.kept, false): L("Music only: the system microphone never uses this speaker. Click to turn off")
        default: L("The system may use it as a microphone, which drops it to call quality. Click to keep it for music only")
        }
    }

    /// What the row says about the rule after a click, as a rebuilt row would.
    static func facts(_ look: Spec.Look, stuck: Bool) -> [String] {
        switch (look, stuck) {
        case (.kept, true): [L("Also the system microphone · No other microphone to switch to")]
        case (.kept, false): [L("Music only")]
        case (_, true): [L("Also the system microphone")]
        default: []
        }
    }

    /// The facts a speaker row shows for its rule, which a click changes in place.
    static var ruleFacts: Set<String> { [L("Music only"), L("Also the system microphone · No other microphone to switch to")] }

    var stuck: Bool { spec.stuck }

    /// The facts that say the speaker is the system microphone right now.
    static var inputFacts: Set<String> { [L("Also the system microphone"), L("Also the system microphone · Call quality")] }

    /// After a click, with the look the button now shows.
    var onFlip: ((Spec.Look) -> Void)?

    static let side: CGFloat = 24
    private var spec: Spec

    init(_ spec: Spec) {
        self.spec = spec
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        title = ""
        wantsLayer = true
        symbolConfiguration = .init(pointSize: 11, weight: .medium)
        imagePosition = .imageOnly
        show()
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks are taken here, as `MenuSwitch` takes them: inside an open menu, NSButton's own mouse tracking never sees
    /// the mouse-up, so its action would not fire. The action stays for the keyboard and VoiceOver.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        clicked()
    }

    private func show() {
        image = NSImage(systemSymbolName: spec.look == .kept ? "mic.slash" : "mic.fill", accessibilityDescription: spec.help)
        contentTintColor = spec.look == .warning ? .white : .labelColor
        toolTip = spec.help
        setAccessibilityLabel(spec.help)
        needsDisplay = true
    }

    /// An open menu keeps its snapshot (`rebuildMenu`), so the button flips its own look, as `MenuSwitch` does, and
    /// a second click in the same opening turns the rule back. The rule changes after the click has finished.
    @objc private func clicked() {
        guard let toggle = spec.toggle else { return }
        let keep = spec.look != .kept
        spec.look = keep ? .kept : .used
        spec.help = Self.help(spec.look, stuck: spec.stuck)
        show()
        onFlip?(spec.look)
        DispatchQueue.main.async { toggle(keep) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Self.side / 2
        layer?.backgroundColor = (spec.look == .warning ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(isDark ? 0.14 : 0.08)).cgColor
    }
}

/// A monochrome switch: the text colour while on, a faint track while off. NSSwitch turns grey whenever its app is
/// not active, and a menu-bar app is never active while its menu is open, so every switch would look off.
final class MenuSwitch: NSView {
    static let size = NSSize(width: 32, height: 18)
    private(set) var isOn: Bool
    var onChange: ((Bool) -> Void)?
    private let track = CALayer()
    private let knob = CALayer()

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        track.cornerRadius = Self.size.height / 2
        knob.cornerRadius = (Self.size.height - 4) / 2
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track)
        track.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers) else { return super.keyDown(with: event) }
        flip()
    }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(!(window?.isVisible ?? false))
        track.frame = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (isOn ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.16)).cgColor
            // On a dark ground the lit track is white, so its knob turns dark to stay visible.
            knob.backgroundColor = (isOn && isDark ? NSColor.windowBackgroundColor : NSColor.white).cgColor
        }
        let side = bounds.height - 4
        knob.frame = NSRect(x: isOn ? bounds.width - side - 2 : 2, y: 2, width: side, height: side)
        CATransaction.commit()
        setAccessibilityValue(isOn)
    }

    /// Reflects outside state without reporting a change.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }

    /// The person turned it: from a click, a key or VoiceOver.
    private func flip() {
        isOn.toggle()
        needsDisplay = true
        onChange?(isOn)
    }
}
