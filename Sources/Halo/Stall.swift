// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import HaloHID

/// A keyboard and pointer that stop responding between the two Macs, noticed and said on both screens so nobody
/// wonders what broke. Halo sees only that the other Mac dropped them while they were over there; whether Universal
/// Control itself disconnected (both have been seen) cannot be told from that, so
/// the notice names the symptom, not a cause.
/// Each Mac plays both parts, whichever way the pointer went: the one the keyboard and pointer were lent to says when
/// it dropped them; the one they belong to, if its input is still routed away a moment later, is stuck (see
/// `HandoffStall`), says so on its screen and tells the other, which says it on its own, where the pointer was.
/// Nothing is polled: the drop comes from the HID event system, the return from Universal Control's own notification.
final class StallWatch {
    private let link: HaloLink
    private let pointer: PointerWatch
    private var stall = HandoffStall()
    private let panel = StallPanel()
    private var drop = LentDrop()
    private var dropCheck: DispatchWorkItem?
    /// Whether any device the other Mac lends this one is still here.
    var anyLent: (() -> Bool)?
    private var expiry: DispatchWorkItem?
    /// The other Mac's input is stuck here: it said `stalled` and nothing has shown it is over.
    private var peer = PeerStall()
    private var peerExpiry: DispatchWorkItem?
    /// Where the menu-bar icon is on screen, to hang the notice under it.
    var anchor: (() -> NSRect?)?

    init(link: HaloLink, pointer: PointerWatch) {
        self.link = link
        self.pointer = pointer
    }

    /// A device the other Mac lends this one went away. Universal Control dropping the other Mac takes all of them
    /// within milliseconds; one going alone (a mouse asleep or switched off over there) is not a drop, nor are all
    /// of them going for a moment while the pointer bounces at the screen edge (see `LentDrop`).
    func lentServiceRemoved() {
        dropCheck?.cancel()
        drop.removed(at: Date())
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drop.settled(at: Date(), anyLent: self.anyLent?() ?? true) else { return }
            Events.record(EventRecord(kind: .handoff, event: "drop-told"))
            self.link.send([.handoff(LinkHandoff(.dropped))])
        }
        dropCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LentDrop.settle, execute: work)
    }

    /// A device the other Mac lends this one came (back): its input works here. A drop told to it is undone, and a
    /// stall of its input here is over at once, however soon after it began.
    func lentServiceAdded() {
        dropCheck?.cancel()
        dropCheck = nil
        if drop.lentAgain() {
            Events.record(EventRecord(kind: .handoff, event: "lent-again"))
            link.send([.handoff(LinkHandoff(.lentAgain))])
        }
        peerOver(.lentAgain)
    }

    func received(_ handoff: LinkHandoff) {
        switch handoff.kind {
        case .dropped?:
            guard stall.dropped(at: Date(), away: away) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + HandoffStall.hold + 0.05) { [weak self] in self?.confirm() }
        case .stalled?:
            peer.stalled(at: Date())
            Events.record(EventRecord(kind: .handoff, event: "peer-stalled"))
            panel.show(.stuck, title: L("Keyboard and Mouse Not Responding"),
                       body: L("%@’s keyboard and mouse aren’t responding. They will come back on their own shortly.", peerName), under: anchor?())
            // As on the other Mac: never up for good if every word of the return is missed.
            peerExpiry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.peerOver(cleared: "no word after \(Int(HandoffStall.ceiling / 60)) min") }
            peerExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HandoffStall.ceiling + 1, execute: work)
        case .recovered?:
            peerOver(seconds: handoff.seconds)
        case .cleared?:
            peerOver(cleared: "the other Mac stopped waiting")
        case .lentAgain?:
            // This Mac's devices are working on the other Mac after all: whatever was pending or shown is over.
            arrived()
        case nil:
            break
        }
    }

    /// The other Mac's stall is over, said by it (`recovered` with its seconds) or given up on (`cleared`, with why):
    /// whichever comes first, or a handoff here (below); the rest find nothing.
    private func peerOver(seconds: Int? = nil, cleared: String? = nil) {
        guard let since = peer.end() else { return }
        if let cleared {
            peerEnded()
            Events.record(EventRecord(kind: .handoff, event: "peer-cleared", detail: cleared))
            panel.hide()
            return
        }
        peerRecovered(seconds ?? max(0, Int(Date().timeIntervalSince(since).rounded())))
    }

    /// Shown by a handoff here, timed from when this Mac heard of the stall.
    private func peerOver(_ sign: PeerStall.Sign) {
        guard let seconds = peer.over(sign, at: Date()) else { return }
        peerRecovered(seconds)
    }

    private func peerRecovered(_ seconds: Int) {
        peerEnded()
        Events.record(EventRecord(kind: .handoff, event: "peer-recovered", detail: "\(seconds) s"))
        panel.show(.restored, title: L("Keyboard and Mouse Back"), body: L("Stuck for %ld seconds.", seconds), under: anchor?(), hideAfter: 4)
    }

    private func peerEnded() {
        peerExpiry?.cancel()
        peerExpiry = nil
    }

    /// Universal Control handed the pointer over normally: this Mac's pointer went to the other Mac or came back.
    /// Input is passing between the two, so a stall of the other Mac's is over even if its own word of it does not
    /// arrive (once measured, the first such handoff came the same second as that word), unless it comes within
    /// `PeerStall.handoffGrace`.
    func handedOver() {
        peerOver(.pointerHandoff)
    }

    /// The pointer came back to this Mac, or the other Mac says it has this Mac's devices again (`lentAgain`): this
    /// Mac's input works. Ends a stall, or a drop still waiting for its confirm.
    func arrived() {
        guard let seconds = stall.arrived(at: Date()) else { return }
        expiry?.cancel()
        Events.record(EventRecord(kind: .handoff, event: "recovered", detail: "\(seconds) s"))
        link.send([.handoff(LinkHandoff(.recovered, seconds: seconds))])
        panel.show(.restored, title: L("Keyboard and Mouse Back"), body: L("Stuck for %ld seconds.", seconds), under: anchor?(), hideAfter: 4)
    }

    /// Without the other Mac nothing more will be heard about a stall on either side.
    func linkChanged() {
        guard !link.online else { return }
        if stall.expire(at: Date(), force: true) { clear("link to the other Mac lost") }
        peerOver(cleared: "link to the other Mac lost")
    }

    private var away: Bool? { pointer.here.map { !$0 } }
    private var peerName: String { link.peer?.name ?? L("Another Mac") }

    private func confirm() {
        guard stall.confirm(at: Date(), away: away), case .stalled(let since) = stall.state else { return }
        // Dated when the drop was heard, where the seconds in `recovered` count from.
        Events.record(EventRecord(t: since, kind: .handoff, event: "stalled"))
        link.send([.handoff(LinkHandoff(.stalled))])
        panel.show(.stuck, title: L("Keyboard and Mouse Not Responding"),
                   body: L("Universal Control didn’t hand them back. They will return to this Mac on their own shortly."), under: anchor?())
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stall.expire(at: Date()) else { return }
            self.clear("no return after \(Int(HandoffStall.ceiling / 60)) min")
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HandoffStall.ceiling + 1, execute: work)
    }

    private func clear(_ reason: String) {
        expiry?.cancel()
        Events.record(EventRecord(kind: .handoff, event: "cleared", detail: reason))
        link.send([.handoff(LinkHandoff(.cleared))])
        panel.hide()
    }
}
