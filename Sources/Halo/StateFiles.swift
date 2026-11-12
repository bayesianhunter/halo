// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import HaloCore

/// Loads the app's state files from `stateURL`. A damaged one is kept aside (see `StateFile`), logged, and named on
/// the Diagnostics page and in the export, so settings that went back to their defaults never do so unexplained.
/// Main thread. The app and the `--peer` test harness load through here; the other command-line modes read state
/// files without moving anything.
enum StateFiles {
    /// What went wrong loading, for the Diagnostics page and export, for as long as Halo runs.
    private(set) static var problems: [String] = []
    /// Files left in place that must not be saved over this run.
    private static var keepAsIs: Set<String> = []

    /// Whether `name` may be written: false for a file that could not be read and is still in place.
    static func mayWrite(_ name: String) -> Bool { !keepAsIs.contains(name) }

    static func load<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        loadSalvaging(type, name).value
    }

    /// The value, and on failure the bytes that were there, for a caller that can salvage part of them.
    static func loadSalvaging<Value: Decodable>(_ type: Value.Type, _ name: String) -> (value: Value?, damaged: Data?) {
        switch StateFile.load(type, from: stateURL.appendingPathComponent(name)) {
        case .absent:
            return (nil, nil)
        case .loaded(let value):
            return (value, nil)
        case .unreadable(let data, let kept):
            report(name, keptAs: kept)
            return (nil, data)
        }
    }

    /// Logs a state file that could not be read and keeps the notice for the Diagnostics page.
    /// `salvaged`: what mattered in it still read (the link's ID and pairing), so its settings did not go back.
    static func report(_ name: String, keptAs kept: String?, salvaged: Bool = false) {
        if kept == nil { keepAsIs.insert(name) }
        Events.app("state-unreadable", detail: (kept.map { "\(name) kept as \($0)" } ?? "\(name) left in place, not saved over")
                   + (salvaged ? "; ID and pairing salvaged" : ""))
        if salvaged {
            problems.append(L("%@ couldn’t be read; this Mac’s ID and pairing were recovered", name))
        } else {
            problems.append(kept.map { L("%@ couldn’t be read and was kept as %@; its settings are back to their defaults for now", name, $0) }
                            ?? L("%@ couldn’t be read and is left as it is, not saved over; its settings are back to their defaults for now", name))
        }
    }
}
