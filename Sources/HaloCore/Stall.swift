// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// This Mac's input stuck on its way to the other Mac. Universal Control on each Mac gives up on the other on its
/// own clock: when the receiving Mac drops this Mac's keyboard and pointer first, this Mac goes on sending to it, and
/// nothing typed or moved here does anything until its own Universal Control notices. Measured between two
/// Macs with Bluetooth off on the receiving one: stuck 19 to 46 seconds.
///
/// The other Mac's drop alone says nothing: devices are dropped whenever Universal Control disconnects. Only the drop
/// followed by this Mac's input still routed away a moment later is a stall; normally both happen within milliseconds.
public struct HandoffStall: Equatable {
    /// How long this Mac's input must stay away after the other Mac dropped it.
    public static let hold: TimeInterval = 2
    /// Waiting stops after this long, so a notice never stays up for good if the return is missed.
    public static let ceiling: TimeInterval = 600

    public enum State: Equatable {
        case idle
        /// The other Mac dropped this Mac's devices at `since` while the input was away; confirmed after `hold`.
        case pending(since: Date)
        case stalled(since: Date)
    }

    public private(set) var state = State.idle

    public init() {}

    /// The other Mac dropped this Mac's devices. `away`: this Mac's input is routed to another Mac, nil if unknown.
    /// True when `confirm` should be called after `hold`.
    public mutating func dropped(at now: Date, away: Bool?) -> Bool {
        guard state == .idle, away == true else { return false }
        state = .pending(since: now)
        return true
    }

    /// After `hold`: true when the input is still away, so this Mac is stuck from when the drop was heard. A confirm
    /// that comes early belongs to an earlier drop (the input came back and was dropped again in between): it leaves
    /// the newer drop pending for its own confirm.
    public mutating func confirm(at now: Date, away: Bool?) -> Bool {
        guard case .pending(let since) = state, now.timeIntervalSince(since) >= Self.hold else { return false }
        guard away == true else {
            state = .idle
            return false
        }
        state = .stalled(since: since)
        return true
    }

    /// The input came back to this Mac: whole seconds it was stuck, nil if it was not.
    public mutating func arrived(at now: Date) -> Int? {
        defer { state = .idle }
        guard case .stalled(let since) = state else { return nil }
        return max(0, Int(now.timeIntervalSince(since).rounded()))
    }

    /// True when a stall is given up on: past `ceiling`, or `force` (the link to the other Mac went away).
    public mutating func expire(at now: Date, force: Bool = false) -> Bool {
        guard case .stalled(let since) = state, force || now.timeIntervalSince(since) >= Self.ceiling else {
            if force { state = .idle }
            return false
        }
        state = .idle
        return true
    }
}

/// The borrowing Mac's side: when to tell the other Mac it dropped its keyboard and pointer. Every lent device goes
/// whenever the pointer goes home, and a pointer bouncing at the screen edge brings them back within half a second
/// (measured: gone 0.45 s); a real drop keeps them gone until the stall is over (19 s and more). So a drop is
/// told only once nothing lent has come back for `settle`, and told undone when something lent comes back after.
public struct LentDrop: Equatable {
    public static let settle: TimeInterval = 1.5
    /// The other Mac was told of a drop that nothing has undone yet.
    public private(set) var told = false
    /// When the last lent device went, so a check that comes before `settle` has passed tells nothing.
    private var removedAt: Date?

    public init() {}

    /// A lent device went; `settled` is due `settle` from now. Every lent device goes within milliseconds of the
    /// others, and each removal moves the check on, so one check covers them all.
    public mutating func removed(at now: Date) { removedAt = now }

    /// The check after a removal: true when the other Mac should hear of a drop.
    public mutating func settled(at now: Date, anyLent: Bool) -> Bool {
        guard !anyLent, !told, let removedAt, now.timeIntervalSince(removedAt) >= Self.settle - 0.05 else { return false }
        told = true
        return true
    }

    /// A lent device came (back): true when the other Mac was told of a drop this undoes. One told when the pointer
    /// went home normally is undone too, which the other Mac, never stuck, ignores.
    public mutating func lentAgain() -> Bool {
        defer { told = false }
        return told
    }
}

/// The other Mac's input stuck on this one, as the other Mac said (`stalled`), until something shows it is over.
public struct PeerStall: Equatable {
    /// The pointer may still be bouncing as the stall begins (once measured, the last bounce here came 2.3 s before
    /// the other Mac's word of it), so pointer handoffs in the first `handoffGrace` seconds do not end it.
    public static let handoffGrace: TimeInterval = 3

    public enum Sign: Equatable {
        /// This Mac's pointer went to the other Mac or came back.
        case pointerHandoff
        /// The other Mac's devices were lent here again: its input works here, whenever that happens.
        case lentAgain
    }

    public private(set) var since: Date?

    public init() {}

    public mutating func stalled(at now: Date) { since = now }

    /// Whole seconds the other Mac's input was stuck when `sign` ends the stall; nil when nothing was stuck or a
    /// pointer handoff came within the grace.
    public mutating func over(_ sign: Sign, at now: Date) -> Int? {
        guard let since else { return nil }
        if sign == .pointerHandoff, now.timeIntervalSince(since) < Self.handoffGrace { return nil }
        self.since = nil
        return max(0, Int(now.timeIntervalSince(since).rounded()))
    }

    /// Ended without a handoff (the other Mac's own word, or given up on): when it began, nil if nothing was stuck.
    public mutating func end() -> Date? {
        defer { since = nil }
        return since
    }
}
