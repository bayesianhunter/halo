// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore

/// `Halo --render-docs DIR`: draws Halo's own views, with devices' factory names, into PNGs for the README. No device
/// on this Mac is read, nothing is listened to, and the app does not start; the views are the ones the menu and the
/// window use, so the pictures are what people see.
enum DocsRender {
    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--render-docs"), arguments.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("usage: Halo --render-docs <folder>\n".utf8))
            return 2
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        // A binary run from .build has no bundle, so the title row and the alerts would show a generic icon. The
        // rounded tile, as the bundled app shows it; the icns holds the square art.
        if let icon = NSImage(contentsOfFile: "docs/icon.png") { NSApp.applicationIconImage = icon }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                write(menu(), appearance: appearance, to: folder.appendingPathComponent("menu-\(suffix).png"))
                write(devices(), appearance: appearance, to: folder.appendingPathComponent("devices-\(suffix).png"))
                write(peerMenu(), appearance: appearance, to: folder.appendingPathComponent("uc-menu-\(suffix).png"))
                for (mac, other) in [("pro", "MacBook Air"), ("air", "MacBook Pro")] {
                    write(pairing(with: other, appearance: appearance), appearance: appearance,
                          to: folder.appendingPathComponent("pair-\(mac)-\(suffix).png"))
                }
                write(sharing(), appearance: appearance, to: folder.appendingPathComponent("sharing-\(suffix).png"))
                writeIcons(appearance: appearance, dark: suffix == "dark", to: folder)
            }
        }
        print("rendered into \(folder.path)")
        return 0
    }

    private static let mouse = Battery(name: "Magic Mouse", serial: "", percent: 80)
    private static let trackpad = Battery(name: "Magic Trackpad", serial: "", percent: 64)
    private static let keyboard = Battery(name: "Magic Keyboard", serial: "", percent: 55)

    /// The menu as it opens with a mouse reversed, a speaker kept for music, a keyboard under two weeks from empty, and a
    /// paired Mac online.
    private static func menu() -> NSView {
        let kept = MicButton.Spec(look: .kept, help: "", toggle: nil)
        let rows: [NSView] = [
            MenuHeaderView(title: Brand.name, status: L("Reversing %@", "Magic Mouse"), state: .working, version: "0.8.0 (68)"),
            separator(),
            SectionHeading(name: "MacBook Pro", identity: L("This Mac"), trailing: L("Reverse"), inMenu: true),
            DeviceRowView(symbol: "rectangle.and.hand.point.up.left", title: L("Built-in Trackpad"), facts: [], isOn: false),
            DeviceRowView(symbol: "rectangle.and.hand.point.up.left", title: "Magic Trackpad", facts: [], battery: trackpad, isOn: false),
            DeviceRowView(symbol: "computermouse.fill", title: "Magic Mouse", facts: [], battery: mouse, isOn: true, active: true),
            DeviceRowView(symbol: "hifispeaker.fill", title: "Beats Pill", facts: [L("Music only")], isOn: nil, mic: kept),
            DeviceRowView(symbol: "keyboard.fill", title: "Magic Keyboard", facts: [L("About %ld days left", 8)], battery: keyboard, isOn: nil),
            separator(),
            SectionHeading(name: "MacBook Air", identity: nil, trailing: L("Online"), inMenu: true),
            DeviceRowView(symbol: "rectangle.and.hand.point.up.left", title: L("Built-in Trackpad"), facts: [], isOn: nil),
            DeviceRowView(symbol: "doc.on.clipboard", title: L("Get Clipboard from %@", "MacBook Air"), facts: [], isOn: nil),
        ]
        return stack(rows.map(menuSized), inset: 6)
    }

    /// Menu rows are sized by frame, as NSMenuItem views are; inside a stack they need it spelled out.
    private static func menuSized(_ row: NSView) -> NSView {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 340).isActive = true
        if row.frame.height > 0 { row.heightAnchor.constraint(equalToConstant: row.frame.height).isActive = true }
        return row
    }

    /// The menu on the MacBook Air while the MacBook Pro's mouse is in use there through Universal Control: the mouse
    /// sits with the Mac it belongs to, under this Mac's switch, and what was copied on the Pro has come over.
    private static func peerMenu() -> NSView {
        let rows: [NSView] = [
            MenuHeaderView(title: Brand.name, status: L("Reversing %@", "Magic Mouse"), state: .working, version: "0.8.0 (68)"),
            separator(),
            SectionHeading(name: "MacBook Air", identity: L("This Mac"), trailing: L("Reverse"), inMenu: true),
            DeviceRowView(symbol: "rectangle.and.hand.point.up.left", title: L("Built-in Trackpad"), facts: [], isOn: false),
            separator(),
            SectionHeading(name: "MacBook Pro", identity: nil, trailing: L("Online"), inMenu: true),
            DeviceRowView(symbol: "computermouse.fill", title: "Magic Mouse", facts: [], battery: mouse, isOn: true, active: true),
            DeviceRowView(symbol: "keyboard.fill", title: "Magic Keyboard", facts: [], battery: keyboard, isOn: nil),
            DeviceRowView(symbol: "doc.on.clipboard", title: "github.com/bayesianhunter/halo", facts: [L("Just now")],
                          isOn: nil, accessory: L("Get Latest"), chevron: false),
        ]
        return stack(rows.map(menuSized), inset: 6)
    }

    /// The comparison both Macs show while pairing, as the app builds it.
    private static func pairing(with name: String, appearance: NSAppearance) -> NSView {
        let alert = AppDelegate.comparisonAlert(code: "482913", name: name)
        alert.icon = NSApp.applicationIconImage
        alert.window.appearance = appearance
        alert.layout()
        return alert.window.contentView ?? NSView()
    }

    /// General's "Sharing Between Macs" once paired: what the pairing turned on.
    private static func sharing() -> NSView {
        let name = NSTextField(labelWithString: "MacBook Air")
        let state = NSTextField(labelWithString: L("Online"))
        state.textColor = .secondaryLabelColor
        let other = AppDelegate.settingRow(title: "MacBook Air", detail: nil, control: NSButton(title: L("Unpair…"), target: nil, action: nil),
                                           detailField: state, titleField: name, symbol: "laptopcomputer")
        let match = AppDelegate.settingRow(title: L("Sync Scrolling Settings"), detail: nil, control: MenuSwitch(isOn: true),
                                           symbol: "arrow.triangle.2.circlepath")
        let clip = AppDelegate.settingRow(title: L("Share Clipboard"), detail: nil, control: MenuSwitch(isOn: true), symbol: "doc.on.clipboard")
        let group = ListGroup(rows: [other, match, clip])
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return stack([AppDelegate.sectionLabel(L("Sharing Between Macs")), group], inset: 0, spacing: 8)
    }

    /// The Devices page: batteries with how long they last.
    private static func devices() -> NSView {
        func spec(_ symbol: String, _ title: String, _ battery: Battery?, days: Int?, on: Bool?, speed: Double? = nil) -> AppDelegate.RowSpec {
            var spec = AppDelegate.RowSpec(id: title, symbol: symbol, title: title, battery: battery)
            spec.isOn = on
            spec.speed = speed
            if let days { spec.timeLeft = (L("About %ld days left", days), "") }
            return spec
        }
        let rows = [spec("computermouse.fill", "Magic Mouse", mouse, days: 31, on: true, speed: 1.5),
                    spec("rectangle.and.hand.point.up.left", "Magic Trackpad", trackpad, days: 42, on: false),
                    spec("keyboard.fill", "Magic Keyboard", keyboard, days: 8, on: nil)]
            .map { row -> NSView in
                let view = DeviceListRow(spec: row, dimmed: false)
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalToConstant: 520).isActive = true
                return view
            }
        return stack(rows, inset: 0, spacing: 0)
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.frame.size = NSSize(width: 340, height: 11)
        return line
    }

    private static func stack(_ views: [NSView], inset: CGFloat, spacing: CGFloat = 0) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.frame.size = stack.fittingSize
        stack.layoutSubtreeIfNeeded()
        return stack
    }

    /// At twice the size, transparent around the views, so a page can set them on any background.
    private static func write(_ view: NSView, appearance: NSAppearance, to url: URL) {
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The menu-bar mark in its states: idle, a device running low (red dot), and one charging (`icon-…`); and the
    /// status items a page sets on either side of it (`bar-left`, `bar-right`).
    private static func writeIcons(appearance: NSAppearance, dark: Bool, to folder: URL) {
        let ink: NSColor = dark ? .white : .black
        let states: [(String, NSImage, Bool)] = [
            ("idle", StatusIcon.make(), false),
            ("low", StatusIcon.make(level: 0.12, dot: false), true),
            ("charging", StatusIcon.make(level: 0.62, tint: StatusIcon.color(charging: 62)), false),
        ]
        let theme = dark ? "dark" : "light"
        for (name, icon, redDot) in states {
            let large = NSImageView(image: mark(icon, redDot: redDot, ink: ink, side: 96))
            large.frame.size = NSSize(width: 96, height: 96)
            large.imageScaling = .scaleNone
            write(large, appearance: appearance, to: folder.appendingPathComponent("icon-\(name)-\(theme).png"))
        }
        write(statusItems(["speaker.wave.2.fill", "moon.fill"], clock: false, ink: ink), appearance: appearance,
              to: folder.appendingPathComponent("bar-left-\(theme).png"))
        write(statusItems(["wifi", "battery.75percent", "switch.2"], clock: true, ink: ink), appearance: appearance,
              to: folder.appendingPathComponent("bar-right-\(theme).png"))
    }

    /// The mark as the menu bar draws it: a template in the bar's colour, a tinted one as it is, and the red dot that
    /// the menu sets on a layer over it.
    private static func mark(_ icon: NSImage, redDot: Bool, ink: NSColor, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            if icon.isTemplate {
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r)
                    ink.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                icon.draw(in: rect)
            }
            if redDot {
                let scale = side / 24
                let center = CGPoint(x: (12 + StatusIcon.dotOffset * cos(StatusIcon.dotAngle)) * scale,
                                     y: (12 + StatusIcon.dotOffset * sin(StatusIcon.dotAngle)) * scale)
                let radius = StatusIcon.dotRadius * scale
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
    }

    /// Status items around Halo's in a 24 pt menu bar: the system's own symbols, and the clock at the right end.
    private static func statusItems(_ symbols: [String], clock: Bool, ink: NSColor) -> NSView {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: ink))
        var views: [NSView] = symbols.map { name in
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
            view.contentTintColor = ink
            return view
        }
        if clock {
            let time = NSTextField(labelWithString: "Tue 9:41")
            time.font = .menuBarFont(ofSize: 0)
            time.textColor = ink
            views.append(time)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.frame.size = row.fittingSize
        row.layoutSubtreeIfNeeded()
        return row
    }
}
