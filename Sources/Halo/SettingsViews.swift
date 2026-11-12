// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore

// The Halo window's own views: its frosted ground, the page picker in the title bar, and the list parts the pages
// are built from.

extension NSView {
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// The window's ground: frosted glass over whatever is behind the window, light or dark with the Mac.
final class HaloGround: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .behindWindow
        // Stays frosted when the window is in the background, rather than turning flat grey.
        state = .active
    }

    required init?(coder: NSCoder) { nil }
}

/// The page picker: a capsule of Liquid Glass floating in the title bar, the current page on a raised pill.
/// Glass is kept to this control; the content below it stays flat.
final class PillPicker: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selected = 0
    private var buttons: [NSButton] = []
    private let stack = NSStackView()
    private let thumb = PillThumb()
    private static let segment = NSSize(width: 60, height: 24)
    private static func font(_ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: 12.5, weight: weight) }
    /// Every segment is as wide as the longest title needs in bold, and never narrower than the 60 pt that fits Chinese.
    private let segmentWidth: CGFloat

    init(titles: [String]) {
        let widest = titles.map { NSAttributedString(string: $0, attributes: [.font: Self.font(.semibold)]).size().width }.max() ?? 0
        segmentWidth = max(Self.segment.width, ceil(widest) + 18)
        super.init(frame: .zero)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(pick(_:)))
            button.isBordered = false
            button.tag = index
            button.setAccessibilityLabel(title)
            button.setAccessibilityRole(.radioButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: segmentWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.segment.height).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        let content = NSView()
        for view in [thumb, stack] as [NSView] { content.addSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let host = NSGlassEffectView()
        host.cornerRadius = intrinsicContentSize.height / 2
        host.contentView = content
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L("Pages"))
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(buttons.count)
        return NSSize(width: count * segmentWidth + (count - 1) * 2 + 6, height: Self.segment.height + 6)
    }

    override func layout() {
        super.layout()
        stack.layoutSubtreeIfNeeded()
        placeThumb(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() { restyle() }

    /// Shows another page as current without reporting a change.
    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        selected = index
        restyle()
        placeThumb(animated: false)
    }

    @objc private func pick(_ sender: NSButton) {
        guard sender.tag != selected else { return }
        selected = sender.tag
        restyle()
        placeThumb(animated: true)
        onChange?(selected)
    }

    private func placeThumb(animated: Bool) {
        guard buttons.indices.contains(selected), let parent = thumb.superview else { return }
        let frame = stack.convert(buttons[selected].frame, to: parent)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.allowsImplicitAnimation = true
                thumb.animator().frame = frame
            }
        } else {
            thumb.frame = frame
        }
    }

    private func restyle() {
        for (index, button) in buttons.enumerated() {
            let current = index == selected
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: Self.font(current ? .semibold : .medium),
                // Glass lowers contrast behind it, so unselected titles use a stronger grey than secondary label.
                .foregroundColor: current ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.72)
            ])
            button.setAccessibilityValue(current ? 1 : 0)
        }
    }
}

/// The raised pill behind the current page: nearly white on light glass, a faint lift on dark.
private final class PillThumb: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.95)).cgColor
    }
}

/// Rows split by hairlines, with nothing behind them: the content stays flat on the ground.
final class ListGroup: NSView {
    /// The hairline above each row but the first, hidden with it.
    private var lines: [ObjectIdentifier: NSView] = [:]

    func show(_ row: NSView, _ shown: Bool) {
        row.isHidden = !shown
        lines[ObjectIdentifier(row)]?.isHidden = !shown
    }

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                lines[ObjectIdentifier(row)] = line
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }
}

/// The page's opening: the app icon, and what is being reversed or what is in the way. A warning leads with an orange
/// sign rather than turning the whole line orange, so it stays readable.
final class HeroView: NSView {

    /// `action` is the one button that fixes what the line says is missing, placed before the switch.
    init(title: String, detail: String, warning: Bool = false, action: (String, () -> Void)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The app icon itself, so the window opens on the same coloured mark people see in the Dock and Finder.
        let mark = NSImageView(image: NSApp.applicationIconImage)
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.setAccessibilityElement(false)
        mark.widthAnchor.constraint(equalToConstant: 48).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let note = NSTextField(labelWithString: "")
        let font = NSFont.systemFont(ofSize: 12.5)
        let line = NSMutableAttributedString()
        if warning, let sign = NSAttributedString.sign("exclamationmark.triangle.fill", tint: .systemOrange, size: 11, font: font,
                                                       description: L("Warning")) {
            line.append(sign)
        }
        line.append(NSAttributedString(string: detail, attributes: [.foregroundColor: warning ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        line.addAttribute(.font, value: font, range: NSRange(location: 0, length: line.length))
        note.attributedStringValue = line
        note.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        var views: [NSView] = [mark, labels]
        var constraints = [labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)]
        if let (title, run) = action {
            let button = ActionButton(title: title, run: run)
            // The summary gives way, not the button.
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(button)
            constraints = [button.trailingAnchor.constraint(equalTo: trailingAnchor),
                           button.centerYAnchor.constraint(equalTo: centerYAnchor),
                           labels.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16)]
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ] + constraints)
    }

    required init?(coder: NSCoder) { nil }
}

/// One peripheral in the window's list: its glyph on a soft tile, name, charge bar and facts, and its reverse switch.
final class DeviceListRow: NSView {
    var onToggle: ((Bool) -> Void)?
    var onSpeed: ((Double) -> Void)?

    init(spec: AppDelegate.RowSpec, dimmed: Bool) {
        super.init(frame: .zero)
        let tile = SoftTile(symbol: spec.symbol)
        let name = NSTextField(labelWithString: spec.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        // Cut in the middle like the menu: the owner and the model are what tell two devices apart.
        name.lineBreakMode = .byTruncatingMiddle
        // The bar is its own view and the text a plain label: text run next to an image attachment loses the
        // ground's vibrancy and reads darker than the other labels.
        // Nothing to report, no second line: a built-in trackpad's name already says what it is.
        let facts = (spec.battery.map { ["\($0.percent)%"] } ?? []) + [spec.timeLeft?.short].compactMap { $0 } + spec.facts
            + [DeviceRowView.signalText(spec.rssi)].compactMap { $0 }
        let text = NSTextField(labelWithString: facts.joined(separator: " · "))
        text.toolTip = spec.timeLeft?.basis
        text.font = .systemFont(ofSize: Layout.detailSize)
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        let bar = spec.battery.map { NSImageView(image: DeviceRowView.chargeBar($0, width: 22)) }
        bar?.setAccessibilityElement(false)
        let plug = spec.battery?.charging == true ? PlugView(connector: spec.battery?.connector) : nil
        let detail = NSStackView(views: [bar, plug, text].compactMap { $0 })
        detail.spacing = 6
        detail.isHidden = text.stringValue.isEmpty && bar == nil
        // The plug goes right into the end of the charge bar.
        if let bar, plug != nil { detail.setCustomSpacing(1, after: bar) }
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        var views: [NSView] = [tile, labels]
        // A mouse gets a second line for its wheel speed; the device line keeps its height either way.
        let line = NSLayoutGuide()
        addLayoutGuide(line)
        var constraints = [
            line.topAnchor.constraint(equalTo: topAnchor),
            line.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Layout.tileGap),
            labels.centerYAnchor.constraint(equalTo: line.centerYAnchor)
        ]
        if let speed = spec.speed {
            let control = SpeedControl(speed: speed, device: spec.title)
            control.onChange = { [weak self] in self?.onSpeed?($0) }
            views.append(control)
            constraints += [heightAnchor.constraint(equalToConstant: Layout.rowHeight + SpeedControl.rowHeight),
                            control.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
                            control.trailingAnchor.constraint(equalTo: trailingAnchor),
                            control.topAnchor.constraint(equalTo: line.bottomAnchor, constant: -6)]
        } else {
            constraints.append(heightAnchor.constraint(equalToConstant: Layout.rowHeight))
        }
        if let isOn = spec.isOn {
            let toggle = MenuSwitch(isOn: isOn)
            toggle.alphaValue = dimmed ? 0.45 : 1
            toggle.setAccessibilityLabel(L("Reverse scrolling for %@", spec.title))
            toggle.onChange = { [weak self] on in self?.onToggle?(on) }
            views.append(toggle)
            constraints += [toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
                            toggle.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                            toggle.widthAnchor.constraint(equalToConstant: MenuSwitch.size.width),
                            toggle.heightAnchor.constraint(equalToConstant: MenuSwitch.size.height),
                            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16)]
        } else if let mic = spec.mic {
            let button = MicButton(mic)
            views.append(button)
            constraints += [button.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -MenuSwitch.size.width / 2),
                            button.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                            labels.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16)]
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate(constraints)
        // One element for VoiceOver, read as the menu reads it; the switch, the mic button and the speed slider stay
        // reachable inside it.
        for part in [name, text] as [NSView] { part.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(DeviceRowView.spoken([spec.title] + spec.facts + [spec.timeLeft?.short].compactMap { $0 },
                                                   battery: spec.battery, rssi: spec.rssi))
    }

    required init?(coder: NSCoder) { nil }
}

/// A button that runs a closure, for one-off actions built with the row that offers them.
final class ActionButton: NSButton {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press() { run() }
}

/// "Scroll speed", a slider that stops only at the offered steps, and the step as "1.5×".
final class SpeedControl: NSView {
    var onChange: ((Double) -> Void)?
    private let slider: NSSlider
    private let value = NSTextField(labelWithString: "")
    private let steps = Policy.speedSteps
    /// The line under a mouse's row that holds this control.
    static let rowHeight: CGFloat = 30

    init(speed: Double, device: String) {
        let index = Policy.speedSteps.firstIndex { $0 >= speed } ?? Policy.speedSteps.count - 1
        slider = NSSlider(value: Double(index), minValue: 0, maxValue: Double(Policy.speedSteps.count - 1), target: nil, action: nil)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: L("Scroll Speed"))
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        slider.controlSize = .small
        slider.numberOfTickMarks = steps.count
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel(L("Scroll speed for %@", device))
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        show(steps[index])
        for view in [title, slider, value] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            value.widthAnchor.constraint(equalToConstant: 34),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func show(_ speed: Double) {
        value.stringValue = speed.formatted(.number.precision(.fractionLength(0...1))) + "×"
        slider.setAccessibilityValueDescription(value.stringValue)
    }

    @objc private func moved() {
        let speed = steps[Int(slider.doubleValue.rounded())]
        show(speed)
        onChange?(speed)
    }
}

/// A device glyph on a softly filled rounded square.
final class SoftTile: NSView {
    static let side: CGFloat = 32

    init(symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? (symbol == "bluetooth" ? NSImage(named: NSImage.bluetoothTemplateName) : nil)
        let glyph = NSImageView(image: image ?? NSImage())
        glyph.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        glyph.contentTintColor = .labelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: centerXAnchor), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor
    }
}

/// Something to say to an agent, as a quiet line with a copy glyph; a click puts it on the clipboard.
final class CopyLine: NSButton {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 11, weight: .regular)
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .secondaryLabelColor
        show(text)
        target = self
        action = #selector(copy(_:))
        setAccessibilityLabel(L("Copy: %@", text))
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    private func show(_ title: String) {
        attributedTitle = NSAttributedString(string: "  " + title, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                                  .foregroundColor: NSColor.labelColor])
    }

    @objc private func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(L("Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.show(self.text)
        }
    }
}
