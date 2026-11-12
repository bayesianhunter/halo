// SPDX-License-Identifier: GPL-3.0-only
import AppKit

extension NSControl {
    /// Small, with the font to match: the size alone keeps the regular 13 pt font, which then fills the small bezel and
    /// the button looks squeezed (measured: 13 pt in a 20 pt high button). Only for the menu: even with the small font
    /// the 20 pt bezel looks cramped in a Settings row, which uses the standard 24 pt one, as System Settings does.
    func makeSmall() {
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    }
}

/// A page keeps its natural height up to the window's limit; longer content scrolls inside it.
final class SettingsScrollView: NSScrollView {
    let body: NSView
    private let document = FlippedSettingsDocument()

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        document.addSubview(body)
        documentView = document
    }

    required init?(coder: NSCoder) { nil }

    var preferredHeight: CGFloat { body.fittingSize.height }

    override func layout() {
        super.layout()
        let size = NSSize(width: contentView.bounds.width, height: body.fittingSize.height)
        document.setFrameSize(size)
        body.frame = document.bounds
        let y = min(contentView.bounds.minY, max(0, size.height - contentView.bounds.height))
        if y != contentView.bounds.minY { contentView.scroll(to: NSPoint(x: 0, y: y)) }
        reflectScrolledClipView(contentView)
    }

    func scrollToBottom() {
        layoutSubtreeIfNeeded()
        contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
}

private final class FlippedSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The measures the menu and the window share, so rows, columns and text line up the same way everywhere.
enum Layout {
    // The menu
    /// From a menu row's edges to its switch and to section headings.
    static let menuEdge: CGFloat = 14
    /// From a menu row's edge to its round tile, and from the tile to the name.
    static let menuLead: CGFloat = 12
    static let menuTileGap: CGFloat = 8
    /// Where device names start in the menu.
    static var menuTextLead: CGFloat { menuLead + RoundTile.side + menuTileGap }
    /// Between a row's text or charge and the control after it.
    static let gap: CGFloat = 10
    /// The middle of the switch column, from a menu row's trailing edge: the mic button and the column title sit on it.
    static var switchCentre: CGFloat { menuEdge + MenuSwitch.size.width / 2 }
    /// Where whatever sits left of the switch column ends, from a menu row's trailing edge.
    static var beforeSwitch: CGFloat { menuEdge + MenuSwitch.size.width + gap }

    // The window
    /// Every list row with a tile, whether a setting, a device or a disclosure; a disclosure without one is lower.
    static let rowHeight: CGFloat = 56
    static let plainRowHeight: CGFloat = 40
    /// From a tile to the text beside it.
    static let tileGap: CGFloat = 14
    /// The one size for text under a row's title, in rows, headings and disclosures.
    static let detailSize: CGFloat = 11.5
    static let footnoteSize: CGFloat = 12
}

/// The top of the menu: Halo's icon, large, its name, and a line on what it is doing with a dot that says at a glance
/// whether that is all well (green), nothing to do (grey) or needs the person (orange).
final class MenuHeaderView: NSView {
    enum State { case working, idle, attention }

    static let iconSide: CGFloat = 34

    /// `version` sits at the right, and a click copies it with the macOS version, for a bug report.
    init(title text: String, status: String, state: State, version: String? = nil, versionDetail: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        autoresizingMask = [.width]
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let dot = StatusDot(color: state == .working ? .systemGreen : state == .attention ? .systemOrange : .tertiaryLabelColor)
        let line = NSTextField(labelWithString: status)
        line.font = .systemFont(ofSize: 11)
        line.textColor = .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = version.map { VersionButton(version: $0, copies: [text, $0, versionDetail].compactMap { $0 }.joined(separator: " ")) }
        for view in [icon, title, dot, line] + [copy].compactMap({ $0 }) as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let textEnd: NSLayoutXAxisAnchor = copy?.leadingAnchor ?? trailingAnchor
        let textGap: CGFloat = copy == nil ? Layout.menuEdge : Layout.gap
        NSLayoutConstraint.activate([
            // The icon's centre on the device tiles' centre line, so the column reads straight down.
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Layout.menuLead + RoundTile.side / 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: textEnd, constant: -textGap),
            dot.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            line.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            line.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            // The version sits level with the title only, so the line under it runs to the menu's edge.
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.menuEdge),
        ])
        if let copy {
            // Its right edge on the switches' right edge, level with the title.
            NSLayoutConstraint.activate([copy.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.menuEdge + 4),
                                         copy.centerYAnchor.constraint(equalTo: title.centerYAnchor)])
        }
        let copyWidth = copy.map { $0.fittingSize.width - 4 + Layout.gap } ?? 0
        let needed = Layout.menuLead + RoundTile.side / 2 + Self.iconSide / 2 + 10
            + max(title.intrinsicContentSize.width + copyWidth, 14 + line.intrinsicContentSize.width) + Layout.menuEdge
        frame.size.width = min(DeviceRowView.maxWidth, max(320, ceil(needed)))
        // The text is one element for VoiceOver, read once, as a section heading is; the version is its own button.
        for part in [title, line, dot] as [NSView] { part.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([text, status].joined(separator: L("CLAUSE_SEPARATOR")))
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The version, quiet, with a copy glyph after it; a click puts `copies` on the clipboard and says so for a moment.
private final class VersionButton: NSButton {
    private let version: String
    private let copies: String
    private var revert: DispatchWorkItem?

    init(version: String, copies: String) {
        self.version = version
        self.copies = copies
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 10, weight: .regular)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        contentTintColor = .secondaryLabelColor
        show(version)
        target = self
        action = #selector(copyVersion)
        toolTip = L("Copy the version, for a bug report")
        setAccessibilityLabel(L("Copy: %@", copies))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    // Inside an open menu NSButton's own tracking never sees the mouse-up, so the click is taken here, as MicButton does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        copyVersion()
    }

    private func show(_ text: String) {
        attributedTitle = NSAttributedString(string: text + " ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
    }

    @objc private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copies, forType: .string)
        show(L("Copied"))
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: L("Copied"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        revert?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.show(self.version)
        }
        revert = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}

/// A small round dot in a system colour, redrawn for the appearance it is shown in.
private final class StatusDot: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
}

/// A compact menu action: explanatory text and a small native button, separate from the device switches.
final class MenuPairingActionView: NSView {
    let button: NSButton

    init(title: String, detail: String, buttonTitle: String, target: AnyObject, action: Selector) {
        button = NSButton(title: buttonTitle, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        autoresizingMask = [.width]
        button.bezelStyle = .rounded
        button.makeSmall()
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier("uc-pair-action")
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(detail)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = title
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = .systemFont(ofSize: Layout.detailSize)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [name, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        for view in [labels, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.menuEdge),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
            note.widthAnchor.constraint(equalTo: labels.widthAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.menuEdge),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// A distinct settings action below the UC heading instead of looking like another device.
final class PairingActionView: NSView {
    let button: NSButton

    init(title: String, detail: String, target: AnyObject, action: Selector) {
        button = NSButton(title: title, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setAccessibilityIdentifier("uc-pair-action")
        let label = NSTextField(wrappingLabelWithString: detail)
        label.font = .systemFont(ofSize: Layout.detailSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 400
        let stack = NSStackView(views: [button, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }
}

/// A group's heading: its name, a quieter identity beside it ("This Mac", "Online · View only"), and on the right the
/// title of the switch column. The name yields first when space is tight. In the menu the column title sits centred
/// over the switches; in the window it ends at their right edge.
final class SectionHeading: NSView {
    init(name: String, identity: String?, trailing: String? = nil, inMenu: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: inMenu ? 24 : 28))
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: inMenu ? 12 : 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = name
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func quiet(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: inMenu ? 11 : Layout.detailSize)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            return label
        }
        let edge: CGFloat = inMenu ? Layout.menuEdge : 0
        var views: [NSView] = [title]
        var constraints = [title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edge),
                           title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: inMenu ? 1 : 0)]
        if inMenu {
            autoresizingMask = [.width]
        } else {
            constraints.append(heightAnchor.constraint(equalToConstant: 28))
        }
        var last: NSView = title
        if let identity, !identity.isEmpty {
            let tag = quiet(identity)
            views.append(tag)
            constraints += [tag.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: inMenu ? 6 : 10),
                            tag.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor)]
            last = tag
        }
        if let trailing {
            let column = quiet(trailing)
            views.append(column)
            constraints += [inMenu ? column.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.switchCentre)
                                   : column.trailingAnchor.constraint(equalTo: trailingAnchor),
                            column.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                            last.trailingAnchor.constraint(lessThanOrEqualTo: column.leadingAnchor, constant: -8)]
        } else {
            constraints.append(last.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -edge))
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([name] + [identity, trailing].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: L("CLAUSE_SEPARATOR")))
    }

    required init?(coder: NSCoder) { nil }
}

/// A whole-row disclosure, with one continuous parent surface and a real keyboard/VoiceOver button.
final class DisclosureRow: NSView {
    private let stack = NSStackView()
    private let content: NSView
    private let note = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var button: ActionButton!
    var onChange: ((Bool) -> Void)?
    private(set) var expanded: Bool

    init(title: String, detail: String = "", symbol: String? = nil, content: NSView, expanded: Bool = false) {
        self.content = content
        self.expanded = expanded
        super.init(frame: .zero)
        button = ActionButton(title: "") { [weak self] in self?.toggle() }
        button.isBordered = false
        button.setAccessibilityLabel(title)
        button.toolTip = title
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.stringValue = detail
        note.isHidden = detail.isEmpty
        note.font = .systemFont(ofSize: Layout.detailSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [name, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        for view in [labels, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(view)
        }
        var constraints = [button.heightAnchor.constraint(equalToConstant: symbol == nil ? Layout.plainRowHeight : Layout.rowHeight),
                           labels.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                           labels.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
                           chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                           chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                           chevron.widthAnchor.constraint(equalToConstant: 12)]
        if let symbol {
            let tile = SoftTile(symbol: symbol)
            tile.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(tile)
            constraints += [tile.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                            tile.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                            labels.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Layout.tileGap)]
        } else {
            constraints.append(labels.leadingAnchor.constraint(equalTo: button.leadingAnchor))
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [button!, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        constraints += [stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                        stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(constraints)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func toggle() {
        expanded.toggle()
        refresh()
        onChange?(expanded)
    }

    private func refresh() {
        content.isHidden = !expanded
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        chevron.contentTintColor = .secondaryLabelColor
        button.setAccessibilityValue(expanded ? L("Expanded") : L("Collapsed"))
    }
}

extension NSAttributedString {
    /// A filled symbol in front of a line of text, centred on the text's capitals and followed by a space: the mark in
    /// white on the coloured shape, so a tick or an exclamation point reads.
    static func sign(_ symbol: String, tint: NSColor, size: CGFloat, font: NSFont, description: String? = nil) -> NSAttributedString? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [.white, tint]))) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(string: " "))
        return line
    }
}
