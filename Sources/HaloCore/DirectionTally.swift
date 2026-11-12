// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Tallies, for one device, whether scrolls reached apps in the direction Halo meant.
/// One stray event proves nothing; most of a handful arriving the wrong way round means another program changed them.
public struct DirectionTally: Equatable {
    public static let samples = 8
    public private(set) var agree = 0
    public private(set) var disagree = 0
    public init() {}

    /// `raw` is the device's own vertical delta, `final` what apps received, `reversed` whether Halo meant to flip it.
    public mutating func add(raw: Double, final: Double, reversed: Bool) {
        guard raw != 0, final != 0 else { return }
        let expected = reversed ? -raw : raw
        if (expected > 0) == (final > 0) { agree += 1 } else { disagree += 1 }
    }

    public var done: Bool { agree + disagree >= Self.samples }
    public var blocked: Bool { done && disagree * 4 >= (agree + disagree) * 3 }
    /// Clearly right: what it takes to clear a device found blocked before.
    public var fine: Bool { done && disagree * 4 < agree + disagree }
}
