// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Halo's state folder: `HALO_STATE_DIR` when set (tests, `--peer`), otherwise Application Support/Halo. A global
/// outside `main.swift` is set up lazily and once, on first use.
let stateURL = ProcessInfo.processInfo.environment["HALO_STATE_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Halo", isDirectory: true)
