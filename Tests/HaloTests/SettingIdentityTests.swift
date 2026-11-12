// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class SettingIdentityTests: XCTestCase {
    private func device(_ sender: Int, name: String = "Desk Mouse", serial: String = "", local: Bool = true, trackpad: Bool = false) -> Device {
        Device(properties: ["sender": sender, "Product": name, "SerialNumber": serial, "local": local,
                            "Transport": "Bluetooth", "touchpad": trackpad])
    }

    func testDifferentSameNamedPhysicalDevicesDoNotShareSettings() {
        let a = device(1, serial: "fixture-a"), b = device(2, serial: "fixture-b")
        XCTAssertNil(SettingSync.localKey(for: a, among: [a, b]))
        XCTAssertNil(SettingSync.localKey(for: b, among: [a, b]))
        XCTAssertEqual(SettingSync.localKey(for: a, among: [a]), "own:desk mouse")
    }

    func testMultipleServicesOfOneSerializedDeviceStillMatch() {
        let a = device(1, serial: "fixture-a"), b = device(2, serial: "fixture-a")
        XCTAssertEqual(SettingSync.localKey(for: a, among: [a, b]), "own:desk mouse")
    }

    func testAnonymousSameNamedDevicesAreAmbiguous() {
        let a = device(1), b = device(2)
        XCTAssertNil(SettingSync.localKey(for: a, among: [a, b]))
        XCTAssertNil(SettingSync.localKey(for: a, among: []))
        let lent = device(3, name: "V-Desk Mouse", local: false)
        XCTAssertEqual(SettingSync.localKey(for: lent, among: [lent]), "borrowed:desk mouse")
    }

    func testBuiltInKeyboardCannotTakeTrackpadsReservedKey() {
        let pad = device(1, name: "Apple Internal Keyboard / Trackpad", trackpad: true)
        let service = device(2, name: "Apple Internal Keyboard / Trackpad", trackpad: true)
        let keyboard = device(3, name: "Apple Internal Keyboard")
        XCTAssertEqual(SettingSync.localKey(for: pad, among: [pad, service, keyboard]), "own:#built-in")
        XCTAssertNil(SettingSync.localKey(for: keyboard, among: [pad, service, keyboard]))
    }

    func testOldPeerCannotSendOneSettingForTwoSameNamedDevices() {
        let row = LinkDevice(name: "Desk Mouse", kind: .mouse, battery: nil, reversed: false, pointing: true)
        let setting = LinkSetting(name: "Desk Mouse", builtIn: false, own: true, reversed: true, reversedChanged: Date())
        var snapshot = LinkSnapshot(computer: "Fixture", active: true, devices: [row, row], settings: [setting])
        XCTAssertTrue(snapshot.matchableSettings.isEmpty)
        snapshot.devices = [row]
        XCTAssertEqual(snapshot.matchableSettings, [setting])
    }

    func testDuplicatedIncomingSettingsDoNotPickAnArbitraryOne() {
        let now = Date()
        let a = LinkSetting(name: "Desk Mouse", builtIn: false, own: true, reversed: true, reversedChanged: now)
        let b = LinkSetting(name: "Desk Mouse", builtIn: false, own: true, reversed: false, reversedChanged: now)
        XCTAssertTrue(SettingSync.newer([a, b], than: [:], now: now).isEmpty)
        XCTAssertEqual(SettingSync.newer([a], than: [:], now: now).count, 1)
    }
}
