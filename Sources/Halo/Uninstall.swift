// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import ServiceManagement

/// Uninstall Halo… in Settings: lists everything Halo put on this Mac, and on the person's word takes it all away,
/// then quits. Files go to the Trash; the pairing key is deleted with the pairing, as Unpair does, and the other Mac is
/// told. macOS keeps its own privacy lists; Halo opens Accessibility so the person can remove it there.
extension AppDelegate {
    /// Only the installed app, with its own state: a copy run from a build folder or with `HALO_STATE_DIR` (tests,
    /// `--peer`) is not the one whose files these are.
    static var canUninstall: Bool {
        Bundle.main.bundleIdentifier == Footprint.bundleID && Bundle.main.bundleURL.pathExtension == "app"
            && ProcessInfo.processInfo.environment["HALO_STATE_DIR"] == nil
    }

    static var footprint: Footprint { Footprint(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// Installed by Homebrew, which keeps its own record of the app: then `brew` removes the app, not Halo.
    static var homebrew: Bool {
        ["/opt/homebrew/Caskroom/halo", "/usr/local/Caskroom/halo"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Registered to open at login, also when switched off in System Settings, where it waits for approval.
    static var loginItemRegistered: Bool { SMAppService.mainApp.status != .notRegistered }

    /// What Uninstall would take away, one line each, as the confirmation lists it.
    func uninstallList() -> [String] {
        let footprint = Self.footprint
        var lines: [String] = []
        if let peer = link.peer {
            lines.append(L("The pairing with %@ and its key in the keychain (deleted, not moved to the Trash)", peer.name))
            if !link.online { lines.append(L("%@ is offline, so it keeps its side: unpair it there too", peer.name)) }
        }
        if Self.loginItemRegistered { lines.append(L("Open at Login")) }
        lines += footprint.present().map(footprint.shown)
        lines.append(Self.homebrew ? L("The app: remove it afterwards with brew uninstall --cask halo")
                                   : footprint.shown(Bundle.main.bundleURL))
        return lines
    }

    @objc func uninstallHalo() {
        guard Self.canUninstall else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Uninstall Halo?")
        alert.informativeText = L("Halo removes all of this, then quits. Files go to the Trash.")
            + "\n\n" + L("macOS keeps its own lists in Privacy & Security and Notifications; Halo opens Privacy & Security so you can remove Halo there too.")
        let list = NSTextField(wrappingLabelWithString: uninstallList().map { "• " + $0 }.joined(separator: "\n"))
        list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        list.textColor = .secondaryLabelColor
        list.isSelectable = true
        list.preferredMaxLayoutWidth = 300
        list.frame.size = list.fittingSize
        alert.accessoryView = list
        alert.addButton(withTitle: L("Uninstall")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performUninstall()
        }
    }

    /// Unpairs first, so the other Mac hears it over the link while the link is still here, then takes the rest away.
    private func performUninstall() {
        window.orderOut(nil)
        if link.peer != nil { link.unpair() }
        // A pairing under way may already hold a key in the keychain; ending the attempt deletes it, as quitting does.
        link.cancelPairing()
        var failed: [String] = []
        if Self.loginItemRegistered {
            do { try SMAppService.mainApp.unregister() } catch { failed.append(L("Open at Login")) }
        }
        // The unpair message leaves in the background, within the 2 seconds the link itself allows it; a Mac that is
        // offline keeps its side until someone unpairs it there, as with Unpair.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finishUninstall(failed: failed) }
    }

    /// cfprefsd writes the emptied preferences back as a new, empty file at its next periodic flush after the old one
    /// went to the Trash, whether or not Halo is still running: measured anywhere from 1.5 to 15 s later on macOS 27.2.
    /// So Halo waits for it, up to 20 s, out of sight (its menu-bar item gone), and deletes the file only when it is
    /// that empty dictionary; one with anything in it stays.
    private func removeRewrittenPreferences() {
        NSStatusBar.system.removeStatusItem(statusItem)
        let file = Self.footprint.home.appendingPathComponent("Library/Preferences/\(Footprint.bundleID).plist")
        let deadline = DispatchTime.now() + .seconds(20)
        while DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            guard let data = try? Data(contentsOf: file) else { continue }
            if (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?.isEmpty == true {
                try? FileManager.default.removeItem(at: file)
            }
            return
        }
    }

    private func finishUninstall(failed: [String]) {
        var failed = failed
        let footprint = Self.footprint
        eventLog.stop()
        do { try AgentSkill.remove() } catch { failed += footprint.ownSkillLinks().map(footprint.shown) }
        UserDefaults.standard.removePersistentDomain(forName: Footprint.bundleID)
        CFPreferencesAppSynchronize(Footprint.bundleID as CFString)
        let trash = { (url: URL) throws in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        failed += footprint.remove(footprint.present(), trash: trash).map(footprint.shown)
        if !Self.homebrew { failed += footprint.remove([Bundle.main.bundleURL], trash: trash).map(footprint.shown) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        if !failed.isEmpty {
            // Said, not swallowed: the confirmation promised all of it.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Halo couldn’t remove everything")
            alert.informativeText = L("These are still here; remove them in Finder or System Settings:") + "\n\n"
                + failed.map { "• " + $0 }.joined(separator: "\n")
            NSApp.activate()
            alert.runModal()
        }
        removeRewrittenPreferences()
        // At once: quitting the usual way would save settings, window state and Sparkle's last check again.
        exit(0)
    }
}

/// `Halo --uninstall`: what Halo put on this Mac, for a person or their agent to see. It removes nothing; Uninstall
/// Halo… in Settings does, after the person confirms, and tells a paired Mac.
enum UninstallList {
    static func run() -> Int32 {
        let footprint = AppDelegate.footprint
        var lines = footprint.present().map(footprint.shown)
        let state = stateURL.appendingPathComponent("link.json")
        if let data = try? Data(contentsOf: state),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let peer = object["peer"] as? [String: Any], let name = peer["name"] as? String {
            lines.insert("Pairing with \(name), and its key in the login keychain", at: 0)
        }
        if Bundle.main.bundleURL.pathExtension == "app", AppDelegate.loginItemRegistered { lines.insert("Open at Login", at: 0) }
        if AppDelegate.homebrew, Bundle.main.bundleURL.pathExtension == "app" {
            lines.append("The app, installed with Homebrew")
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            lines.append(footprint.shown(Bundle.main.bundleURL))
        }
        print("Halo has put these on this Mac:")
        lines.forEach { print("  \($0)") }
        print("""

            Nothing was removed. To remove all of it, open Halo > Settings > General > Uninstall Halo…: it lists the
            same, unpairs (telling the other Mac if it is connected), moves the files to the Trash and quits.\(AppDelegate.homebrew ? " Then run: brew uninstall --cask halo" : "")
            macOS keeps Halo in Privacy & Security (Accessibility, Bluetooth, Local Network) and in Notifications until
            it is removed there.
            """)
        return 0
    }
}
