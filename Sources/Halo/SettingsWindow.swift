// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import ServiceManagement

/// The Halo window: frosted glass over the desktop, a floating glass capsule in the title bar to switch between
/// Devices, General, Diagnostics and About. Long pages scroll within the display.
extension AppDelegate {
    static let contentWidth: CGFloat = 520
    static let inset: CGFloat = 32
    /// Between one section of a page and the next.
    static let sectionSpacing: CGFloat = 26
    /// Where the picker's top sits; set once the title bar exists so the capsule lines up with the window buttons.
    static var pickerTop: CGFloat = 10

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + Self.inset * 2, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("%@ Settings", Brand.name)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // The Devices page rebuilds its rows; new switches join the Tab order without a manual recalculation.
        window.autorecalculatesKeyViewLoop = true
        // See-through: the ground blurs whatever is behind the window, as the menu and Control Center do.
        window.isOpaque = false
        window.backgroundColor = .clear
        let ground = HaloGround()
        window.contentView = ground

        pages.tabViewType = .noTabsNoBorder
        pages.drawsBackground = false
        for (title, view) in [(L("Devices"), devicesTab()), (L("General"), generalTab()), (L("Diagnostics"), diagnosticsTab()), (L("About"), aboutTab())] {
            let item = NSTabViewItem(identifier: title)
            item.view = view
            pages.addTabViewItem(item)
        }
        pagePicker.onChange = { [weak self] _ in self?.pickPage() }
        if let close = window.standardWindowButton(.closeButton), let bar = close.superview {
            let button = bar.convert(close.frame, to: nil)
            Self.pickerTop = max(0, window.frame.height - button.midY - pagePicker.intrinsicContentSize.height / 2)
        }
        for view in [pagePicker, pages] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            ground.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pagePicker.topAnchor.constraint(equalTo: ground.topAnchor, constant: Self.pickerTop),
            pagePicker.centerXAnchor.constraint(equalTo: ground.centerXAnchor),
            pages.topAnchor.constraint(equalTo: pagePicker.bottomAnchor, constant: 6),
            pages.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            pages.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        fitWindow(animated: false)
        window.center()
    }

    func pickPage() {
        pages.selectTabViewItem(at: pagePicker.selected)
        fitWindow(animated: true)
    }

    func fitWindow(animated: Bool) {
        guard let window, let page = pages.selectedTabViewItem?.view else { return }
        let chrome = Self.pickerTop + pagePicker.intrinsicContentSize.height + 6
        let preferred = (page as? SettingsScrollView)?.preferredHeight ?? page.fittingSize.height
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(chrome + preferred, available - 40)
        let content = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + Self.inset * 2, height: height))
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
        page.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Pages

    private func page(_ views: [NSView], top: CGFloat = 20) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: top, left: Self.inset, bottom: 26, right: Self.inset)
        for view in views { view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true }
        return SettingsScrollView(body: stack)
    }

    private func devicesTab() -> NSView {
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 0
        renderDevices(force: true)
        return page([devicesStack])
    }

    private func generalTab() -> NSView {
        loginSwitch.onChange = { [weak self] on in self?.setOpenAtLogin(on) }
        let login = settingRow(title: L("Open at Login"), detail: nil, control: loginSwitch, symbol: "power")
        iconSwitch.setOn(engine.showIcon)
        iconSwitch.onChange = { [weak self] on in self?.setShowIcon(on) }
        let icon = settingRow(title: L("Show in Menu Bar"), detail: nil, control: iconSwitch, symbol: "menubar.rectangle")
        icon.toolTip = L("Open Halo to show its settings when the menu bar icon is hidden.")
        dockSwitch.setOn(engine.showDock)
        dockSwitch.onChange = { [weak self] on in self?.setShowDock(on) }
        let dock = settingRow(title: L("Show in Dock"), detail: nil, control: dockSwitch, symbol: "dock.rectangle")
        dock.toolTip = L("Keep Halo in the Dock after Settings closes.")
        accessButton.title = L("Open Settings")
        accessButton.target = self
        accessButton.action = #selector(permissions)
        let access = settingRow(title: L("Accessibility Access"), detail: nil, control: accessButton, detailField: accessDetail, symbol: "accessibility")
        let languages = NSPopUpButton()
        languages.addItems(withTitles: Language.allCases.map(\.title))
        languages.selectItem(at: Language.allCases.firstIndex(of: Language.current) ?? 0)
        languages.target = self
        languages.action = #selector(changeLanguage(_:))
        let language = settingRow(title: L("Language"), detail: nil, control: languages, symbol: "globe")
        language.toolTip = L("Halo restarts when its language changes.")
        linkButton.target = self
        linkDetail.lineBreakMode = .byTruncatingTail
        linkDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let other = settingRow(title: L("Another Mac"), detail: nil, control: linkButton, detailField: linkDetail,
                               titleField: linkName, symbol: "laptopcomputer")
        other.toolTip = L("Once paired with another Mac, each shows the other’s devices, battery levels and reversing while both are on the same network.")
        renderLink()
        matchSwitch.setOn(engine.matchSettings)
        matchSwitch.onChange = { [weak self] on in
            guard let self else { return }
            self.engine.setMatchSettings(on)
            if on { self.matchPeerSettings() }
            self.sharingChanged()
        }
        let match = settingRow(title: L("Sync Scrolling Settings"), detail: nil,
                               control: matchSwitch, symbol: "arrow.triangle.2.circlepath")
        match.toolTip = L("Sync scroll direction and wheel speed between these Macs.")
        clipSwitch.setOn(engine.shareClipboard)
        clipSwitch.onChange = { [weak self] on in
            guard let self else { return }
            self.engine.setShareClipboard(on)
            self.sharingChanged()
            // Reading the clipboard without a paste counts as programmatic access, which macOS may ask about. Read it
            // once now, so that question comes while the person is at this Mac, not when they leave it.
            if on { self.clipboard.prime() }
        }
        clipDetail.lineBreakMode = .byTruncatingTail
        clipDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clip = settingRow(title: L("Share Clipboard"), detail: nil, control: clipSwitch, detailField: clipDetail, symbol: "doc.on.clipboard")
        clip.toolTip = L("When Universal Control moves the pointer to the other Mac, text or an image you copied here goes ahead of you, ready for ⌘V there. It’s kept in memory only, never written to disk.")
        let tools = DisclosureRow(title: L("Other Scroll Apps"), content:
            footnote(L("Halo pauses while another scroll-reversing app is running and resumes when it quits.")))
        tools.onChange = { [weak self] _ in self?.fitWindow(animated: true) }
        let local = ListGroup(rows: [login, icon, dock, language, access])
        let sharing = sectionLabel(L("Sharing Between Macs"))
        let group = ListGroup(rows: [other, match, clip])
        sharingGroup = group
        sharingRows = [match, clip]
        let uninstallButton = NSButton(title: L("Uninstall…"), target: self, action: #selector(uninstallHalo))
        uninstallButton.isEnabled = Self.canUninstall
        let uninstall = ListGroup(rows: [settingRow(title: L("Uninstall Halo"), detail: L("Removes everything Halo put on this Mac"),
                                                    control: uninstallButton, symbol: "trash")])
        let result = page([pageTitle(L("General")), local, sharing, group, tools, uninstall])
        if let body = (result as? SettingsScrollView)?.body as? NSStackView {
            body.setCustomSpacing(Self.sectionSpacing, after: local)
            body.setCustomSpacing(Self.sectionSpacing, after: group)
            body.setCustomSpacing(Self.sectionSpacing, after: tools)
        }
        showSharingRows()
        return result
    }

    /// The General page's pairing row: what the link is doing and the one action that fits.
    func renderLink() {
        presentComparison()
        let detail: NSAttributedString
        let title: String
        let action: Selector
        let plain = { (text: String, color: NSColor) in
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: Layout.detailSize), .foregroundColor: color])
        }
        if let peer = link.peer {
            linkName.stringValue = peer.name
            linkName.toolTip = peer.name
            if link.keyDeclined {
                detail = plain(L("Halo wasn’t allowed to read the pairing key from the keychain; it will ask again when reopened"), .systemOrange)
            } else if link.online {
                let shared = engine.matchSettings || engine.shareClipboard
                detail = plain(link.path == .direct ? L("Online · Direct link while the network is blocked") : shared ? L("Online") : L("Online · View only"), .secondaryLabelColor)
            } else if link.verdict == .tcpBlocked, let check = link.lastCheck, Date().timeIntervalSince(check.at) < 1800 {
                detail = plain(L("Offline · The network is blocking the connection; restarting the router usually fixes it"), .systemOrange)
            } else {
                detail = plain(L("Offline · Paired, waiting to reconnect"), .secondaryLabelColor)
            }
            title = L("Unpair…")
            action = #selector(unpairLink)
        } else {
            linkName.stringValue = L("Another Mac")
            switch link.pairing {
            case .searching:
                detail = plain(L("Looking for your other Mac… click Pair on it too"), .secondaryLabelColor)
                title = L("Cancel")
                action = #selector(cancelLinkPairing)
            case .comparing(let code, _, let confirmed):
                // The digits are the one thing to read from across the desk, so they are large; the rest stays quiet.
                let text = NSMutableAttributedString(string: Self.spaced(code) + "  ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
                text.append(plain(confirmed ? L("Waiting for Match on the other Mac…") : L("Compare the numbers on both Macs"), .secondaryLabelColor))
                detail = text
                title = L("Cancel")
                action = #selector(cancelLinkPairing)
            case .idle:
                detail = link.notice.map { plain($0, .systemOrange) } ?? plain(L("See another Mac’s devices and battery levels here"), .secondaryLabelColor)
                title = L("Pair…")
                action = #selector(pairLink)
            }
        }
        if linkDetail.attributedStringValue != detail { linkDetail.attributedStringValue = detail }
        let clipText: NSAttributedString
        if link.peer != nil, engine.shareClipboard, clipboard.peerClipboard == false {
            clipText = plain(L("Waiting for the other Mac to turn this on"), .secondaryLabelColor)
        } else if engine.shareClipboard, clipboard.readNeedsSettings {
            // Anything but "always allow" would leave a question waiting on the Mac the person just left.
            clipText = plain(L("Allow Halo to always read the clipboard in System Settings"), .systemOrange)
        } else {
            clipText = plain("", .secondaryLabelColor)
        }
        if clipDetail.attributedStringValue != clipText { clipDetail.attributedStringValue = clipText }
        clipDetail.isHidden = clipText.length == 0
        if linkButton.title != title { linkButton.title = title }
        linkButton.action = action
        showSharingRows()
    }

    /// The sharing switches belong to a pairing: unpaired, they are chosen in the Pair alert instead.
    private func showSharingRows() {
        let paired = link.peer != nil
        guard let group = sharingGroup, sharingRows.contains(where: { $0.isHidden == paired }) else { return }
        sharingRows.forEach { group.show($0, paired) }
        // While the page is being built no tab is selected yet, and this does nothing.
        fitWindow(animated: true)
    }

    /// Where pairing stands, in one word: "idle", "searching", "comparing", or "confirmed" once this Mac clicked Match.
    var pairingStep: String {
        switch link.pairing {
        case .idle: return "idle"
        case .searching: return "searching"
        case .comparing(_, _, let confirmed): return confirmed ? "confirmed" : "comparing"
        }
    }

    /// The notes around this Mac's list. Neither Mac knows whether it was set up first, so each says what it sees: no
    /// mouse here (it may be on the other Mac), above the list; or, on the first launch only, with built-in ones alone
    /// and no other Mac connected, a hint below it (someone with one MacBook would otherwise read it for good).
    func devicesNotes(_ pointing: [RowSpec], universalControl: Bool) -> (above: String?, below: String?) {
        if pointing.isEmpty {
            return (L("No mouse or trackpad yet. If yours is connected to another Mac, move the pointer here with Universal Control and it shows up by itself."), nil)
        }
        if firstLaunch, pointing.allSatisfy(\.builtIn), !universalControl {
            return (nil, L("Mouse connected to another Mac? Move the pointer here with Universal Control and it shows up by itself."))
        }
        return (nil, nil)
    }

    /// While Universal Control connects another Mac that is not paired.
    func pairCardShown(universalControl: Bool) -> Bool { link.peer == nil && universalControl }

    /// The card's words and its button's, by where pairing stands.
    func pairCardContent() -> (title: String, detail: String, button: String, action: Selector) {
        switch link.pairing {
        case .idle:
            // Why the last attempt ended, as the General page says it, until a new one starts.
            return (L("Pair with Another Mac…"), link.notice ?? L("Install Halo on it too and pair, to keep reverse and the clipboard the same"),
                    L("Pair with Another Mac…"), #selector(pairLink))
        case .searching:
            return (L("Another Mac Connected"), L("Looking for your other Mac… click Pair on it too"), L("Cancel"), #selector(cancelLinkPairing))
        case .comparing(_, _, let confirmed):
            return (L("Another Mac Connected"), confirmed ? L("Waiting for Match on the other Mac…") : L("Compare the numbers on both Macs"),
                    L("Cancel"), #selector(cancelLinkPairing))
        }
    }

    /// While Universal Control connects another Mac that is not paired: the one step that makes the two one setup.
    private func pairCard() -> NSView {
        let content = pairCardContent()
        let action = PairingActionView(title: content.button, detail: content.detail, target: self, action: content.action)
        pairCardButton = action.button
        return action
    }

    @objc func pairLink() {
        let alert = NSAlert()
        alert.messageText = L("Pair with Another Mac")
        alert.informativeText = L("Keep both Macs on the same network. Click Pair on both; if the six-digit codes are the same, click Match on both.")
        // The same two switches as in General, on unless the person unticks one. Ticked differently on the two Macs,
        // off wins (see `SettingSync.pairingStamp`).
        let match = NSButton(checkboxWithTitle: L("Sync Scrolling Settings"), target: nil, action: nil)
        let clip = NSButton(checkboxWithTitle: L("Share Clipboard"), target: nil, action: nil)
        match.state = .on
        clip.state = .on
        let choices = NSStackView(views: [match, clip])
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 8
        choices.frame.size = choices.fittingSize
        alert.accessoryView = choices
        alert.addButton(withTitle: L("Pair"))
        alert.addButton(withTitle: L("Cancel"))
        alert.layout()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.pairingChoice = (match.state == .on, clip.state == .on)
            // As when the switch is flipped by hand: macOS may ask about reading the clipboard, and the person is here
            // now, which they may not be when the pairing completes.
            if clip.state == .on { self.clipboard.prime() }
            self.link.startPairing()
        }
    }

    static func spaced(_ code: String) -> String { code.prefix(3) + " " + code.suffix(3) }

    /// The six digits to compare with `name`, and Match or Don’t Match. Also drawn for the README (`DocsRender`).
    static func comparisonAlert(code: String, name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("Compare the number on %@", name)
        alert.informativeText = L("If both Macs show the same number, click Match on both. If not, click Don’t Match: another device may be posing as your Mac.")
        let digits = NSTextField(labelWithString: spaced(code))
        digits.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        digits.alignment = .center
        digits.frame = NSRect(x: 0, y: 0, width: 220, height: 40)
        digits.setAccessibilityLabel(code.map(String.init).joined(separator: " "))
        alert.accessoryView = digits
        alert.addButton(withTitle: L("Match"))
        alert.addButton(withTitle: L("Don’t Match"))
        return alert
    }

    /// Puts the digits in front of the person once both Macs have them, and takes them away when the attempt ends
    /// on its own (the other Mac cancelled, time ran out). Called on every link change.
    func presentComparison() {
        guard case .comparing(let code, let name, false) = link.pairing else {
            if let sheet = compareSheet {
                compareSheet = nil
                window.endSheet(sheet.window, returnCode: .abort)
            }
            return
        }
        guard compareSheet == nil else { return }
        let alert = Self.comparisonAlert(code: code, name: name)
        compareSheet = alert
        // In front even if Settings sits behind another app or on another Space: the digits have a time limit.
        showWindow()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .abort else { return }
            self.compareSheet = nil
            if response == .alertFirstButtonReturn {
                self.link.confirmPairing()
            } else {
                self.link.cancelPairing(notice: L("The numbers didn’t match; pairing cancelled"))
            }
        }
    }

    @objc func cancelLinkPairing() { link.cancelPairing() }

    @objc func unpairLink() {
        guard let peer = link.peer else { return }
        let alert = NSAlert()
        alert.messageText = L("Unpair from %@?", peer.name)
        // Only a connected Mac hears it; one offline keeps its side until it is unpaired there.
        alert.informativeText = link.online ? L("Both Macs delete the pairing key and stop showing each other’s devices.")
                                            : L("This Mac deletes the pairing key. The other Mac isn’t online, so unpair it there too.")
        alert.addButton(withTitle: L("Unpair"))
        alert.addButton(withTitle: L("Keep"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.link.unpair()
        }
    }

    /// Pairing completed: the two switches take what was ticked when Pair was clicked here. It can complete while the
    /// person is already at the other Mac, so nothing here asks them anything.
    func paired() {
        let choice = pairingChoice ?? (true, true)
        pairingChoice = nil
        engine.choosePairSharing(match: choice.match, clipboard: choice.clipboard)
        matchSwitch.setOn(choice.match)
        clipSwitch.setOn(choice.clipboard)
        sharingChanged()
    }

    /// After either Mac unpaired: what belonged to that pairing goes with it.
    func pairingForgotten() {
        pairingChoice = nil
        engine.resetSharing()
        matchSwitch.setOn(false)
        clipSwitch.setOn(false)
        updateClipboard()
    }

    /// Diagnostics, for the person: whether anything is wrong, and the way to hand the rest to an agent. Recording,
    /// the scroll sources, the link and audio checks all live in the export and run from `Halo --diagnostics`.
    private func diagnosticsTab() -> NSView {
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byWordWrapping
        diagnosisButton.target = self
        let title = pageTitle(L("Diagnostics"), detailField: statusLabel, action: diagnosisButton)
        summaryButton.title = L("Copy")
        summaryButton.target = self
        summaryButton.action = #selector(copySummary)
        let summary = settingRow(title: L("Diagnostics Summary"), detail: nil, control: summaryButton,
                                 symbol: "doc.on.clipboard")
        let agent = ListGroup(rows: [agentSkillRow(), summary])
        let prompts = NSStackView(views: [
            L("My mouse scrolls the wrong way in Halo — take a look"), L("My speaker keeps cutting out — check it with Halo"),
            L("Halo can’t reach my other Mac"), L("Use Halo to make my mouse wheel faster")
        ].map { CopyLine(text: $0) })
        prompts.orientation = .vertical
        prompts.alignment = .leading
        prompts.spacing = 2
        for line in prompts.arrangedSubviews { line.widthAnchor.constraint(equalTo: prompts.widthAnchor).isActive = true }
        let examples = DisclosureRow(title: L("Example Requests"), content: prompts)
        let privacy = DisclosureRow(title: L("Privacy"), content:
            footnote(L("No keystrokes, screen content or microphone audio is recorded. Halo never saves shared clipboard content to disk.")))
        for row in [examples, privacy] {
            row.onChange = { [weak self] _ in self?.fitWindow(animated: true) }
        }
        let result = page([title, agent, examples, privacy])
        if let body = (result as? SettingsScrollView)?.body as? NSStackView {
            for view in [title, agent] { body.setCustomSpacing(Self.sectionSpacing, after: view) }
        }
        renderDiagnosis()
        return result
    }

    /// The Diagnostics page's opening line: all is well, or what is wrong, with the one button that fixes it when
    /// there is one.
    func renderDiagnosis() {
        var problem: String?
        var fix: (String, Selector)?
        if engine.tap == nil {
            problem = engine.trusted ? L("Not listening to scrolling") : L("Needs Accessibility access")
            fix = engine.trusted ? (L("Restart Listening"), #selector(start)) : (L("Allow…"), #selector(permissions))
        } else if let note = menuNote {
            problem = note
        } else if let peer = link.peer, !link.online, link.verdict == .tcpBlocked {
            problem = L("Can’t reach %@: the network is blocking the connection; restarting the router usually fixes it", peer.name)
        } else if let (name, alert) = recentAudioTrouble {
            // What the speaker's row says for ten minutes after a weak signal.
            problem = L("%@: %@", name, alert)
        }
        let font = NSFont.systemFont(ofSize: 13)
        let line = NSMutableAttributedString()
        let symbol = problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let tint: NSColor = problem == nil ? .systemGreen : .systemOrange
        if let sign = NSAttributedString.sign(symbol, tint: tint, size: 12, font: font) { line.append(sign) }
        line.append(NSAttributedString(string: problem ?? L("Everything looks fine"), attributes: [.foregroundColor: NSColor.labelColor]))
        line.addAttribute(.font, value: font, range: NSRange(location: 0, length: line.length))
        // A passing notice (an export written, a setting not saved) goes under it, then any state file that could not
        // be read, for as long as Halo runs.
        for notice in [engine.status].compactMap({ $0 }) + StateFiles.problems {
            line.append(NSAttributedString(string: "\n" + notice, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                                .font: NSFont.systemFont(ofSize: Layout.detailSize)]))
        }
        if statusLabel.attributedStringValue != line { statusLabel.attributedStringValue = line }
        diagnosisButton.isHidden = fix == nil
        if let fix {
            if diagnosisButton.title != fix.0 { diagnosisButton.title = fix.0 }
            diagnosisButton.action = fix.1
        }
    }

    /// Writes a fresh export, as `Halo --diagnostics` would, and puts its summary on the clipboard for any chat.
    @objc func copySummary() {
        guard exportForPerson(), let text = try? String(contentsOf: DiagnosticsExport.folder.appendingPathComponent(DiagnosticsReport.markdownName), encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        summaryButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.summaryButton.title = L("Copy") }
    }

    @objc private func openSource() { NSWorkspace.shared.open(Brand.source) }

    /// GitHub or mail, each with the version and macOS already written in.
    @objc private func showFeedback(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Report on GitHub…"), action: #selector(reportOnGitHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Email %@", Brand.feedbackEmail), action: #selector(emailFeedback), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// "Halo 0.8.0 (68) · macOS 27.2 (26B123)", the line a report starts from.
    var versionLine: String { "Halo \(version) (\(build)) · \(DiagnosticsExport.macOSVersion)" }

    private func feedbackBody() -> String {
        L("What happened:") + "\n\n\n" + L("Diagnostics summary, if you like (Settings → Diagnostics → Copy):") + "\n\n\n---\n" + versionLine
    }

    /// URLComponents leaves "+" as it is, and a query reads a bare "+" as a space.
    private func open(_ url: URLComponents) {
        var url = url
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let link = url.url { NSWorkspace.shared.open(link) }
    }

    /// The repository has issue templates, so this lands on their chooser: `version` fills the bug form's version
    /// field (GitHub passes a form's field ids through the chooser), and `body` fills a blank issue.
    @objc private func reportOnGitHub() {
        var url = URLComponents(url: Brand.issues, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "version", value: versionLine), URLQueryItem(name: "body", value: feedbackBody())]
        open(url)
    }

    @objc private func emailFeedback() {
        var url = URLComponents()
        url.scheme = "mailto"
        url.path = Brand.feedbackEmail
        url.queryItems = [URLQueryItem(name: "subject", value: "Halo \(version) (\(build))"), URLQueryItem(name: "body", value: feedbackBody())]
        open(url)
    }

    private func aboutTab() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let name = NSTextField(labelWithString: Brand.name)
        name.font = .systemFont(ofSize: 28, weight: .semibold)
        let version = NSTextField(labelWithString: L("Version %@", self.version))
        version.textColor = .secondaryLabelColor
        var views: [NSView] = [icon, name, version]
        // Feedback beside updates: both are what someone comes to About for.
        let feedback = NSButton(title: L("Send Feedback…"), target: self, action: #selector(showFeedback(_:)))
        feedback.controlSize = .small
        var buttons: [NSView] = [feedback]
        if updates.available {
            let button = NSButton(title: L("Check for Updates…"), target: updates, action: #selector(Updates.checkForUpdates(_:)))
            button.controlSize = .small
            buttons.insert(button, at: 0)
        }
        let actions = NSStackView(views: buttons)
        actions.spacing = 8
        views.append(actions)
        // Not translated: a company's name stays as registered.
        if let notice = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            let copyright = NSTextField(labelWithString: notice)
            copyright.font = .systemFont(ofSize: 11)
            copyright.textColor = .tertiaryLabelColor
            views.append(copyright)
        }
        // GPL-3.0 asks an interactive program to say that it is free software, without warranty, and where its license
        // is; the license texts are also in the app (Contents/Resources/Licenses).
        let license = NSTextField(wrappingLabelWithString: L("Free software under the GNU GPL v3, with no warranty. Updates by Sparkle (MIT)."))
        license.font = .systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor
        license.alignment = .center
        license.preferredMaxLayoutWidth = Self.contentWidth
        let source = NSButton(title: L("Source Code and Licenses"), target: self, action: #selector(openSource))
        source.isBordered = false
        source.contentTintColor = .linkColor
        source.font = .systemFont(ofSize: 11)
        views += [license, source]
        let stack = NSStackView(views: views)
        stack.setCustomSpacing(12, after: version)
        stack.setCustomSpacing(12, after: actions)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 32, right: 24)
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + Self.inset * 2).isActive = true
        return stack
    }

    // MARK: Live parts

    func renderSettings() {
        renderDevices(force: false)
        renderLink()
        renderDiagnosis()
        let trusted = engine.trusted
        accessDetail.stringValue = trusted ? L("Allowed") : L("Allow Halo in System Settings")
        accessDetail.textColor = trusted ? .secondaryLabelColor : .systemOrange
        accessButton.isHidden = trusted
    }

    /// Where keyboard focus sits in the device list: the row it is in, and the path to it inside that row.
    private func focusInDevices() -> (row: NSUserInterfaceItemIdentifier, path: [Int])? {
        guard var view = window.firstResponder as? NSView, view.isDescendant(of: devicesStack) else { return nil }
        var path: [Int] = []
        while !(view is DeviceListRow) {
            guard view !== devicesStack, let parent = view.superview, let index = parent.subviews.firstIndex(of: view) else { return nil }
            path.insert(index, at: 0)
            view = parent
        }
        return view.identifier.map { ($0, path) }
    }

    private func restoreFocus(_ focus: (row: NSUserInterfaceItemIdentifier, path: [Int])) {
        func find(in view: NSView) -> NSView? {
            if view is DeviceListRow { return view.identifier == focus.row ? view : nil }
            return view.subviews.lazy.compactMap(find).first
        }
        guard var view = find(in: devicesStack) else { return }
        for index in focus.path {
            guard view.subviews.indices.contains(index) else { return }
            view = view.subviews[index]
        }
        if view.acceptsFirstResponder, window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    /// Rebuilds the cards only when one would change, and never while a mouse button is down,
    /// so a switch being clicked is not replaced between press and release.
    func renderDevices(force: Bool) {
        // Not mid-click: it catches up once the button is up.
        if !force, NSEvent.pressedMouseButtons != 0 { return renderAfterClick() }
        clickReleased()
        // A rebuild would drop keyboard focus, and the person would have to Tab back from the top after every Space;
        // so focus on a device row's control goes back to the same control of the same row. Focus anywhere else in
        // the list (a disclosure, a card) holds the rebuild off until it moves on.
        let focus = focusInDevices()
        let focusOnPairCard = pairCardButton != nil && window.firstResponder === pairCardButton
        if !force, focus == nil, !focusOnPairCard, let focused = window.firstResponder as? NSView, focused.isDescendant(of: devicesStack) {
            heldForFocus = true
            return
        }
        let groups = deviceGroups()
        rowsChangeAt = (groups.mine + groups.universalControl + (groups.peer?.rows.map(\.0) ?? [])).compactMap(\.changesAt).min()
        let pairingStep = self.pairingStep
        let universalControl = engine.universalControlConnected
        let rowsSignature = { (specs: [RowSpec]) in specs.map(\.signature).joined(separator: "\n") }
        // The offline heading's "Last connected today" is in it, so the midnight refresh rebuilds it.
        let lastSeen = link.online ? "" : link.peer?.lastSeen.map(Language.current.dateText) ?? ""
        let signature = rowsSignature(groups.mine) + "|\(engine.policy.enabled)|\(menuNote ?? "")|\(link.online)|\(link.peer?.name ?? "")|\(lastSeen)"
            + "|\(universalControl)|\(pairingStep)|" + rowsSignature(groups.universalControl)
            + conflictCards.map { "\($0.0.key):\($0.1)" }.joined(separator: ",")
            + (groups.peer.map { p in "|" + p.title + p.rows.map { "\($0.0.signature)\($0.0.lent)\($0.1)" }.joined() + (p.note ?? "") } ?? "")
        guard force || signature != devicesSignature else { return }
        devicesSignature = signature
        defer {
            if let focus { restoreFocus(focus) }
            // The card is rebuilt with the step it shows; focus stays on its button, as on a row's switch.
            if focusOnPairCard, let button = pairCardButton { window.makeFirstResponder(button) }
        }
        devicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let needsAccess = engine.tap == nil && !engine.trusted
        var allow: (String, () -> Void)?
        if needsAccess { allow = (L("Allow…"), { [weak self] in self?.permissions() }) }
        let hero = HeroView(title: Brand.name, detail: scrollingSummary(groups.allPointing),
                            warning: needsAccess || engine.blocked != nil, action: allow)
        devicesStack.addArrangedSubview(hero)
        hero.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        for (tool, kind) in conflictCards {
            devicesStack.setCustomSpacing(12, after: devicesStack.arrangedSubviews.last!)
            let card = conflictView(tool, kind, inMenu: false)
            devicesStack.addArrangedSubview(card)
            card.heightAnchor.constraint(equalToConstant: 64).isActive = true
        }

        // A section is its label and a list of rows split by hairlines, with no card behind them.
        func heading(_ name: String, identity: String?, trailing: String? = nil) {
            devicesStack.setCustomSpacing(Self.sectionSpacing, after: devicesStack.arrangedSubviews.last!)
            let heading = SectionHeading(name: name, identity: identity, trailing: trailing)
            devicesStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            devicesStack.setCustomSpacing(4, after: devicesStack.arrangedSubviews.last!)
        }
        // Two devices can share a name, so the identifier also counts which of that name the row is: focus goes back to
        // the same one, not the first.
        var seen: [String: Int] = [:]
        func rows(_ specs: [RowSpec]) -> [NSView] {
            specs.map { spec -> NSView in
                // A row of this Mac's: one attached here, or one lent here, under whichever Mac lends it.
                let here = !spec.id.hasPrefix("#peer-")
                let row = DeviceListRow(spec: spec, dimmed: here && !engine.policy.enabled)
                let id = (here ? "here:" : "peer:") + spec.id
                let index = seen[id, default: 0]
                seen[id] = index + 1
                row.identifier = NSUserInterfaceItemIdentifier(id + "#\(index)")
                row.onToggle = spec.onToggle
                row.onSpeed = spec.onSpeed
                return row
            }
        }
        func list(_ specs: [RowSpec]) -> NSView { ListGroup(rows: rows(specs)) }
        func append(_ view: NSView) {
            devicesStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        heading(link.computerName, identity: L("This Mac"), trailing: groups.minePointing.isEmpty ? nil : L("Reverse"))
        // Neither Mac knows whether it was set up first. Each says what it sees: no mouse here (it may be on the other
        // Mac), or Universal Control connecting another Mac that is not paired yet.
        let notes = devicesNotes(groups.allPointing, universalControl: universalControl)
        if let above = notes.above { append(footnote(above)) }
        if !groups.mine.isEmpty { append(list(groups.mine)) }
        if let below = notes.below { append(footnote(below)) }
        // Devices lent here that are not known to be the paired Mac's, with the card that pairs the Mac lending them.
        let showCard = pairCardShown(universalControl: universalControl)
        if showCard || !groups.universalControl.isEmpty {
            heading(L("Universal Control"), identity: nil, trailing: groups.universalControl.isEmpty ? nil : L("Reverse"))
            if showCard { append(pairCard()) }
            if !groups.universalControl.isEmpty { append(ListGroup(rows: rows(groups.universalControl))) }
        }
        if !showCard { pairCardButton = nil }
        if let peer = link.peer {
            let offline = peer.lastSeen.map { L("Offline · Last connected %@", Language.current.dateText($0)) } ?? L("Offline")
            // Its devices, each in its place; one it lends here through Universal Control carries this Mac's switch.
            let lent = groups.peer?.rows.map(\.0).filter(\.lent) ?? []
            heading(peer.name, identity: link.online ? (lent.isEmpty ? L("Online · View only") : L("Online")) : offline,
                    trailing: lent.isEmpty ? nil : L("Reverse"))
            if !link.online {
                // Universal Control can still lend a device while Halo's link is down: its switch stays in reach, and the
                // rest is the snapshot from the last connection.
                if !lent.isEmpty { append(list(lent)) }
                if let remote = groups.peer {
                    let saved = remote.rows.map(\.0).filter { !$0.lent }
                    if !saved.isEmpty {
                        let count = saved.count
                        let snapshot = DisclosureRow(title: count == 1 ? L("1 Saved Device") : L("%ld Saved Devices", count),
                                                     detail: L("Snapshot from last connection"),
                                                     symbol: "laptopcomputer", content: list(saved),
                                                     expanded: remoteSnapshotExpanded)
                        snapshot.onChange = { [weak self] expanded in
                            self?.remoteSnapshotExpanded = expanded
                            self?.fitWindow(animated: true)
                        }
                        append(snapshot)
                    }
                } else {
                    append(footnote(L("Its devices show once the other Mac is online.")))
                }
            } else if let remote = groups.peer {
                append(list(remote.rows.map(\.0)))
                if let note = remote.note { append(footnote(note)) }
            }
        }
        devicesStack.setCustomSpacing(22, after: devicesStack.arrangedSubviews.last!)
        let help = DisclosureRow(title: L("How Scrolling Works"), content:
            footnote(L("Reverse changes vertical scrolling. Speed applies to mouse wheels. Settings are saved for each device.")),
                                 expanded: scrollingHelpExpanded)
        help.onChange = { [weak self] expanded in
            self?.scrollingHelpExpanded = expanded
            self?.fitWindow(animated: true)
        }
        append(help)
        if pagePicker.selected == 0 { fitWindow(animated: false) }
    }

    private func setShowDock(_ on: Bool) {
        engine.showDock = on
        // Switched off with Settings open, Halo stays in the Dock until the window closes.
        NSApp.setActivationPolicy(on || window.isVisible ? .regular : .accessory)
        // Leaving the Dock deactivates the app; keep the window the person is using in front.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice(L("Couldn’t change Open at Login: %@", error.localizedDescription))
        }
        loginSwitch.setOn(SMAppService.mainApp.status == .enabled)
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> NSTextField { Self.sectionLabel(text) }

    static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: Layout.footnoteSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func pageTitle(_ title: String, detail: String? = nil, detailField: NSTextField? = nil, action: NSView? = nil) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let note = detailField ?? footnote(detail ?? "")
        note.isHidden = detailField == nil && detail == nil
        let labels = NSStackView(views: [name, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        let row = NSStackView(views: [labels] + [action].compactMap { $0 })
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 20
        return row
    }

    func settingRow(title: String, detail: String?, control: NSView, detailField: NSTextField? = nil,
                    titleField: NSTextField? = nil, symbol: String? = nil) -> NSView {
        Self.settingRow(title: title, detail: detail, control: control, detailField: detailField, titleField: titleField, symbol: symbol)
    }

    /// Also drawn for the README (`DocsRender`).
    static func settingRow(title: String, detail: String?, control: NSView, detailField: NSTextField? = nil,
                           titleField: NSTextField? = nil, symbol: String? = nil) -> NSView {
        let row = NSView()
        let name = titleField ?? NSTextField(labelWithString: title)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let note = detailField ?? NSTextField(labelWithString: detail ?? "")
        note.font = .systemFont(ofSize: Layout.detailSize)
        if detailField == nil { note.textColor = .secondaryLabelColor }
        let labels = NSStackView(views: [name, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = detailField == nil && (detail ?? "").isEmpty
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tile = symbol.map(SoftTile.init(symbol:))
        for view in [labels, control] + [tile].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: tile == nil ? 0 : SoftTile.side + Layout.tileGap),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12)
        ])
        if let tile {
            NSLayoutConstraint.activate([tile.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                                         tile.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
        }
        if let toggle = control as? MenuSwitch {
            toggle.setAccessibilityLabel(title)
            toggle.widthAnchor.constraint(equalToConstant: MenuSwitch.size.width).isActive = true
            toggle.heightAnchor.constraint(equalToConstant: MenuSwitch.size.height).isActive = true
        }
        return row
    }
}
