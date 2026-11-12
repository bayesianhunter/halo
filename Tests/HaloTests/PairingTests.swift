// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import XCTest
@testable import HaloCore

/// Pairing by numeric comparison, without the network: what each side sends, in what order, and what a stranger in
/// the middle can and cannot do.
final class PairingTests: XCTestCase {
    /// Runs the exchange between two sides as the network would, each answering the other's commitment with its key.
    func run(_ a: inout PairingExchange, _ b: inout PairingExchange) throws -> (String, String) {
        let revealA = try a.received(commitment: b.commitment)
        let revealB = try b.received(commitment: a.commitment)
        return (try a.received(reveal: revealB), try b.received(reveal: revealA))
    }

    func testBothSidesShowTheSameDigitsAndArriveAtTheSameKey() throws {
        var a = PairingExchange(id: LinkKeys.newPeerID(), computer: "Studio")
        var b = PairingExchange(id: LinkKeys.newPeerID(), computer: "Air")
        let (onA, onB) = try run(&a, &b)
        XCTAssertEqual(onA, onB)
        XCTAssertEqual(onA.count, 6)
        XCTAssertTrue(onA.allSatisfy(\.isNumber))
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.key?.count, 32)
        XCTAssertEqual(a.peer?.computer, "Air")
        XCTAssertEqual(b.peer?.computer, "Studio")
        XCTAssertTrue(b.accepts(confirmation: try XCTUnwrap(a.confirmation)))
        XCTAssertTrue(a.accepts(confirmation: try XCTUnwrap(b.confirmation)))
        XCTAssertFalse(a.accepts(confirmation: try XCTUnwrap(a.confirmation)), "one side's own confirmation does not pass for the other's")
    }

    /// The digits are fixed by what was exchanged, so a known exchange gives known digits on every build.
    func testTheDigitsAreStable() throws {
        func side(_ id: String, _ name: String, _ seed: UInt8) throws -> PairingExchange {
            PairingExchange(id: id, computer: name, privateKey: try .init(rawRepresentation: Data(repeating: seed, count: 32)))
        }
        var a = try side("00000000-0000-0000-0000-000000000001", "Studio", 1)
        var b = try side("00000000-0000-0000-0000-000000000002", "Air", 2)
        let (onA, onB) = try run(&a, &b)
        XCTAssertEqual(onA, onB)
        var again = try side("00000000-0000-0000-0000-000000000001", "Studio", 1)
        var other = try side("00000000-0000-0000-0000-000000000002", "Air", 2)
        XCTAssertEqual(try run(&other, &again).0, onA, "the order the two run in does not matter")
    }

    /// Someone in the middle runs an exchange with each Mac. Unless the digits happen to collide, the two Macs show
    /// different digits and the people stop there.
    func testAStrangerInTheMiddleShowsDifferentDigits() throws {
        var collisions = 0
        for _ in 0..<200 {
            var a = PairingExchange(id: LinkKeys.newPeerID(), computer: "Studio")
            var b = PairingExchange(id: LinkKeys.newPeerID(), computer: "Air")
            // The stranger poses as Air toward Studio and as Studio toward Air, with keys of its own.
            var towardA = PairingExchange(id: b.own.peer, computer: "Air")
            var towardB = PairingExchange(id: a.own.peer, computer: "Studio")
            let (onA, _) = try run(&a, &towardA)
            let (_, onB) = try run(&towardB, &b)
            if onA == onB { collisions += 1 }
            XCTAssertNotEqual(a.key, b.key)
            XCTAssertFalse(b.accepts(confirmation: try XCTUnwrap(a.confirmation)), "Studio's confirmation does not reach Air as valid")
        }
        XCTAssertLessThanOrEqual(collisions, 1)
    }

    /// Changing only the name in transit, keeping the key, still changes the digits.
    func testTheNameIsPartOfTheDigits() throws {
        var a = PairingExchange(id: LinkKeys.newPeerID(), computer: "Studio")
        var b = PairingExchange(id: LinkKeys.newPeerID(), computer: "Air")
        var renamed = try a.received(commitment: b.commitment)
        renamed.computer = "Mallory"
        let revealB = try b.received(commitment: PairingExchange.commitment(to: renamed))
        XCTAssertNotEqual(try a.received(reveal: revealB), try b.received(reveal: renamed))
    }

    func testARevealMustMatchItsCommitmentAndComeAfterIt() throws {
        var a = PairingExchange(id: LinkKeys.newPeerID(), computer: "Studio")
        let b = PairingExchange(id: LinkKeys.newPeerID(), computer: "Air")
        let c = PairingExchange(id: LinkKeys.newPeerID(), computer: "Other")
        XCTAssertThrowsError(try a.received(reveal: b.own)) { XCTAssertEqual($0 as? PairingExchange.Failure, .outOfOrder) }
        _ = try a.received(commitment: b.commitment)
        XCTAssertThrowsError(try a.received(commitment: b.commitment)) { XCTAssertEqual($0 as? PairingExchange.Failure, .outOfOrder) }
        XCTAssertThrowsError(try a.received(reveal: c.own)) { XCTAssertEqual($0 as? PairingExchange.Failure, .commitmentBroken) }
        XCTAssertNil(a.key)
        XCTAssertNil(a.confirmation, "nothing to confirm before the digits")
        XCTAssertFalse(a.accepts(confirmation: Data(count: 32)))
    }

    func testThisMacCannotPairWithItself() throws {
        var a = PairingExchange(id: LinkKeys.newPeerID(), computer: "Studio")
        _ = try a.received(commitment: a.commitment)
        XCTAssertThrowsError(try a.received(reveal: a.own)) { XCTAssertEqual($0 as? PairingExchange.Failure, .unusable) }
    }

    func testFieldsAreEncodedUnambiguously() {
        let key = Data(repeating: 7, count: 32)
        let one = LinkPairing(peer: "ab", computer: "c", key: key)
        let two = LinkPairing(peer: "a", computer: "bc", key: key)
        XCTAssertNotEqual(PairingExchange.encode(one), PairingExchange.encode(two))
    }
}
