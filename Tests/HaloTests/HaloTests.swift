// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CoreGraphics
@testable import HaloHID
@testable import HaloCore

final class HaloTests: XCTestCase {
    func device(_ sender: UInt64, _ extra: [String: Any] = [:]) -> Device {
        Device(properties: ["sender": NSNumber(value: sender), "Product": "Test",
                            "Transport": "USB", "local": true].merging(extra) { _, b in b })
    }

    /// The tap's quick lookup must name a device exactly as the full listing does, or a rule saved from the menu
    /// would not apply to the first scroll after a reconnect or a Universal Control handoff. Checks the devices
    /// present on the Mac running the tests, Universal Control ones included.
    func testQuickLookupMatchesFullListing() throws {
        let listed = HaloHID.devices().map(Device.init(properties:))
        try XCTSkipIf(listed.isEmpty, "no scrolling device on this Mac")
        HaloHID.prepareLookup()
        var slowest: UInt64 = 0
        for device in listed {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = HaloHID.device(sender: device.sender)
            slowest = max(slowest, DispatchTime.now().uptimeNanoseconds - start)
            let quick = try XCTUnwrap(found.map(Device.init(properties:)), device.name)
            XCTAssertEqual(quick.key, device.key, device.name)
            XCTAssertEqual(quick.profileKey, device.profileKey, device.name)
            XCTAssertEqual(quick.trackpad, device.trackpad, device.name)
        }
        print("quick lookup: \(listed.count) devices (\(listed.filter { !$0.local }.count) via Universal Control), slowest \(slowest / 1000) µs")
        XCTAssertNil(HaloHID.device(sender: 0))
    }

    func testUnknownInputNeverInheritsPreviousMouseRule() {
        let mouse = device(1)
        let trackpad = device(2, ["HIDScrollAccelerationType": "HIDTrackpadScrollAcceleration"])
        var policy = Policy()
        policy.enabled = true
        policy.rules[mouse.sourceKey(continuous: false)] = .reverse
        for _ in 0..<1000 {
            XCTAssertTrue(policy.shouldReverse(device: mouse, continuous: false))
            XCTAssertFalse(policy.shouldReverse(device: nil, continuous: true))
            XCTAssertFalse(policy.shouldReverse(device: trackpad, continuous: true))
        }
    }

    func testUniversalControlAndLocalDeviceHaveIndependentRules() {
        let mouse = device(1)
        let remote = device(2, ["local": false, "Transport": "UniversalControl"])
        var policy = Policy()
        policy.enabled = true
        policy.rules[mouse.sourceKey(continuous: false)] = .reverse
        XCTAssertNotEqual(mouse.key, remote.key)
        XCTAssertFalse(policy.shouldReverse(device: remote, continuous: true))
        policy.rules[remote.sourceKey(continuous: true)] = .reverse
        XCTAssertTrue(policy.shouldReverse(device: remote, continuous: true))
        XCTAssertFalse(policy.shouldReverse(device: remote, continuous: false))
        policy.enabled = false
        XCTAssertFalse(policy.shouldReverse(device: mouse, continuous: false))
    }

    func testSessionKeysRemainDistinctWithoutSerial() {
        XCTAssertNotEqual(device(1).key, device(2).key)
        XCTAssertTrue(device(1).sessionOnly)
        let first = device(1, ["SerialNumber": "ABC"])
        let reconnected = device(2, ["SerialNumber": "ABC"])
        XCTAssertEqual(first.key, reconnected.key)
        XCTAssertFalse(first.sessionOnly)
        XCTAssertNotEqual(first.key, device(3, ["SerialNumber": "DEF"]).key)
    }

    func testExistingRuleSurvivesReconnectAndReloadWithoutTouchingTrackpad() throws {
        let mouse = device(1)
        let reconnected = device(2)
        let trackpad = device(3, ["HIDScrollAccelerationType": "HIDTrackpadScrollAcceleration"])
        var policy = Policy()
        policy.rules[mouse.sourceKey(continuous: false)] = .reverse
        XCTAssertTrue(policy.updateDevices([mouse, trackpad]))
        policy.enabled = true
        policy.updateDevices([reconnected, trackpad])
        XCTAssertTrue(policy.shouldReverse(device: reconnected, continuous: false))
        XCTAssertFalse(policy.shouldReverse(device: reconnected, continuous: true))
        XCTAssertFalse(policy.shouldReverse(device: trackpad, continuous: true))
        XCTAssertFalse(policy.shouldReverse(device: nil, continuous: false))

        var restarted = Policy()
        restarted.rules = try JSONDecoder().decode([String: ScrollRule].self,
            from: JSONEncoder().encode(policy.rules))
        let anotherSession = device(4)
        restarted.updateDevices([anotherSession, trackpad])
        XCTAssertFalse(restarted.shouldReverse(device: anotherSession, continuous: false))
        restarted.enabled = true
        XCTAssertTrue(restarted.shouldReverse(device: anotherSession, continuous: false))
        for other in [device(5, ["Product": "Other"]), device(6, ["Transport": "Bluetooth"]),
                      device(7, ["VendorID": 1]), device(8, ["ProductID": 1]), device(9, ["local": false])] {
            restarted.updateDevices([other])
            XCTAssertFalse(restarted.shouldReverse(device: other, continuous: false))
        }
    }

    /// A mouse without a serial number that drops out of the listing and comes back under a new sender is looked up
    /// by the tap before the next listing; its first scroll must already follow its rule and speed.
    func testUnlistedNewSenderFollowsItsProfile() {
        let mouse = device(1)
        var policy = Policy()
        policy.enabled = true
        policy.updateDevices([mouse])
        policy.setRule(.reverse, for: mouse, continuous: false)
        policy.setSpeed(2, for: mouse)
        policy.updateDevices([])
        let back = device(2)
        XCTAssertEqual(policy.factor(device: back, continuous: false), -2)
        XCTAssertEqual(policy.factor(device: device(3, ["Product": "Other"]), continuous: false), 1)
    }

    func testIndistinguishableConnectedSourcesNeedSessionSelection() {
        let first = device(1)
        let second = device(2)
        var policy = Policy()
        policy.enabled = true
        policy.updateDevices([first])
        policy.setRule(.reverse, for: first, continuous: false)
        policy.updateDevices([first, second])
        XCTAssertTrue(policy.shouldReverse(device: first, continuous: false))
        XCTAssertFalse(policy.shouldReverse(device: second, continuous: false))
        policy.setRule(.unchanged, for: second, continuous: false)
        policy.updateDevices([second])
        XCTAssertFalse(policy.shouldReverse(device: second, continuous: false))
        policy.updateDevices([device(3)])
        XCTAssertFalse(policy.shouldReverse(device: device(3), continuous: false))
    }

    func testSourceTableDropsDisconnectedSenderAndKeepsOtherSources() {
        let first = device(1)
        let reconnected = device(2)
        let trackpad = device(3, ["HIDScrollAccelerationType": "HIDTrackpadScrollAcceleration"])
        var catalog = SourceCatalog()
        catalog.updateDevices([first, trackpad])
        catalog.observe(sender: first.sender, continuous: false)
        catalog.observe(sender: trackpad.sender, continuous: true)
        XCTAssertEqual(catalog.sightings.count, 2)
        catalog.updateDevices([reconnected, trackpad])
        XCTAssertNil(catalog.sightings[first.sourceKey(continuous: false)])
        XCTAssertNotNil(catalog.sightings[trackpad.sourceKey(continuous: true)])
        catalog.observe(sender: first.sender, continuous: false)
        XCTAssertEqual(catalog.sightings.count, 1)
        XCTAssertFalse(catalog.observe(sender: first.sender, continuous: false), "a sender no longer listed is not news")
        XCTAssertTrue(catalog.observe(sender: reconnected.sender, continuous: false), "the first scroll of its kind is news")
        XCTAssertFalse(catalog.observe(sender: reconnected.sender, continuous: false))
        XCTAssertEqual(catalog.sightings.count, 2)
        XCTAssertEqual(catalog.sightings[reconnected.sourceKey(continuous: false)]?.count, 2)
        let revision = catalog.revision
        catalog.updateDevices([reconnected, trackpad])
        XCTAssertEqual(catalog.revision, revision)
    }

    func testBatteryParsingAndLowestLowCharge() {
        XCTAssertNil(Battery(properties: ["Product": "No charge"]))
        XCTAssertNil(Battery(properties: ["percent": NSNumber(value: 140)]))
        let pad = Battery(properties: ["percent": NSNumber(value: 76), "Product": "Magic Trackpad", "SerialNumber": "04:4B"])
        let keyboard = Battery(properties: ["percent": NSNumber(value: 12), "Product": "Keyboard"])
        let mouse = Battery(properties: ["percent": NSNumber(value: 20), "Product": "Mouse"])
        XCTAssertEqual(pad?.name, "Magic Trackpad")
        XCTAssertEqual(pad?.serial, "04:4B")
        XCTAssertNil(Battery.lowest([pad!]))
        XCTAssertEqual(Battery.lowest([pad!, mouse!, keyboard!])?.name, "Keyboard")
        XCTAssertTrue(mouse!.isLow)
    }

    /// The plug drawn beside a charging Apple accessory follows its product ID: USB-C from 0x0320 on, Lightning below.
    func testTheChargingPlugFollowsTheModel() {
        XCTAssertEqual(Battery.connector(vendor: 0x004C, product: 0x0323), .usbC, "Magic Mouse, USB-C, over Bluetooth")
        XCTAssertEqual(Battery.connector(vendor: 0x05AC, product: 0x0320), .usbC, "Magic Keyboard, USB-C, over USB")
        XCTAssertEqual(Battery.connector(vendor: 0x004C, product: 0x0269), .lightning, "Magic Mouse 2")
        XCTAssertNil(Battery.connector(vendor: 0x046D, product: 0x0323), "not Apple's: no guess")
        XCTAssertNil(Battery.connector(vendor: 0x004C, product: 0))
        XCTAssertNil(Battery.connector(vendor: nil, product: 0x0323))
        let reading = Battery(properties: ["percent": NSNumber(value: 40), "VendorID": NSNumber(value: 0x004C), "ProductID": NSNumber(value: 0x0324)])
        XCTAssertEqual(reading?.connector, .usbC)
    }

    func testBluetoothLEBatteriesFillOnlyDevicesTheRegistryMisses() {
        let pad = Battery(name: "Magic Trackpad", serial: "04:4B", percent: 76)
        let merged = Battery.merge([pad], [Battery(name: "magic trackpad", serial: "", percent: 70),
                                           Battery(name: "MX Master 2S", serial: "", percent: 90)])
        XCTAssertEqual(merged.map(\.name), ["Magic Trackpad", "MX Master 2S"])
        XCTAssertEqual(merged.first?.percent, 76)
        XCTAssertEqual(Battery(name: "x", serial: "", percent: 130).percent, 100)
    }

    /// Two devices of the same name keep apart in the log; a reading without a serial joins the one serial its name has
    /// in the registry's current list, and the lines logged by name before still count while the name is unique.
    func testSameNamedBatteriesAreLoggedApart() {
        var serials = BatterySerials()
        let one = Battery(name: "Magic Mouse", serial: "AA", percent: 50), two = Battery(name: "Magic Mouse", serial: "BB", percent: 80)
        let ble = Battery(name: "magic mouse", serial: "", percent: 50)
        XCTAssertNotEqual(serials.key(for: one), serials.key(for: two))
        XCTAssertEqual(serials.key(for: Battery(name: "Magic Mouse", serial: " aa", percent: 50)), serials.key(for: one), "case and spaces aside")
        XCTAssertEqual(serials.key(for: ble), "battery|magic mouse", "nothing read from the registry yet: by name")
        serials.update([one])
        XCTAssertEqual(serials.key(for: ble), serials.key(for: one))
        XCTAssertEqual(serials.keys(for: one, among: [one]), [serials.key(for: one), "battery|magic mouse"], "its lines from before count")
        XCTAssertEqual(serials.keys(for: one, among: [one, two]), [serials.key(for: one)], "two of that name: the old lines are a mix")
        serials.update([one, two])
        XCTAssertEqual(serials.key(for: ble), "battery|magic mouse", "two serials for the name: which one is unknown")
        serials.update([])
        XCTAssertEqual(serials.key(for: ble), "battery|magic mouse", "a mouse the registry no longer lists lends its serial to no one")
        XCTAssertEqual(serials.keys(for: ble, among: [ble]), ["battery|magic mouse"])
    }

    /// The system behaviour the reversal order rests on, measured rather than assumed: writing the line delta
    /// recomputes the fixed-point (×1) and pixel (×8) deltas, while writing either of those leaves the rest alone.
    /// If a macOS release changes this, this test says so before scrolling goes wrong.
    func testWritingTheLineDeltaRecomputesTheOthers() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -point)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -3)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -3 * 8)
        XCTAssertNotEqual(-3 * 8, -point, "the device's own pixel delta is lost unless written back after the line delta")
    }

    /// A trackpad's scroll can arrive nested inside another HID event; only the scroll value may change.
    func testEmbeddedScrollReversesEvenWhenNested() throws {
        typealias Make = @convention(c) (CFAllocator?, UInt64, Double, Double, Double, UInt32) -> Unmanaged<CFTypeRef>?
        typealias Append = @convention(c) (CFTypeRef, CFTypeRef) -> Void
        typealias Get = @convention(c) (CFTypeRef, UInt32) -> Double
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard HaloHID.available,
              let makeScroll = dlsym(handle, "IOHIDEventCreateScrollEvent").map({ unsafeBitCast($0, to: Make.self) }),
              let makeTranslation = dlsym(handle, "IOHIDEventCreateTranslationEvent").map({ unsafeBitCast($0, to: Make.self) }),
              let append = dlsym(handle, "IOHIDEventAppendEvent").map({ unsafeBitCast($0, to: Append.self) }),
              let get = dlsym(handle, "IOHIDEventGetFloatValue").map({ unsafeBitCast($0, to: Get.self) }) else {
            throw XCTSkip("HID event functions unavailable")
        }
        let translationY: UInt32 = (4 << 16) | 1
        let plain = try XCTUnwrap(makeScroll(nil, 0, 0, 5, 0, 0)?.takeRetainedValue())
        XCTAssertTrue(HaloHID.reverseEmbedded(plain))
        XCTAssertEqual(get(plain, HaloHID.scrollY), -5)

        let parent = try XCTUnwrap(makeTranslation(nil, 0, 0.25, 0.75, 0, 0)?.takeRetainedValue())
        let child = try XCTUnwrap(makeScroll(nil, 0, 0, 5, 0, 0)?.takeRetainedValue())
        append(parent, child)
        XCTAssertTrue(HaloHID.reverseEmbedded(parent))
        XCTAssertEqual(get(parent, HaloHID.scrollY), -5)
        XCTAssertEqual(get(parent, translationY), 0.75, "the enclosing gesture's own value stays as it was")
    }

    /// Saved rules are keyed by this hash; a change to the identity fields would silently orphan every rule.
    func testDeviceIdentityIsStable() {
        let mouse = Device(properties: ["sender": NSNumber(value: 7), "Product": "MX Master 2S", "Transport": "Bluetooth Low Energy",
                                        "VendorID": NSNumber(value: 1133), "ProductID": NSNumber(value: 45081), "local": true,
                                        "HIDScrollAccelerationType": "HIDMouseScrollAcceleration", "SerialNumber": "aa:bb:cc:dd:ee:03"])
        XCTAssertEqual(mouse.key, "80b20307224fa92abe7b45a1289e9f4a672c9fc69277c82515921be43ec3e2ac")
        XCTAssertTrue(mouse.local)
        XCTAssertFalse(mouse.trackpad)
        let pad = Device(properties: ["sender": NSNumber(value: 8), "Product": "Magic Trackpad", "local": true, "touchpad": true])
        XCTAssertTrue(pad.local)
        XCTAssertTrue(pad.trackpad)
        let remote = Device(properties: ["sender": NSNumber(value: 9), "Product": "V-Trackpad", "local": false, "touchpad": NSNumber(value: true)])
        XCTAssertFalse(remote.local)
        XCTAssertTrue(remote.trackpad)
    }

    /// The shown name of an unnamed device follows the language; its identity, and so its saved rules, does not.
    func testUnnamedDeviceIdentityIgnoresDisplayName() {
        let saved = Device.unnamed
        defer { Device.unnamed = saved }
        let before = Device(properties: ["sender": NSNumber(value: 1), "Transport": "USB", "local": true, "SerialNumber": "A"])
        Device.unnamed = "Unnamed Device"
        let after = Device(properties: ["sender": NSNumber(value: 1), "Transport": "USB", "local": true, "SerialNumber": "A"])
        XCTAssertEqual(after.name, "Unnamed Device")
        XCTAssertEqual(Battery(properties: ["percent": NSNumber(value: 50)])?.name, "Unnamed Device")
        // Hashed with the placeholder unnamed devices have always had, so rules saved before localization still apply.
        XCTAssertEqual(before.key, "e69dc05802c4a3ea6f661037744dfa896099c30e6da681de9e1ee6c3b05c0451")
        XCTAssertEqual(before.key, after.key)
        XCTAssertEqual(before.profileKey, after.profileKey)
    }

    func testScrollRepresentationsReverseTogetherAndHorizontalIsPreserved() throws {
        guard HaloHID.available else { throw XCTSkip("Required SPI unavailable") }
        for y: Int32 in [-120, -1, 0, 1, 120] {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                             wheel1: y, wheel2: 17, wheel3: 0))
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let x = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
            XCTAssertTrue(HaloHID.reverseVertical(event))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -lines)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -points)
            XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -fixed)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), x)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 4)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 2)
            XCTAssertTrue(HaloHID.reverseVertical(event))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), points)
        }
    }

    /// Replays the representation mismatch captured with a UC mouse in iPhone Mirroring: the ordinary deltas
    /// were reversed, but the raw and accelerated values still described the original direction.
    func testReversalUpdatesRawAndAcceleratedWheelValues() throws {
        guard HaloHID.available else { throw XCTSkip("Required SPI unavailable") }
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                         wheel1: 3, wheel2: 7, wheel3: 0))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3.5)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 37)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: -1)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: -3.5)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis2, value: 7)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2, value: 8.5)
        XCTAssertTrue(HaloHID.reverseVertical(event))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -37)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -3.5)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1), 1)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1), 3.5)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis2), 7)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2), 8.5)
    }

    func testRawAndAcceleratedValuesFollowWheelSpeedAndReversal() throws {
        guard HaloHID.available else { throw XCTSkip("Required SPI unavailable") }
        for factor in [0.25, -0.25, 2, -2] {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                             wheel1: 1, wheel2: 0, wheel3: 0))
            event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: -1)
            event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: -3.5)
            XCTAssertTrue(HaloHID.scaleVertical(event, by: factor))
            XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1), -factor)
            XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1), -3.5 * factor)
        }
    }

    func testWheelSpeedScalesEveryRepresentationAndNeverDropsAStep() throws {
        guard HaloHID.available else { throw XCTSkip("Required SPI unavailable") }
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 1, wheel2: 3, wheel3: 0))
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        XCTAssertTrue(HaloHID.scaleVertical(event, by: -2.5))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3) // -2.5 rounds away from zero
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64((Double(points) * -2.5).rounded()))
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), fixed * -2.5)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 3)
        XCTAssertEqual(HaloHID.scaled(1, 0.5), 1)
        XCTAssertEqual(HaloHID.scaled(-1, 0.4), -1)
        XCTAssertEqual(HaloHID.scaled(0, 4), 0)
        XCTAssertNil(HaloHID.scaled(.max, 4))
        XCTAssertFalse(HaloHID.scaleVertical(event, by: 0))
    }

    func testSpeedAppliesToWheelsOnlyAndCombinesWithReversal() {
        let mouse = Device(properties: ["sender": NSNumber(value: 7), "local": true, "Product": "Mouse", "Transport": "Bluetooth Low Energy",
                                        "SerialNumber": "S1", "HIDScrollAccelerationType": "HIDMouseScrollAcceleration"])
        var policy = Policy()
        policy.enabled = true
        policy.updateDevices([mouse])
        XCTAssertEqual(policy.factor(device: mouse, continuous: false), 1)
        policy.setSpeed(2, for: mouse)
        XCTAssertEqual(policy.factor(device: mouse, continuous: false), 2)
        XCTAssertEqual(policy.factor(device: mouse, continuous: true), 1)
        policy.setRule(.reverse, for: mouse, continuous: false)
        XCTAssertEqual(policy.factor(device: mouse, continuous: false), -2)
        XCTAssertEqual(policy.factor(device: nil, continuous: false), 1)
        policy.setSpeed(1, for: mouse)
        XCTAssertTrue(policy.speeds.isEmpty, "1× is the default and is not stored")
        policy.enabled = false
        XCTAssertEqual(policy.factor(device: mouse, continuous: false), 1)
    }

    func testLinkQualityReportParsesTheDaemonLine() throws {
        let line = "2026-10-31 09:55:14.248 Df bluetoothd[55554:69e2f0] [com.apple.bluetooth:Server.Audio] A2DP LinkQualityReport: Handle = 15 ReTx = 13.6% ( 12 /  88), NAK =    0, NoSync =   12, TxPwr =  8 dBm, RSSI =  -44, {50,75,90}th Noise = { -86, -77, -76} for 20 ch, 2EDR pkts =  26, 3EDRTx pkts =   0, CoexDenial =   0, TxFlush pkts =  2, Tx2Flush pkts =   1, rate = 256 kbps Flow off = 0 devicename = <private>"
        let sample = try XCTUnwrap(LinkQualitySample.parse(line))
        XCTAssertEqual(sample, LinkQualitySample(retransmitted: 13.6, dropped: 3, rssi: -44, noise: -86, handle: 15))
        XCTAssertNil(LinkQualitySample.parse("A2DP LinkQualityReport: something else entirely"))
        XCTAssertNil(LinkQualitySample.parse("HFP LinkQualityReport: Handle = 15"))
        let huge = String(repeating: "9", count: 400)
        XCTAssertNil(LinkQualitySample.parse("A2DP LinkQualityReport: Handle = \(huge) ReTx = 1% RSSI = -40"),
                     "a number no report could mean is not understood, rather than crashing")
        XCTAssertEqual(LinkQualitySample.parse("A2DP LinkQualityReport: Handle = 15 ReTx = 1% RSSI = -40 TxFlush pkts = \(huge)")?.dropped, 0)
        let summary = try XCTUnwrap(LinkQualitySummary([sample, LinkQualitySample(retransmitted: 40.4, dropped: 0, rssi: -50, noise: -80, handle: 15)]))
        XCTAssertEqual(summary.averageRetransmitted, 27, accuracy: 0.01)
        XCTAssertEqual(summary.dropped, 3)
        XCTAssertEqual(summary.averageRSSI, -47)
        XCTAssertEqual(summary.medianNoise, -80)
        XCTAssertNil(LinkQualitySummary([]))
    }

    func testDirectionTallyFlagsOnlyConsistentReversal() {
        var undone = DirectionTally()
        for _ in 0..<DirectionTally.samples { undone.add(raw: 3, final: 3, reversed: true) }
        XCTAssertTrue(undone.blocked)

        var fine = DirectionTally()
        for _ in 0..<DirectionTally.samples { fine.add(raw: 3, final: -3, reversed: true) }
        fine.add(raw: 3, final: 3, reversed: true)
        XCTAssertTrue(fine.done)
        XCTAssertFalse(fine.blocked)
        XCTAssertTrue(fine.fine)

        var mixed = DirectionTally()
        for index in 0..<DirectionTally.samples { mixed.add(raw: 1, final: index < 5 ? 1 : -1, reversed: true) }
        XCTAssertFalse(mixed.blocked)
        XCTAssertFalse(mixed.fine)

        var flippedTrackpad = DirectionTally()
        for _ in 0..<DirectionTally.samples { flippedTrackpad.add(raw: -1, final: 1, reversed: false) }
        XCTAssertTrue(flippedTrackpad.blocked)

        var early = DirectionTally()
        for _ in 0..<(DirectionTally.samples - 1) { early.add(raw: 1, final: 1, reversed: true) }
        early.add(raw: 0, final: 1, reversed: true)
        XCTAssertFalse(early.done)
        XCTAssertFalse(early.blocked)
    }

    func testLentDevicesAreListedBeforeTheyScroll() {
        func device(_ name: String, _ transport: String, local: Bool) -> Device {
            Device(properties: ["sender": NSNumber(value: 9), "Product": name, "Transport": transport, "local": NSNumber(value: local)])
        }
        let lent = device("V-MX Master 2S", "Bluetooth Low Energy", local: false)
        XCTAssertTrue(lent.lent)
        XCTAssertTrue(lent.listed(scrolled: false, ruled: false), "a mouse the other Mac lends shows before its first scroll here")
        let helper = device("V-UC Automouse", "UniversalControl", local: false)
        XCTAssertFalse(helper.lent)
        XCTAssertFalse(helper.listed(scrolled: false, ruled: false), "Universal Control's own helper stays out")
        let unknown = device("Virtual Pointer", "Virtual", local: false)
        XCTAssertFalse(unknown.listed(scrolled: false, ruled: false))
        XCTAssertTrue(unknown.listed(scrolled: true, ruled: false), "another virtual device shows once it scrolls here")
        XCTAssertTrue(device("MX Master 2S", "Bluetooth Low Energy", local: true).listed(scrolled: false, ruled: false))
    }

    func testDevicesAreListedBuiltInAttachedLentThenOthers() {
        func device(_ name: String, _ transport: String, local: Bool) -> Device {
            Device(properties: ["sender": NSNumber(value: 9), "Product": name, "Transport": transport, "local": NSNumber(value: local)])
        }
        let devices = [
            device("V-Apple Internal Keyboard / Trackpad", "SPI", local: false),
            device("Xbox Wireless Controller", "Bluetooth Low Energy", local: true),
            device("V-UC Automouse", "UniversalControl", local: false),
            device("V-Basic Mouse", "Bluetooth", local: false),
            device("MX Master 2S", "Bluetooth Low Energy", local: true),
            device("Apple Internal Keyboard / Trackpad", "FIFO", local: true),
            device("Alex’s Magic Trackpad", "Bluetooth", local: true),
        ]
        // As the app shows them: without "V-", and a built-in one by its kind.
        func shown(_ device: Device) -> String {
            let name = device.name.hasPrefix("V-") ? String(device.name.dropFirst(2)) : device.name
            return name.hasPrefix("Apple Internal") ? "Built-in Trackpad" : name
        }
        // A name late in the alphabet stays with the attached ones; a lent one sorts by the name its row shows.
        XCTAssertEqual(devices.sorted(by: Device.listOrder(shown: shown)).map(shown), [
            "Built-in Trackpad",
            "Alex’s Magic Trackpad", "MX Master 2S", "Xbox Wireless Controller",
            "Basic Mouse", "Built-in Trackpad",
            "UC Automouse",
        ])
    }
}
