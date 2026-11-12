// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import XCTest
@testable import HaloCore

/// Halo link without the network: keys, the wire format and its limits, and sending only what changed.
final class LinkTests: XCTestCase {
    let mouse = LinkDevice(name: "MX Master", kind: .mouse, battery: 80, reversed: true, pointing: true)
    var snapshot: LinkSnapshot { LinkSnapshot(computer: "Studio", active: true, devices: [mouse]) }

    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testBothSidesDeriveTheSameLongTermKey() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let idA = LinkKeys.newPeerID(), idB = LinkKeys.newPeerID()
        let onA = try LinkKeys.longTermKey(own: a, peerKey: b.publicKey.rawRepresentation, ids: [idA, idB])
        let onB = try LinkKeys.longTermKey(own: b, peerKey: a.publicKey.rawRepresentation, ids: [idB, idA])
        XCTAssertEqual(onA, onB)
        XCTAssertEqual(onA.count, 32)
        // Bound to who paired, and fresh for every pairing.
        XCTAssertNotEqual(onA, try LinkKeys.longTermKey(own: a, peerKey: b.publicKey.rawRepresentation, ids: [idA, LinkKeys.newPeerID()]))
        let c = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertNotEqual(onA, try LinkKeys.longTermKey(own: c, peerKey: b.publicKey.rawRepresentation, ids: [idA, idB]))
        XCTAssertThrowsError(try LinkKeys.longTermKey(own: a, peerKey: Data(count: 31), ids: [idA, idB]))
    }

    func testPeerIDs() {
        XCTAssertTrue(LinkKeys.isPeerID(LinkKeys.newPeerID()))
        XCTAssertFalse(LinkKeys.isPeerID("not-a-peer"))
    }

    func decodeFrame(_ frame: Data) throws -> LinkMessage? {
        let length = try XCTUnwrap(LinkFrame.bodyLength(header: frame.prefix(4)))
        XCTAssertEqual(length, frame.count - 4)
        return try LinkFrame.decode(body: frame.dropFirst(4))
    }

    func testMessagesRoundTrip() throws {
        let pairing = LinkPairing(peer: LinkKeys.newPeerID(), computer: "Air", key: Data(repeating: 7, count: 32))
        for message in [LinkMessage.snapshot(snapshot), .hello(peer: LinkKeys.newPeerID()), .pairCommit(Data(repeating: 1, count: 32)),
                        .pairReveal(pairing), .pairConfirm(Data(repeating: 2, count: 32))] {
            XCTAssertEqual(try decodeFrame(LinkFrame.encode(message)), message)
        }
        for short in [LinkMessage.pairCommit(Data(count: 31)), .pairConfirm(Data(count: 33))] {
            XCTAssertThrowsError(try decodeFrame(LinkFrame.encode(short)), "a proof is a SHA-256 or HMAC-SHA-256, 32 bytes")
        }
    }

    func testOversizedMessagesAreRefused() {
        XCTAssertNil(LinkFrame.bodyLength(header: Data([0, 1, 0, 1])), "64 KiB + 1")
        XCTAssertNil(LinkFrame.bodyLength(header: Data([0, 0, 0, 0])))
        XCTAssertNil(LinkFrame.bodyLength(header: Data([0xff, 0xff, 0xff, 0xff])))
        XCTAssertNil(LinkFrame.bodyLength(header: Data([0, 0, 1])))
        XCTAssertEqual(LinkFrame.bodyLength(header: Data([0, 1, 0, 0])), LinkFrame.maxBody)
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(count: LinkFrame.maxBody + 1)))
        let huge = LinkDevice(name: String(repeating: "x", count: 2000), kind: .mouse, battery: nil, reversed: false, pointing: true)
        XCTAssertThrowsError(try LinkFrame.encode(.snapshot(LinkSnapshot(computer: "Studio", active: true, devices: Array(repeating: huge, count: 64)))))
    }

    func testAnOffTickedAtPairingWinsOnEitherMac() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let on = SettingSync.pairingStamp(on: true), off = SettingSync.pairingStamp(on: false)
        // However far apart the two clocks are: the receiver's own clock only screens times from the future.
        for receiver in [now, now.addingTimeInterval(-3600), now.addingTimeInterval(3600)] {
            XCTAssertTrue(SettingSync.takes(off, over: on, now: receiver), "an off from the other Mac wins")
            XCTAssertFalse(SettingSync.takes(on, over: off, now: receiver), "an on from the other Mac does not undo an off")
            XCTAssertFalse(SettingSync.takes(on, over: on, now: receiver))
        }
        XCTAssertTrue(SettingSync.takes(SettingSync.stamp(after: off, now: now), over: on, now: now), "a change after pairing beats both")
        XCTAssertTrue(SettingSync.takes(SettingSync.stamp(after: on, now: now), over: off, now: now))
    }

    func testUnpairingTravels() throws {
        // One Mac unpairing tells the other; an older Halo ignores the type it does not know rather than hang up.
        XCTAssertEqual(try LinkFrame.decode(body: LinkFrame.encode(.unpaired).dropFirst(4)), .unpaired)
        XCTAssertEqual(String(decoding: try LinkFrame.encode(.unpaired).dropFirst(4), as: UTF8.self), #"{"type":"unpaired"}"#)
    }

    func testDecodingIsDefensive() throws {
        func decode(_ json: String) throws -> LinkMessage? { try LinkFrame.decode(body: Data(json.utf8)) }
        XCTAssertNil(try decode(#"{"type":"command","action":"reverse"}"#), "unknown types are ignored")
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"type":"snapshot"}"#))
        XCTAssertThrowsError(try decode(#"{"type":"hello","peer":"someone"}"#))
        XCTAssertThrowsError(try decode(#"{"type":"pairReveal","pair":{"peer":"\#(LinkKeys.newPeerID())","computer":"Air","key":"AAAA"}}"#))

        let devices = (0..<70).map { _ in
            #"{"name":"Line\nbreak \#(String(repeating: "é", count: 150))","kind":"hologram","battery":150,"reversed":true,"pointing":false,"future":1}"#
        }
        let json = #"{"type":"snapshot","extra":true,"snapshot":{"computer":"Studio","devices":[\#(devices.joined(separator: ","))]}}"#
        guard case .snapshot(let decoded)? = try decode(json) else { return XCTFail("snapshot expected") }
        XCTAssertFalse(decoded.active, "missing means not active")
        XCTAssertEqual(decoded.devices.count, LinkSnapshot.maxDevices)
        let device = decoded.devices[0]
        XCTAssertEqual(device.kind, .other)
        XCTAssertNil(device.battery)
        XCTAssertFalse(device.reversed, "only pointing devices are reversed")
        XCTAssertFalse(device.name.contains("\n"))
        XCTAssertEqual(device.name.count, 120)
    }

    func testOnlyChangedSnapshotsAreSent() throws {
        var outbox = LinkOutbox()
        XCTAssertNotNil(try outbox.frame(for: snapshot))
        XCTAssertNil(try outbox.frame(for: snapshot), "unchanged")
        var lower = snapshot
        lower.devices[0].battery = 79
        XCTAssertNotNil(try outbox.frame(for: lower))
        XCTAssertNil(try outbox.frame(for: lower))
        var paused = lower
        paused.active = false
        XCTAssertNotNil(try outbox.frame(for: paused))
        outbox.reset()
        XCTAssertNotNil(try outbox.frame(for: paused), "a new connection gets the current state once")
    }

    func testReportsRoundTripAndOldPeersIgnoreThem() throws {
        let check = LinkCheck(at: Date(timeIntervalSince1970: 1_800_000_000), found: true, address: "192.168.1.9", ping: .ok,
                              pingMilliseconds: 6, peerTCP: .timedOut, gatewayTCP: .ok, inboundStalled: 3, dialTimeouts: 2)
        let frame = try LinkFrame.encode(.report(check))
        XCTAssertEqual(try LinkFrame.decode(body: frame.dropFirst(4)), .report(check))
        XCTAssertNil(try LinkFrame.decode(body: Data(#"{"type":"future","x":1}"#.utf8)), "an unknown kind is ignored")
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(#"{"type":"report"}"#.utf8)))
        let newer = #"{"type":"report","report":{"at":0,"found":true,"ping":"lost","peerTCP":"ok","gatewayTCP":"ok","inboundStalled":0,"dialTimeouts":0,"handshakeFailures":0}}"#
        guard case .report(let read)? = try LinkFrame.decode(body: Data(newer.utf8)) else { return XCTFail("report expected") }
        XCTAssertEqual(read.ping, .unavailable, "a value from a newer peer reads as untested")
    }

    func testSettingsRoundTripAndOldSnapshotsHaveNone() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var withSettings = snapshot
        withSettings.settings = [LinkSetting(name: "MX Master", builtIn: false, own: true, reversed: true, reversedChanged: at,
                                             speed: 2, speedChanged: at)]
        withSettings.sharing = LinkSharing(match: true, matchChanged: at)
        XCTAssertEqual(try decodeFrame(LinkFrame.encode(.snapshot(withSettings))), .snapshot(withSettings))
        let old = #"{"type":"snapshot","snapshot":{"computer":"Studio","active":true,"devices":[]}}"#
        guard case .snapshot(let read)? = try LinkFrame.decode(body: Data(old.utf8)) else { return XCTFail("snapshot expected") }
        XCTAssertEqual(read.settings, [], "a snapshot without settings has none")
        let odd = #"{"type":"snapshot","snapshot":{"computer":"Studio","devices":[],"settings":[{"name":"MX\nMaster","own":true,"reversed":false,"speed":7,"speedChanged":0,"reversedChanged":0}]}}"#
        guard case .snapshot(let defensive)? = try LinkFrame.decode(body: Data(odd.utf8)) else { return XCTFail("snapshot expected") }
        XCTAssertNil(defensive.settings[0].speed, "a speed the menu does not offer is dropped")
        XCTAssertEqual(defensive.settings[0].reversed, false)
        XCTAssertEqual(defensive.settings[0].name, "MXMaster")
    }

    /// A newer Halo may shape one setting differently; the rest of the snapshot, and the connection, stay.
    func testOneOddSettingCostsOnlyItself() throws {
        let json = #"{"type":"snapshot","snapshot":{"computer":"Studio","devices":[],"settings":[{"name":"New","own":"maybe"},{"name":"MX","own":true,"reversed":true,"reversedChanged":0}],"sharing":{"match":"yes"}}}"#
        guard case .snapshot(let read)? = try LinkFrame.decode(body: Data(json.utf8)) else { return XCTFail("snapshot expected") }
        XCTAssertEqual(read.settings.map(\.name), ["MX"])
        XCTAssertEqual(try LinkFrame.decode(body: Data(#"{"type":"clipDeclined","reason":"\#(String(repeating: "x", count: 100))"}"#.utf8)),
                       .clipDeclined(String(repeating: "x", count: 40)), "a long reason is cut, not a reason to hang up")
    }

    /// A frame of a known kind whose contents this version cannot read is told apart from a broken frame, so the
    /// connection can skip it rather than hang up and be sent it again forever.
    func testUnreadableContentsAreNotABrokenFrame() throws {
        let oneOddDevice = #"{"type":"snapshot","snapshot":{"computer":"Studio","devices":[{"kind":"mouse"},{"name":"MX","kind":"mouse"}]}}"#
        guard case .snapshot(let read)? = try LinkFrame.decode(body: Data(oneOddDevice.utf8)) else { return XCTFail("snapshot expected") }
        XCTAssertEqual(read.devices.map(\.name), ["MX"], "one device without a name costs only itself")

        let newerSnapshot = #"{"type":"snapshot","snapshot":{"computer":42}}"#
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(newerSnapshot.utf8))) { error in
            XCTAssertEqual(error as? LinkFrame.Failure, .unreadable("snapshot"))
        }
        XCTAssertThrowsError(try LinkFrame.decode(body: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? LinkFrame.Failure, .malformed)
        }

        let olderReport = #"{"type":"report","report":{"found":true,"ping":"ok","peerTCP":"ok","gatewayTCP":"teleported"}}"#
        guard case .report(let report)? = try LinkFrame.decode(body: Data(olderReport.utf8)) else { return XCTFail("report expected") }
        XCTAssertEqual(report.gatewayTCP, .unavailable)
        XCTAssertEqual(report.dialTimeouts, 0, "a field left out reads as not measured")
        XCTAssertTrue(report.found)
        let noFound = #"{"type":"report","report":{"ping":"ok"}}"#
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(noFound.utf8)), "not knowing whether the peer was found is not \"not found\"") { error in
            XCTAssertEqual(error as? LinkFrame.Failure, .unreadable("report"))
        }
        for body in [#"{"type":"clipDeclined","reason":{"code":7}}"#, #"{"type":"handoff","handoff":{"event":5}}"#] {
            XCTAssertThrowsError(try LinkFrame.decode(body: Data(body.utf8)), body) { error in
                guard case .unreadable? = error as? LinkFrame.Failure else { return XCTFail("\(error)") }
            }
        }
        XCTAssertNil(try LinkFrame.decode(body: Data(#"{"type":"handoff","handoff":{"event":"teleported"}}"#.utf8)), "a newer event is ignored")
    }

    /// Each Mac names a device from its own side: the sender's mouse is one the receiver borrows, and the receiver's
    /// built-in trackpad, borrowed by the sender, is the receiver's own. Reverse and speed each go by their own time.
    func testSettingsApplyToTheMatchingDeviceOnlyWhenNewer() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), earlier = now.addingTimeInterval(-60)
        let mouse = LinkSetting(name: "MX Master", builtIn: false, own: true, reversed: true, reversedChanged: now, speed: 2, speedChanged: earlier)
        let trackpad = LinkSetting(name: "Apple Internal Keyboard / Trackpad", builtIn: true, own: false, reversed: false, reversedChanged: earlier)
        let both = SettingSync.newer([mouse, trackpad], than: [:], now: now)
        XCTAssertEqual(both.map(\.key), ["borrowed:mx master", "own:#built-in"])
        XCTAssertEqual(both.first.map { [$0.reverse, $0.speed] }, [true, true])
        let changes = ["borrowed:mx master|reverse": now, "own:#built-in|reverse": now]
        let speedOnly = SettingSync.newer([mouse, trackpad], than: changes, now: now)
        XCTAssertEqual(speedOnly.map(\.key), ["borrowed:mx master"], "a setting already taken, or older than a change made here, is left alone")
        XCTAssertEqual(speedOnly.first.map { [$0.reverse, $0.speed] }, [false, true], "the speed set earlier there still beats none here")
        XCTAssertEqual(SettingSync.newer([mouse], than: ["own:mx master|reverse": now, "own:mx master|speed": now], now: now).map(\.key),
                       ["borrowed:mx master"], "this Mac's own mouse of the same name is a different device")
    }

    /// A peer clock far ahead, or a forged time, cannot lock a setting; a change made here always beats one stored here.
    func testTimesFromTooFarAheadAreNotTakenAndLocalChangesAlwaysWin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forged = LinkSetting(name: "MX", builtIn: false, own: true, reversed: true, reversedChanged: .distantFuture)
        XCTAssertTrue(SettingSync.newer([forged], than: [:], now: now).isEmpty)
        XCTAssertFalse(SettingSync.takes(now.addingTimeInterval(SettingSync.maxAhead + 1), over: nil, now: now))
        XCTAssertTrue(SettingSync.takes(now.addingTimeInterval(SettingSync.maxAhead - 1), over: nil, now: now), "a clock a little ahead is fine")
        let ahead = now.addingTimeInterval(30)
        XCTAssertGreaterThan(SettingSync.stamp(after: ahead, now: now), ahead, "a change here beats the peer's time it took")
        XCTAssertEqual(SettingSync.stamp(after: now.addingTimeInterval(-5), now: now), now)
    }

    func testReverseFollowsTheFeelNotTheSwitch() {
        var setting = LinkSetting(name: "MX Master", builtIn: false, own: true, reversed: true, reversedChanged: Date(), natural: true)
        XCTAssertEqual(setting.reversed(naturalHere: true), true)
        XCTAssertEqual(setting.reversed(naturalHere: false), false, "Natural Scrolling off here already turns it round")
        setting.natural = nil
        XCTAssertEqual(setting.reversed(naturalHere: false), true, "an unknown sender setting is taken as it is")
        setting.reversed = nil
        XCTAssertNil(setting.reversed(naturalHere: true), "no reverse value, nothing to take")
    }

    /// The case met on a real network: the Macs ping each other and reach the router, but TCP between them is dropped.
    func testVerdicts() {
        func check(found: Bool = true, ping: LinkReach = .ok, peer: LinkReach = .ok, gateway: LinkReach = .ok, tls: Int = 0,
                   timeouts: Int = 0) -> LinkCheck {
            LinkCheck(found: found, ping: ping, peerTCP: peer, gatewayTCP: gateway, dialTimeouts: timeouts, handshakeFailures: tls)
        }
        XCTAssertEqual(LinkVerdict.of(check()), .ok)
        XCTAssertEqual(LinkVerdict.of(check(peer: .refused)), .ok, "a refusal still crossed the network")
        XCTAssertEqual(LinkVerdict.of(check(peer: .timedOut)), .tcpBlocked)
        XCTAssertEqual(LinkVerdict.of(check(ping: .timedOut, peer: .timedOut)), .peerSilent)
        XCTAssertEqual(LinkVerdict.of(check(found: false, ping: .unavailable, peer: .unavailable)), .notFound)
        XCTAssertEqual(LinkVerdict.of(check(ping: .timedOut, peer: .timedOut, gateway: .timedOut)), .localNetwork, "this Mac's own network first")
        XCTAssertEqual(LinkVerdict.of(check(peer: .timedOut, gateway: .timedOut)), .tcpBlocked, "a ping reply rules out this Mac's network")
        XCTAssertEqual(LinkVerdict.of(check(gateway: .timedOut)), .ok, "a router ignoring port 80 is not a fault")
        XCTAssertEqual(LinkVerdict.of(check(timeouts: 2)), .unknown, "TCP works but Halo's connections stall")
        XCTAssertEqual(LinkVerdict.of(check(gateway: .unavailable)), .ok, "no router to compare against is not a fault")
        XCTAssertEqual(LinkVerdict.of(check(tls: 2)), .handshake)
        var weak = check(tls: 1)
        weak.noForwardSecrecy = 3
        XCTAssertEqual(LinkVerdict.of(weak), .noForwardSecrecy, "plain PSK refused, not a lost key")
        XCTAssertEqual(LinkVerdict.of(check(peer: .unavailable)), .unknown)
        XCTAssertEqual(LinkVerdict.of(check(peer: .unavailable), peer: check(peer: .timedOut)), .tcpBlocked, "the other side saw the drop")
        XCTAssertEqual(LinkVerdict.of(check(), peer: nil), .ok)
    }

    func testFindsADeviceItLendsInItsOwnList() {
        func lent(_ name: String, trackpad: Bool = false, transport: String = "Bluetooth") -> Device {
            Device(properties: ["sender": NSNumber(value: 1), "Product": name, "local": false, "Transport": transport,
                                "touchpad": NSNumber(value: trackpad)])
        }
        let snapshot = LinkSnapshot(computer: "Studio", active: true, devices: [
            LinkDevice(name: "Built-in Trackpad", kind: .trackpad, battery: nil, reversed: false, pointing: true, builtIn: true),
            LinkDevice(name: "MX Master", kind: .mouse, battery: 80, reversed: true, pointing: true),
            LinkDevice(name: "Magic Keyboard", kind: .keyboard, battery: 60, reversed: false, pointing: false),
        ])
        // By name, whatever the case; the built-in trackpad by kind, as each Mac names it in its own language.
        XCTAssertEqual(snapshot.index(ofLent: lent("V-mx master")), 1)
        XCTAssertEqual(snapshot.index(ofLent: lent("V-Apple Internal Keyboard / Trackpad", trackpad: true)), 0)
        // Reported as a keyboard here, it is still that Mac's built-in device.
        XCTAssertNil(snapshot.index(ofLent: lent("V-Apple Internal Keyboard / Trackpad")))
        XCTAssertEqual(snapshot.index(ofLent: lent("V-Apple Internal Keyboard / Trackpad"), anyKind: true), 0)
        // Not reported by that Mac (an iPad's, or a third Mac's), attached here, or Universal Control's own pointer.
        XCTAssertNil(snapshot.index(ofLent: lent("V-Logitech Pebble")))
        XCTAssertNil(snapshot.index(ofLent: Device(properties: ["sender": NSNumber(value: 2), "Product": "MX Master", "local": true])))
        XCTAssertNil(snapshot.index(ofLent: lent("V-MX Master", transport: "UniversalControl")))
        // Two of one name fill two slots; a built-in one of the other kind takes the built-in slot only if it is free.
        let twice = LinkSnapshot(computer: "Studio", active: true, devices: [
            LinkDevice(name: "Built-in Trackpad", kind: .trackpad, battery: nil, reversed: false, pointing: true, builtIn: true),
            LinkDevice(name: "MX Master", kind: .mouse, battery: 80, reversed: true, pointing: true),
            LinkDevice(name: "MX Master", kind: .mouse, battery: 70, reversed: false, pointing: true),
        ])
        XCTAssertEqual(twice.slots(ofLent: [lent("V-Apple Internal Keyboard / Trackpad"), lent("V-MX Master"),
                                            lent("V-Apple Internal Keyboard / Trackpad", trackpad: true), lent("V-MX Master")]),
                       [1: 1, 2: 0, 3: 2])
    }
}
