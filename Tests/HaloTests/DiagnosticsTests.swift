// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CryptoKit
@testable import HaloCore

/// The diagnostics export: what an agent reads back, what it is told is missing, and what never goes in.
final class DiagnosticsTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_793_600_000.25)
    let key = SymmetricKey(size: .bits256)

    func report(source: String = "live", recording: Bool = false) -> DiagnosticsReport {
        var report = DiagnosticsReport(source: source, app: .init(version: "0.5.0", build: "10", macOS: "macOS 27.2 (26B123)", language: "en",
                                                                  exportedAt: at, uptime: 5000),
                                       state: .init(appRunning: true, accessibility: true, recordScrolls: recording, showIcon: true))
        let mouse = Device(properties: ["sender": NSNumber(value: 0x2a), "Product": "Test Mouse", "Transport": "Bluetooth Low Energy",
                                        "SerialNumber": "aa:bb:cc:dd:ee:ff"])
        var policy = Policy()
        policy.setRule(.reverse, for: mouse, continuous: false)
        policy.updateDevices([mouse])
        report.devices = [.init(mouse, displayName: "Test Mouse", policy: policy, idKey: key, wheelScrolls: 3)]
        if source == "live" {
            report.scrolls = recording ? [.init(at: at, uptime: 4999, sender: 0x2a, device: "Test Mouse", continuous: false,
                                                input: 1, output: -1, phase: 0, momentum: 0, reversed: true)] : []
            report.audioDevices = [.init(name: "Speaker", address: "AA:BB:CC:DD:EE:04", idKey: key, speaker: true, output: true, input: false,
                                         callQuality: false, micInUseBy: nil, micRule: true, battery: 46, rssi: nil)]
            report.audioEvents = []
        }
        report.notes = report.gaps()
        return report
    }

    func testRoundTripsWithMilliseconds() throws {
        let original = report(recording: true)
        let data = try DiagnosticsReport.encoder.encode(original)
        XCTAssertEqual(try DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: data), original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 1"))
    }

    func testShowsTheDevicesPageAsItReads() throws {
        var live = report()
        live.page = .init(windowOpen: true, firstLaunch: true, pairing: "idle",
                          rows: [.init(title: "Built-in Trackpad", facts: [], battery: nil, on: false, speed: nil)],
                          notes: [], pairCard: .init(title: "Another Mac Connected", detail: "Install Halo on it too", button: "Pair…"),
                          universalControlRows: [.init(title: "MX Master 2S", facts: [], battery: nil, on: true, speed: 1, lent: true)],
                          peerTitle: nil, peerRows: nil, peerNote: nil)
        var text = live.markdown
        XCTAssertTrue(text.contains("## Devices page"))
        XCTAssertTrue(text.contains("first launch yes · pairing idle"))
        XCTAssertTrue(text.contains("- Built-in Trackpad · reverse off\n- Universal Control:\n  - MX Master 2S · lent here · reverse on · speed 1×\n"
                                    + "  - Card: Another Mac Connected · Install Halo on it too · [Pair…]"), text)
        // Paired: the lent mouse is listed once, in its place among the other Mac's devices, with this Mac's switch.
        var paired = live
        paired.page = .init(windowOpen: false, firstLaunch: false, pairing: "idle",
                            rows: [.init(title: "Built-in Trackpad", facts: [], battery: nil, on: false, speed: nil)],
                            notes: [], pairCard: nil, peerTitle: "Other Mac",
                            peerRows: [.init(title: "Built-in Trackpad", facts: [], battery: nil, on: nil, speed: nil),
                                       .init(title: "MX Master 2S", facts: ["Reversed on Other Mac"], battery: 50, on: false, speed: 1, lent: true)],
                            peerNote: nil)
        text = paired.markdown
        XCTAssertFalse(text.contains("- Universal Control:"))
        XCTAssertTrue(text.contains("- Other Mac:\n  - Built-in Trackpad\n  - MX Master 2S · Reversed on Other Mac · lent here · 50% · reverse off"), text)
        XCTAssertEqual(try DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: DiagnosticsReport.encoder.encode(paired)), paired)
        XCTAssertEqual(try DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: DiagnosticsReport.encoder.encode(live)), live)
        // A report without the page reads back without it.
        XCTAssertNil(try DiagnosticsReport.decoder.decode(DiagnosticsReport.self, from: DiagnosticsReport.encoder.encode(report())).page)
    }

    /// No program is judged by its name: the export says only whether a tap can modify scrolling.
    func testScrollToolsCarryNoNameBasedVerdict() throws {
        var current = report()
        current.scrollTools = [.init(name: "Some Reverser", bundleID: "com.example.reverser", modifies: true, isHalo: false)]
        let text = String(decoding: try DiagnosticsReport.encoder.encode(current), as: UTF8.self)
        XCTAssertFalse(text.contains("reverser\" :"))
        XCTAssertFalse(text.contains("pausedForConflict"))
        XCTAssertTrue(current.markdown.contains("Some Reverser (com.example.reverser): can modify scrolling"))
    }

    func testNoSerialOrAddress() throws {
        let text = String(decoding: try DiagnosticsReport.encoder.encode(report(recording: true)), as: UTF8.self) + report().markdown
        XCTAssertFalse(text.lowercased().contains("aa:bb:cc"))
        XCTAssertFalse(text.lowercased().contains("aa:bb:cc:dd:ee"))
        let speaker = { (address: String, key: SymmetricKey) in
            DiagnosticsReport.AudioDeviceEntry(name: "S", address: address, idKey: key, speaker: true, output: false, input: false,
                                               callQuality: false, micInUseBy: nil, micRule: nil, battery: nil, rssi: nil).id
        }
        XCTAssertEqual(speaker("AA:BB:CC:DD:EE:04", key), speaker("aa-bb-cc-dd-ee-04", key))
        XCTAssertEqual(speaker("aa:bb:cc:dd:ee:04", key).count, 8)
        XCTAssertNotEqual(speaker("aa:bb:cc:dd:ee:04", key), speaker("aa:bb:cc:dd:ee:04", SymmetricKey(size: .bits256)),
                          "ids are keyed per Mac, so they cannot be hashed back from a shared export")
    }

    func testSaysWhatIsMissing() {
        let off = report().notes
        XCTAssertTrue(off.contains { $0.hasPrefix("No scrolls recorded") && $0.contains("--diagnostics --record 30") },
                      "a gap names the command that fills it")
        XCTAssertTrue(off.contains { $0.hasPrefix("Not paired") })
        XCTAssertTrue(off.contains { $0.hasPrefix("The audio link has not been checked") && $0.contains("--audio-check") })
        XCTAssertFalse(report(recording: true).notes.contains { $0.hasPrefix("No scrolls") })
        var quiet = report()
        quiet.request = .init(kind: "record", startedAt: at, endedAt: at.addingTimeInterval(5), seconds: 5, result: "0 scrolls arrived")
        XCTAssertTrue(quiet.gaps().contains { $0.hasPrefix("Nothing scrolled during the 5 s recording") })
        XCTAssertTrue(quiet.markdown.contains("**This export:** a 5 s scroll recording"))
        let cold = report(source: "cold").notes
        XCTAssertTrue(cold[0].hasPrefix("Halo is running but did not answer"))
        XCTAssertFalse(cold.contains { $0.hasPrefix("No scrolls") }, "a cold export says once that live state is missing")
    }

    func testSummary() {
        let text = report(recording: true).markdown
        XCTAssertTrue(text.contains("| Test Mouse | Test Mouse |"))
        XCTAssertTrue(text.contains("| reverse | unchanged | 1× | 3 wheel |"))
        XCTAssertTrue(text.contains("- Test Mouse: 1 wheel (1 reversed, 0 passed)"), "scrolls are summed up per device")
        XCTAssertTrue(text.contains("## Missing or empty"))
        XCTAssertTrue(text.contains("Speaker ["))
        XCTAssertTrue(text.contains("1 kept, "))
    }
}
