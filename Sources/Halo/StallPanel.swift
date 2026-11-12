// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// A small notice hanging from Halo's menu-bar icon, the way a menu-bar popover does: a rounded bubble of the
/// system's popover material with a tip pointing up at the icon. A click closes it, without taking focus or bringing
/// Halo forward; otherwise it goes away by itself. It fades in and out. AppKit only, so a preview can be built from
/// this file alone.
final class StallPanel {
    enum Look {
        case stuck, restored

        var symbol: String { self == .stuck ? "keyboard.badge.ellipsis" : "checkmark.circle.fill" }
        var tint: NSColor { self == .stuck ? .systemOrange : .systemGreen }
    }

    static let width: CGFloat = 300
    static let tipHeight: CGFloat = 9
    static let tipWidth: CGFloat = 20
    static let radius: CGFloat = 12

    private var panel: NSPanel?
    private let bubble = BubbleView()
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    /// Bumped by every show, so a fade-out that finishes after a later show does not take the panel away.
    private var generation = 0

    func show(_ look: Look, title: String, body: String, under anchor: NSRect?, hideAfter: TimeInterval? = nil) {
        hideWork?.cancel()
        generation += 1
        let panel = self.panel ?? make()
        let shown = panel.isVisible && panel.alphaValue > 0
        icon.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        icon.contentTintColor = look.tint
        self.title.stringValue = title
        self.body.stringValue = body

        bubble.layoutSubtreeIfNeeded()
        let height = bubble.fittingSize.height
        let frame = Self.frame(size: NSSize(width: Self.width, height: height), under: anchor)
        panel.setFrame(frame.window, display: false)
        bubble.tipX = frame.tipX
        if !shown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        if let hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        let fading = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel, self.generation == fading else { return }
            panel.orderOut(nil)
        })
    }

    /// Under the icon on its screen, the tip at the icon's centre even when the bubble is pushed in from the edge;
    /// top right of the screen with the menu bar, tip near its right end, when the icon is hidden in the menu-bar overflow.
    static func frame(size: NSSize, under anchor: NSRect?) -> (window: NSRect, tipX: CGFloat) {
        let margin: CGFloat = 8, gap: CGFloat = 2
        let screen = anchor.flatMap { anchor in NSScreen.screens.first { $0.frame.intersects(anchor) } } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target: CGFloat, top: CGFloat
        if let anchor, anchor.width > 0 {
            target = anchor.midX
            top = min(anchor.minY, visible.maxY) - gap
        } else {
            target = visible.maxX - margin - 40
            top = visible.maxY - gap
        }
        let x = min(max(target - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        let tipX = min(max(target - x, radius + tipWidth / 2), size.width - radius - tipWidth / 2)
        return (NSRect(x: x, y: top - size.height, width: size.width, height: size.height), tipX)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // `ignoresMouseEvents` stays at its default, so clicks on the transparent corners and beside the tip go
        // through to what is under them; only the bubble takes one.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        // Both wrap: an English title is wider than the panel ("Keyboard and Mouse Not Responding" was cut off).
        title.preferredMaxLayoutWidth = Self.width - 16 - 28 - 10 - 16
        body.preferredMaxLayoutWidth = Self.width - 16 - 28 - 10 - 16
        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        bubble.content.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: bubble.content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: bubble.content.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: bubble.content.topAnchor, constant: Self.tipHeight + 12),
            row.bottomAnchor.constraint(equalTo: bubble.content.bottomAnchor, constant: -13),
            bubble.content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        bubble.onClick = { [weak self] in self?.hide() }
        panel.contentView = bubble
        self.panel = panel
        return panel
    }
}

/// The bubble: popover material cut to a rounded rectangle with a tip on top, and a hairline edge as popovers have.
final class BubbleView: NSView {
    let content = NSVisualEffectView()
    private let edge = CAShapeLayer()
    var tipX: CGFloat = StallPanel.width / 2 { didSet { needsLayout = true } }
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        edge.fillColor = nil
        edge.lineWidth = 1
        edge.zPosition = 10
        layer?.addSublayer(edge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    /// The whole bubble takes the click, its labels included; the first click counts though Halo is not active.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        let path = Self.outline(in: bounds, tipX: tipX)
        content.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
        // The edge follows the material at once, not over Core Animation's default quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = bounds
        edge.path = Self.outline(in: bounds.insetBy(dx: 0.5, dy: 0.5), tipX: tipX - 0.5)
        updateEdgeColor()
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateEdgeColor()
    }

    private func updateEdgeColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        edge.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }

    /// Rounded rectangle below a tip centred at `tipX`, y up, the tip's point at the top edge.
    static func outline(in rect: NSRect, tipX: CGFloat) -> CGPath {
        let r = StallPanel.radius, h = StallPanel.tipHeight, w = StallPanel.tipWidth
        let top = rect.maxY - h, minX = rect.minX, maxX = rect.maxX, minY = rect.minY
        let tip = rect.minX + tipX
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + r, y: top))
        path.addLine(to: CGPoint(x: tip - w / 2, y: top))
        // Softened shoulders and point, as the system's popover tip.
        path.addQuadCurve(to: CGPoint(x: tip - 2, y: rect.maxY - 1.2), control: CGPoint(x: tip - w / 4, y: top + h * 0.5))
        path.addQuadCurve(to: CGPoint(x: tip + 2, y: rect.maxY - 1.2), control: CGPoint(x: tip, y: rect.maxY + 0.6))
        path.addQuadCurve(to: CGPoint(x: tip + w / 2, y: top), control: CGPoint(x: tip + w / 4, y: top + h * 0.5))
        path.addLine(to: CGPoint(x: maxX - r, y: top))
        path.addArc(tangent1End: CGPoint(x: maxX, y: top), tangent2End: CGPoint(x: maxX, y: top - r), radius: r)
        path.addLine(to: CGPoint(x: maxX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - r, y: minY), radius: r)
        path.addLine(to: CGPoint(x: minX + r, y: minY))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + r), radius: r)
        path.addLine(to: CGPoint(x: minX, y: top - r))
        path.addArc(tangent1End: CGPoint(x: minX, y: top), tangent2End: CGPoint(x: minX + r, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}
