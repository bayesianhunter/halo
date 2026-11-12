// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Sparkle

/// Updates for a Halo installed from the download (Homebrew upgrades its own copies the same way, through this).
///
/// Sparkle is the only part of Halo that downloads and runs code, which is acceptable only because `SUPublicEDKey` in
/// Info.plist makes it reject anything not signed with Halo's own update key. Gatekeeper alone would not: anyone can
/// notarize a replacement under their own Developer ID.
///
/// `SUEnableAutomaticChecks` is deliberately absent, so Sparkle asks once (on the second launch) whether to check on
/// its own; until the person says yes nothing goes out except a check they start. When they agree, Sparkle looks once
/// a day, on its own schedule, not on a timer of Halo's.
///
/// An update found by that daily check is not put in a window of its own: Halo lives in the menu bar, and a window
/// opened while someone works in another app lands behind it, unseen for days. Halo marks it instead (the dot of the
/// menu-bar mark and a line in its menu, Sparkle's "gentle reminders") and the window opens when that line is chosen.
/// Right after launch, when Sparkle would show it in front anyway, Sparkle shows it.
final class Updates: NSObject {
    private var controller: SPUStandardUpdaterController?
    /// The version of an update found in the background that the person has not looked at yet.
    private(set) var waiting: String?
    /// The mark or the menu has something to show or to stop showing.
    var onChange: (() -> Void)?

    /// Only the app in a bundle updates: not a command-line mode, not a test run with its own state folder.
    static var applies: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && !CommandLine.arguments.contains("--smoke")
            && ProcessInfo.processInfo.environment["HALO_STATE_DIR"] == nil
    }

    func start() {
        guard Self.applies, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var available: Bool { controller != nil }

    /// A check the person asked for: Sparkle shows its own window, including "you're up to date".
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Menu items stay dimmed while a check is already under way, as Sparkle's own item does.
    func validate(_ item: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        waiting = update.displayVersionString
        onChange?()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { looked() }

    func standardUserDriverWillFinishUpdateSession() { looked() }

    private func looked() {
        guard waiting != nil else { return }
        waiting = nil
        onChange?()
    }
}

extension Updates: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}
