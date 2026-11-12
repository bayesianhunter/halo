// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class UniversalControlDeviceTests: XCTestCase {
    private func pad(_ sender: Int, name: String = "V-Apple Internal Keyboard / Trackpad", local: Bool = false,
                     transport: String = "SPI", trackpad: Bool = true) -> Device {
        Device(properties: ["sender": sender, "Product": name, "local": local, "Transport": transport, "touchpad": trackpad])
    }

    func testKnownTrackpadSurvivesEmptyHIDListDuringSameConnection() {
        let input = pad(1)
        var memory = UniversalControlDevices()
        memory.update([input], connected: true, session: "peer-a")
        memory.update([], connected: true, session: "peer-a")
        XCTAssertEqual(memory.displayed(alongside: [], connected: true), [input])
        var sources = SourceCatalog()
        sources.updateDevices([])
        XCTAssertFalse(sources.observe(sender: input.sender, continuous: true), "a displayed old sender never becomes a live scroll source")
    }

    func testNoRowInventedBeforeDeviceWasObserved() {
        var memory = UniversalControlDevices()
        memory.update([], connected: true, session: "peer-a")
        XCTAssertTrue(memory.displayed(alongside: [], connected: true).isEmpty)
    }

    func testStartupEvidenceSurvivesUntilConnectionReadCompletes() {
        let input = pad(1)
        var memory = UniversalControlDevices()
        memory.update([input], connected: nil, session: nil)
        XCTAssertTrue(memory.displayed(alongside: [], connected: nil).isEmpty)
        memory.update([], connected: true, session: "peer-a")
        XCTAssertEqual(memory.displayed(alongside: [], connected: true), [input])
    }

    func testDisconnectClearsRowsAndDoesNotReviveThemOnReconnect() {
        var memory = UniversalControlDevices()
        memory.update([pad(1)], connected: true, session: "peer-a")
        memory.update([], connected: false, session: "empty")
        memory.update([], connected: true, session: "peer-a")
        XCTAssertTrue(memory.displayed(alongside: [], connected: true).isEmpty)
    }

    func testNewSenderReplacesOldRow() {
        let first = pad(1), next = pad(2)
        var memory = UniversalControlDevices()
        memory.update([first], connected: true, session: "peer-a")
        memory.update([next], connected: true, session: "peer-a")
        XCTAssertEqual(memory.displayed(alongside: [next], connected: true), [next])
        XCTAssertEqual(memory.displayed(alongside: [], connected: true), [next])
    }

    func testPeerSetChangeCannotCarryOldDeviceIntoNewSession() {
        let first = pad(1), next = pad(2)
        var memory = UniversalControlDevices()
        memory.update([first], connected: true, session: "peer-a")
        memory.update([first], connected: true, session: "peer-b")
        memory.update([], connected: true, session: "peer-b")
        XCTAssertTrue(memory.displayed(alongside: [], connected: true).isEmpty)
        memory.update([next], connected: true, session: "peer-b")
        XCTAssertEqual(memory.displayed(alongside: [], connected: true), [next])
    }

    func testDuplicateAnonymousProfilesStayAmbiguous() {
        var memory = UniversalControlDevices()
        memory.update([pad(1), pad(2)], connected: true, session: "peer-a")
        memory.update([pad(1)], connected: true, session: "peer-a")
        XCTAssertTrue(memory.displayed(alongside: [], connected: true).isEmpty)
        XCTAssertEqual(memory.displayed(alongside: [pad(1)], connected: true), [pad(1)])
    }

    func testLocalDevicesAndUCHelperAreNeverRemembered() {
        var memory = UniversalControlDevices()
        memory.update([pad(1, local: true), pad(2, name: "V-UC Automouse", transport: "UniversalControl")], connected: true, session: "peer-a")
        XCTAssertTrue(memory.displayed(alongside: [], connected: true).isEmpty)
    }

    func testSelectingRememberedRowAppliesWhenNewSenderReturns() {
        let first = pad(1, name: "V-Fixture Mouse", trackpad: false), next = pad(2, name: "V-Fixture Mouse", trackpad: false)
        var memory = UniversalControlDevices()
        memory.update([first], connected: true, session: "peer-a")
        var livePolicy = Policy()
        livePolicy.updateDevices([])
        var selection = livePolicy
        selection.updateDevices(memory.displayed(alongside: [], connected: true))
        selection.setRule(.reverse, for: first, continuous: true)
        selection.setSpeed(2, for: first)
        livePolicy.rules = selection.rules
        livePolicy.speeds = selection.speeds
        livePolicy.updateDevices([next])
        XCTAssertEqual(livePolicy.rule(for: next, continuous: true), .reverse)
        XCTAssertEqual(livePolicy.speed(for: next), 2)
    }
}
