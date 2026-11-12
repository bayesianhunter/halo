// SPDX-License-Identifier: GPL-3.0-only
import HaloCore
import AppKit

/// A program that intercepts scroll events, found through the system's event-tap list rather than a list of app names.
struct ScrollTool {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let appURL: URL?
    /// False for listen-only taps, which see scrolling but cannot change it.
    let modifies: Bool
    let isSelf: Bool

    /// What the person would call it in settings, and how it is told apart in suspect sets and prompts asked once.
    var key: String { bundleID ?? name }
    var role: String { isSelf ? L("Reverses per device") : modifies ? L("Can change scrolling") : L("Watches scrolling, doesn’t change it") }

    var icon: NSImage {
        if let appURL { return NSWorkspace.shared.icon(forFile: appURL.path) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    /// Which processes have an enabled tap on scroll events, and whether any of their taps can modify them.
    /// Cheap enough to run every few seconds; naming the processes happens only when this changes.
    static func taps() -> [pid_t: Bool] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [:] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [:] }
        let scroll = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        var byProcess: [pid_t: Bool] = [:]
        for tap in taps.prefix(Int(count)) where tap.enabled && tap.eventsOfInterest & scroll != 0 {
            let pid = pid_t(tap.tappingProcess)
            byProcess[pid] = (byProcess[pid] ?? false) || tap.options == .defaultTap
        }
        return byProcess
    }

    /// One entry per app, ours included: an app and its helper both tapping count as one tool.
    static func describe(_ taps: [pid_t: Bool]) -> [ScrollTool] {
        var byKey: [String: ScrollTool] = [:]
        for (pid, modifies) in taps.sorted(by: { $0.key < $1.key }) {
            let tool = describe(pid: pid, modifies: modifies)
            if let existing = byKey[tool.key] {
                byKey[tool.key] = ScrollTool(pid: existing.pid, name: existing.name, bundleID: existing.bundleID, appURL: existing.appURL,
                                             modifies: existing.modifies || modifies, isSelf: existing.isSelf || tool.isSelf)
            } else {
                byKey[tool.key] = tool
            }
        }
        let rank = { (tool: ScrollTool) in tool.isSelf ? 0 : tool.modifies ? 1 : 2 }
        return byKey.values.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    /// Names the app a process belongs to. Helpers live inside their app's bundle, so the outermost .app on the
    /// executable's path is the one people recognise (the app, not its login-item helper).
    private static func describe(pid: pid_t, modifies: Bool) -> ScrollTool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        var appURL: URL?
        if let path, let range = path.range(of: ".app/") {
            appURL = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        let bundle = appURL.flatMap(Bundle.init(url:))
        let running = NSRunningApplication(processIdentifier: pid)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? running?.localizedName
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? L("Process %d", pid)
        return ScrollTool(pid: pid, name: name, bundleID: bundle?.bundleIdentifier ?? running?.bundleIdentifier, appURL: appURL,
                          modifies: modifies, isSelf: pid == getpid())
    }

    /// Asks the app to quit, as its own Quit command would; `force` is for one that ignored that request.
    /// Helpers are quit through the app that owns them.
    func quit(force: Bool = false) -> Bool {
        var apps = bundleID.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []
        if apps.isEmpty, let app = NSRunningApplication(processIdentifier: pid) { apps = [app] }
        return apps.map { force ? $0.forceTerminate() : $0.terminate() }.contains(true)
    }
}

/// One conflicting tool, either as a row inside the status menu or as a glass card in the Halo window.
final class ConflictView: NSView {
    /// A program measured changing a device's direction after Halo. No app is singled out by name: whatever it is,
    /// Halo finds out by watching what reaches apps.
    enum Kind: CustomStringConvertible {
        case blocked(device: String, sole: Bool)
        var description: String {
            switch self {
            case let .blocked(device, sole): return "blocked \(device) \(sole)"
            }
        }
    }

    var onQuit: (() -> Void)?

    init(tool: ScrollTool, kind: Kind, inMenu: Bool, canQuit: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: inMenu ? 320 : 520, height: inMenu ? 50 : 64))
        // In the menu it stretches with the rows, which grow to fit long device names.
        if inMenu { autoresizingMask = [.width] }
        let icon = NSImageView(image: tool.icon)
        let side: CGFloat = inMenu ? 26 : 34
        let titleText: String, detailText: String
        switch kind {
        case let .blocked(device, true):
            titleText = L("%@ changed the direction of %@", tool.name, device)
            detailText = inMenu ? L("Turn off its scroll setting, or quit it") : L("It changed the direction again after Halo reversed it. Turn off its scroll setting, or quit it.")
        case let .blocked(device, false):
            titleText = L("%@ may have changed the direction of %@", tool.name, device)
            detailText = inMenu ? L("Try turning off scroll settings one at a time") : L("The direction changed again after Halo reversed it, and any of the listed apps could have done it. Try turning off their scroll settings one at a time.")
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: inMenu ? 12 : 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        var views: [NSView] = [icon, labels]
        var constraints: [NSLayoutConstraint] = []
        let inset: CGFloat = inMenu ? 18 : 14
        if canQuit {
            let button = NSButton(title: inMenu ? L("Quit") : L("Quit %@", tool.name), target: self, action: #selector(quitTapped))
            // In the menu a small one fits the row; in Settings it is the standard size, as System Settings uses.
            if inMenu { button.makeSmall() }
            button.bezelStyle = .push
            // The words give way, not the button: squeezed, its title would be cut to an empty bezel.
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(button)
            constraints += [button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                            button.centerYAnchor.constraint(equalTo: centerYAnchor),
                            labels.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8)]
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset))
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate(constraints + [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: side),
            icon.heightAnchor.constraint(equalToConstant: side),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        // The tint sits behind the content; every card here is something actually getting in Halo's way.
        let backing = TintView(warning: true, inMenu: inMenu)
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing, positioned: .below, relativeTo: nil)
        let margin: CGFloat = inMenu ? 8 : 0, vertical: CGFloat = inMenu ? 3 : 0
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            backing.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func quitTapped() { onQuit?() }
}

private final class TintView: NSView {
    private let warning: Bool
    private let inMenu: Bool

    init(warning: Bool, inMenu: Bool) {
        self.warning = warning
        self.inMenu = inMenu
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = inMenu ? 9 : 14
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if warning {
                layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(inMenu ? 0.16 : 0.10).cgColor
                layer?.borderColor = NSColor.systemOrange.withAlphaComponent(inMenu ? 0 : 0.45).cgColor
            } else {
                layer?.backgroundColor = (inMenu ? NSColor.black.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.06)).cgColor
                layer?.borderColor = (inMenu ? NSColor.clear : NSColor.white.withAlphaComponent(0.10)).cgColor
            }
            layer?.borderWidth = inMenu ? 0 : 1
        }
    }
}

/// What Halo does when another tool appears: it is listed in the menu and window, and only a program measured
/// changing a device's direction gets a prompt (`blockedChanged`).
extension AppDelegate {
    /// Called on every scan change, Halo's own new tap included.
    func toolsChanged() {
        updateIconVisibility()
        settingsChanged()
    }

    /// Shows alerts one at a time and never over the open status menu, whose tracking would otherwise nest them.
    func presentAlert(_ show: @escaping () -> Void) {
        pendingAlerts.append(show)
        showNextAlert()
    }

    func showNextAlert() {
        guard !menuOpen, !alertOpen, !pendingAlerts.isEmpty else { return }
        alertOpen = true
        let show = pendingAlerts.removeFirst()
        DispatchQueue.main.async { [weak self] in
            show()
            self?.alertOpen = false
            self?.showNextAlert()
        }
    }

    /// Quits the tool. An app showing its own modal window (an update prompt, say) ignores a polite
    /// quit, so after a moment it is force-quit: the person asked for it to go.
    func quitTool(_ tool: ScrollTool) {
        // The alert and the menu's button can both ask; one quit is enough.
        guard quittingTools.insert(tool.key).inserted else { return }
        // Still running means the process, not just its tap: an app waiting on its own dialog may have dropped the tap.
        let stillRunning = { [weak self] in
            !(tool.bundleID.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []).isEmpty
                || self?.engine.tools.contains(where: { $0.key == tool.key }) == true
        }
        _ = tool.quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.engine.scanTools()
            if stillRunning() { _ = tool.quit(force: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.quittingTools.remove(tool.key)
                self.engine.scanTools()
                if stillRunning() {
                    self.notice(L("%@ didn’t quit; quit it from its own menu", tool.name))
                    self.render()
                }
            }
        }
    }

    /// Halo's icon with the other tool's icon in the corner, so the alert shows both parties at a glance.
    private func badgedIcon(_ other: NSImage) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            NSApp.applicationIconImage.draw(in: rect)
            other.draw(in: NSRect(x: rect.maxX - 30, y: 0, width: 30, height: 30))
            return true
        }
    }

    /// What gets a card: programs measured changing the direction. A program that merely could modify scrolling
    /// gets none; it is listed only on the diagnostics page.
    var conflictCards: [(ScrollTool, ConflictView.Kind)] {
        guard let blocked = engine.blocked else { return [] }
        let device = Self.displayName(blocked.device)
        return blocked.tools.map { ($0, .blocked(device: device, sole: blocked.sole)) }
    }

    /// Says once per run which program changed the direction; later findings show in the menu and window.
    func blockedChanged() {
        let device = engine.blocked.map { Self.displayName($0.device) }
        if device != loggedBlocked {
            if let previous = loggedBlocked { Events.record(EventRecord(kind: .tool, event: "unblocked", device: previous)) }
            if let device, let blocked = engine.blocked {
                Events.record(EventRecord(kind: .tool, event: "blocked", device: device, id: Events.deviceID(blocked.device),
                                          text: blocked.tools.map(\.name).joined(separator: " or ")))
            }
            loggedBlocked = device
        }
        updateIconVisibility()
        settingsChanged()
        guard let blocked = engine.blocked else { return }
        let key = "blocked:" + blocked.tools.map(\.key).joined(separator: ",")
        guard promptedTools.insert(key).inserted else { return }
        presentAlert { [weak self] in
            // Settled before the alert's turn came: ask again if it comes back.
            guard let self, self.engine.blocked == blocked else { self?.promptedTools.remove(key); return }
            self.promptBlocked(blocked)
        }
    }

    /// Only apps people launched themselves are offered for quitting; system processes and bare helpers are not.
    func canQuit(_ tool: ScrollTool) -> Bool {
        tool.appURL != nil && !(tool.bundleID ?? "").hasPrefix("com.apple.")
    }

    private func promptBlocked(_ blocked: Blocked) {
        let device = Self.displayName(blocked.device)
        let alert = NSAlert()
        if blocked.sole, let tool = blocked.tools.first {
            alert.messageText = L("%@ changed the scroll direction of %@", tool.name, device)
            alert.informativeText = L("After Halo reversed it as you set, %@ changed the direction again. Turn off its scroll setting, or quit it.", tool.name)
            alert.icon = badgedIcon(tool.icon)
            if canQuit(tool) { alert.addButton(withTitle: L("Quit %@", tool.name)) }
            alert.addButton(withTitle: L("OK"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, canQuit(tool) { quitTool(tool) }
        } else {
            alert.messageText = L("Another app changed the scroll direction of %@", device)
            alert.informativeText = L("After Halo reversed it as you set, the direction was changed again. It could be: %@. Try turning off their scroll settings one at a time.",
                                      blocked.tools.map(\.name).joined(separator: L("LIST_SEPARATOR")))
            alert.addButton(withTitle: L("OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func conflictView(_ tool: ScrollTool, _ kind: ConflictView.Kind, inMenu: Bool) -> ConflictView {
        let view = ConflictView(tool: tool, kind: kind, inMenu: inMenu, canQuit: canQuit(tool))
        view.onQuit = { [weak self] in
            self?.menu.cancelTracking()
            // Quitting a suspect proves nothing yet; the check that follows says whether the direction is right.
            self?.quitTool(tool)
        }
        return view
    }
}
