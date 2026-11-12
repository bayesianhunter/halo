// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// Universal Control stuck between the two Macs: the other Mac dropped this one's devices while its input was away.
final class StallTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testADropWhileAwayThatLastsIsAStall() {
        var stall = HandoffStall()
        XCTAssertTrue(stall.dropped(at: at(0), away: true))
        XCTAssertTrue(stall.confirm(at: at(2), away: true))
        XCTAssertEqual(stall.state, .stalled(since: at(0)), "stuck from when the drop was heard")
        XCTAssertEqual(stall.arrived(at: at(27.4)), 27)
        XCTAssertEqual(stall.state, .idle)
    }

    func testADropWithTheInputHereIsNothing() {
        var stall = HandoffStall()
        XCTAssertFalse(stall.dropped(at: at(0), away: false), "an ordinary disconnect")
        XCTAssertFalse(stall.dropped(at: at(0), away: nil), "not watching the pointer")
        XCTAssertEqual(stall.state, .idle)
    }

    func testComingBackWithinTheHoldIsNothing() {
        var stall = HandoffStall()
        XCTAssertTrue(stall.dropped(at: at(0), away: true))
        XCTAssertNil(stall.arrived(at: at(0.1)), "the usual order: dropped, then home within milliseconds")
        XCTAssertFalse(stall.confirm(at: at(2), away: false))
        XCTAssertEqual(stall.state, .idle)
        XCTAssertTrue(stall.dropped(at: at(10), away: true))
        XCTAssertFalse(stall.confirm(at: at(12), away: false), "home by the time it is checked")
        XCTAssertEqual(stall.state, .idle)
    }

    func testAnEarlierDropsConfirmLeavesALaterDropAlone() {
        var stall = HandoffStall()
        XCTAssertTrue(stall.dropped(at: at(0), away: true))
        XCTAssertNil(stall.arrived(at: at(0.1)))
        XCTAssertTrue(stall.dropped(at: at(1), away: true), "Universal Control flapping: dropped again a second later")
        XCTAssertFalse(stall.confirm(at: at(2.05), away: true), "the first drop's confirm is too early for the second")
        XCTAssertEqual(stall.state, .pending(since: at(1)))
        XCTAssertTrue(stall.confirm(at: at(3.05), away: true), "the second drop's own confirm finds it stuck")
        XCTAssertEqual(stall.state, .stalled(since: at(1)))
    }

    func testAStallIsGivenUpOn() {
        var stall = HandoffStall()
        _ = stall.dropped(at: at(0), away: true)
        _ = stall.confirm(at: at(2), away: true)
        XCTAssertFalse(stall.expire(at: at(HandoffStall.ceiling - 1)))
        XCTAssertTrue(stall.expire(at: at(HandoffStall.ceiling)))
        XCTAssertNil(stall.arrived(at: at(HandoffStall.ceiling + 5)), "nothing to report once given up")
        _ = stall.dropped(at: at(1000), away: true)
        _ = stall.confirm(at: at(1002), away: true)
        XCTAssertTrue(stall.expire(at: at(1003), force: true), "the link went away")
        XCTAssertEqual(stall.state, .idle)
    }

    func testOneDropAtATime() {
        var stall = HandoffStall()
        XCTAssertTrue(stall.dropped(at: at(0), away: true))
        XCTAssertFalse(stall.dropped(at: at(0.5), away: true), "already waiting")
        _ = stall.confirm(at: at(2), away: true)
        XCTAssertFalse(stall.dropped(at: at(3), away: true), "already stuck")
        XCTAssertEqual(stall.state, .stalled(since: at(0)))
    }

    /// Measured: the pointer bounced from Mac A to Mac B and back within 0.6 s; B's devices left A and
    /// were lent to it again 0.45 s later. Nothing was lost, and neither Mac may say otherwise.
    func testAnEdgeBounceSaysNothing() {
        for start in [0.0, 76.0] {
            var drop = LentDrop()
            drop.removed(at: at(start))
            // Where the check used to be (0.3 s), the devices were still gone: it must not be due yet.
            XCTAssertFalse(drop.settled(at: at(start + 0.3), anyLent: false), "too early to tell")
            XCTAssertFalse(drop.lentAgain(), "back at +0.45 s: nothing was told, nothing to undo")
            XCTAssertFalse(drop.settled(at: at(start + LentDrop.settle), anyLent: true), "back within the settle")
            XCTAssertFalse(drop.told, "the other Mac never hears of a drop, so neither Mac shows anything")
        }
        XCTAssertGreaterThan(LentDrop.settle, 0.45 * 3, "well clear of the measured bounce")
    }

    /// A bounce slower than the settle: the drop is told, then undone when the devices are lent again; the owner's
    /// pending drop ends before its confirm.
    func testADropUndoneBeforeItsConfirmSaysNothing() {
        var drop = LentDrop()
        var owner = HandoffStall()
        drop.removed(at: at(0))
        XCTAssertTrue(drop.settled(at: at(1.5), anyLent: false))
        XCTAssertTrue(owner.dropped(at: at(1.52), away: true))
        XCTAssertTrue(drop.lentAgain(), "told, so undone")
        XCTAssertNil(owner.arrived(at: at(2.02)), "pending, not stuck")
        XCTAssertFalse(owner.confirm(at: at(3.52), away: true), "the pointer is on the other Mac, working")
        XCTAssertEqual(owner.state, .idle)
        XCTAssertFalse(drop.lentAgain(), "undone once")
    }

    /// A real drop still becomes a stall: the devices stay gone.
    func testADropThatStaysGoneIsStillAStall() {
        var drop = LentDrop()
        var owner = HandoffStall()
        drop.removed(at: at(0))
        drop.removed(at: at(0.01))
        XCTAssertTrue(drop.settled(at: at(1.51), anyLent: false))
        XCTAssertFalse(drop.settled(at: at(3), anyLent: false), "told once")
        XCTAssertTrue(owner.dropped(at: at(1.53), away: true))
        XCTAssertTrue(owner.confirm(at: at(3.53), away: true))
        XCTAssertEqual(owner.state, .stalled(since: at(1.53)))
    }

    /// Lent again just after the owner confirmed: the notice is up for a moment, then the owner calls it over.
    func testLentAgainAfterTheConfirmEndsTheStall() {
        var drop = LentDrop()
        var owner = HandoffStall()
        drop.removed(at: at(0))
        XCTAssertTrue(drop.settled(at: at(1.5), anyLent: false))
        XCTAssertTrue(owner.dropped(at: at(1.5), away: true))
        XCTAssertTrue(owner.confirm(at: at(3.5), away: true))
        XCTAssertTrue(drop.lentAgain())
        XCTAssertEqual(owner.arrived(at: at(3.6)), 2, "the owner's `lentAgain` goes through `arrived()`")
        XCTAssertEqual(owner.state, .idle)
    }

    /// The devices lent here again end the other Mac's stall at once; a pointer handoff only after the grace.
    func testLentAgainEndsAPeerStallAtOnce() {
        var peer = PeerStall()
        peer.stalled(at: at(0))
        XCTAssertNil(peer.over(.pointerHandoff, at: at(1)), "the pointer may still be bouncing")
        XCTAssertEqual(peer.over(.lentAgain, at: at(1.4)), 1)
        XCTAssertNil(peer.since)
        peer.stalled(at: at(10))
        XCTAssertEqual(peer.over(.pointerHandoff, at: at(15)), 5)
        peer.stalled(at: at(20))
        XCTAssertEqual(peer.end(), at(20))
        XCTAssertNil(peer.end())
    }

    func testHandoffMessagesCrossTheLink() throws {
        for message in [LinkMessage.handoff(LinkHandoff(.dropped)), .handoff(LinkHandoff(.stalled)),
                        .handoff(LinkHandoff(.recovered, seconds: 46)), .handoff(LinkHandoff(.cleared)),
                        .handoff(LinkHandoff(.lentAgain))] {
            XCTAssertEqual(try LinkFrame.decode(body: LinkFrame.encode(message).dropFirst(4)), message)
        }
        XCTAssertNil(try LinkFrame.decode(body: Data(#"{"type":"handoff","handoff":{"event":"rebooted"}}"#.utf8)),
                     "an event from a newer Halo is ignored, not a reason to hang up")
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(#"{"type":"handoff"}"#.utf8)), "skipped and logged once, like a snapshot") {
            XCTAssertEqual($0 as? LinkFrame.Failure, .unreadable("handoff"))
        }
    }

    func testARemovalIsDatedWhenItWentMissing() {
        var presence = Presence<String>(confirmsRemoval: true, confirmAfter: 60)
        _ = presence.update(["v": "V-MX Master 2S"], at: at(0))
        XCTAssertTrue(presence.update([:], at: at(100)).removed.isEmpty, "dropped")
        XCTAssertTrue(presence.update([:], at: at(100.1)).removed.isEmpty, "a listing a moment later does not confirm it")
        XCTAssertTrue(presence.awaitingConfirmation, "the engine lists once more after the wait")
        let gone = presence.update([:], at: at(160))
        XCTAssertFalse(presence.awaitingConfirmation, "confirmed: nothing more to list for")
        XCTAssertEqual(gone.removed, ["V-MX Master 2S"])
        XCTAssertEqual(gone.removedAt, [at(100)], "logged at the drop, not at the listing that confirmed it")
        var waking = Presence<String>(confirmsRemoval: true, confirmAfter: 60)
        _ = waking.update(["m": "Mouse"], at: at(0))
        _ = waking.update([:], at: at(50))
        _ = waking.update([:], at: at(52))
        XCTAssertTrue(waking.update(["m": "Mouse"], at: at(55)).removed.isEmpty, "away for the seconds of a wake")
    }
}
