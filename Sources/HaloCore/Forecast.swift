// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How long a battery lasts at the rate it has been draining since its last charge, from the levels the event log
/// already holds. Only what was measured: no estimate until the current discharge spans a day and has dropped by
/// a few points, and none while charging.
public struct BatteryForecast: Equatable {
    public struct Reading: Equatable {
        public let t: Date
        public let percent: Int
        public let charging: Bool
        public init(t: Date, percent: Int, charging: Bool) {
            self.t = t
            self.percent = percent
            self.charging = charging
        }
    }

    /// The span and the drop the current discharge needs before an estimate is given.
    public static let minimumSpan: TimeInterval = 86400
    public static let minimumDrop = 3
    /// A rise this large without a cable is a charge (a Logitech mouse charging over USB says nothing over
    /// Bluetooth); smaller ones are the level wavering between readings.
    public static let chargeRise = 3
    /// A device whose every drop is at least this large reports its level coarsely, so a rate drawn through two steps
    /// would be a guess: an MX Master 2S measured during development says over HID++ that it has four levels (90, 50, 20, 5), while the
    /// keyboard beside it went down one point at a time from 74 to 48. One large drop beside small ones is a gap in
    /// the readings (Halo not running, the device away), not coarse reporting.
    public static let coarseStep = 10

    /// The latest level and when it was read.
    public let percent: Int
    public let readAt: Date
    /// Points lost per day over the current discharge.
    public let perDay: Double
    /// When the current discharge began, as far as the log shows.
    public let since: Date
    /// Days left from `now`.
    public let days: Double

    public static func estimate(_ readings: [Reading], now: Date = Date()) -> BatteryForecast? {
        let sorted = readings.sorted { $0.t < $1.t }
        guard let last = sorted.last, !last.charging else { return nil }
        // The current discharge: after the last charge seen, either on a cable or as a clear rise.
        var start = 0, lowest = Int.max
        for (index, reading) in sorted.enumerated() {
            if reading.charging {
                start = index + 1
                lowest = .max
            } else if lowest != .max, reading.percent >= lowest + chargeRise {
                start = index
                lowest = reading.percent
            } else {
                lowest = min(lowest, reading.percent)
            }
        }
        let run = sorted[start...]
        // How the device reports, from every drop in the history, not only this discharge: coarse when none was small.
        let drops = zip(sorted, sorted.dropFirst()).compactMap { pair -> Int? in
            let drop = pair.0.percent - pair.1.percent
            return !pair.0.charging && !pair.1.charging && drop > 0 ? drop : nil
        }
        let coarse = !drops.isEmpty && drops.allSatisfy { $0 >= coarseStep }
        guard !coarse, let first = run.first, last.t.timeIntervalSince(first.t) >= minimumSpan,
              let highest = run.map(\.percent).max(), highest - last.percent >= minimumDrop else { return nil }
        // Least squares over the readings, in days: each line is a moment the level changed.
        let xs = run.map { $0.t.timeIntervalSince(first.t) / 86400 }, ys = run.map { Double($0.percent) }
        let n = Double(run.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx
        guard slope < 0, slope.isFinite else { return nil }
        let perDay = -slope
        return BatteryForecast(percent: last.percent, readAt: last.t, perDay: perDay, since: first.t,
                               days: daysLeft(percent: last.percent, perDay: perDay, elapsed: now.timeIntervalSince(last.t)))
    }

    /// Days left at the rate, counting down from the last reading, but never past what a one-point drop would take:
    /// the level is logged whenever it changes, so no new line means it is still at the last reading.
    static func daysLeft(percent: Int, perDay: Double, elapsed: TimeInterval) -> Double {
        let counted = min(max(0, elapsed / 86400), 1 / perDay)
        return max(0, Double(percent) / perDay - counted)
    }

    /// The same estimate seen later: the days left count down between readings, at most by one point's worth.
    public func at(_ now: Date) -> BatteryForecast {
        BatteryForecast(percent: percent, readAt: readAt, perDay: perDay, since: since,
                        days: Self.daysLeft(percent: percent, perDay: perDay, elapsed: now.timeIntervalSince(readAt)))
    }

    /// What the window says of the days left, in its steps: whole days from a day and a half, whole hours from an
    /// hour, then almost empty.
    public enum Shown: Equatable {
        case days(Int), hours(Int), almostEmpty
    }

    public var shown: Shown {
        if days >= 1.5 { return .days(Int(days.rounded())) }
        if days * 24 >= 1 { return .hours(Int((days * 24).rounded())) }
        return .almostEmpty
    }

    /// When `shown` changes next with time alone, so an open window refreshes then, once, rather than on a timer.
    /// Nil once it no longer counts down: almost empty, or a point's worth of time already passed since the reading,
    /// after which the next reading changes it.
    public func nextChange(after now: Date) -> Date? {
        let current = at(now)
        // The value of `days` at which the text steps down: halfway to the next whole day or hour, or where the unit
        // changes.
        let step: Double
        switch current.shown {
        case .days(let count): step = Double(count) - 0.5
        case .hours(let count): step = max(Double(count) - 0.5, 1) / 24
        case .almostEmpty: return nil
        }
        let when = now.addingTimeInterval((current.days - step) * 86400)
        return when <= readAt.addingTimeInterval(86400 / perDay) ? when : nil
    }

    /// Whole days the estimate rests on, at least one.
    public var basedOnDays: Int { max(1, Int((readAt.timeIntervalSince(since) / 86400).rounded())) }

    /// The readings of one battery from the event log.
    public static func readings(_ events: [EventRecord]) -> [Reading] {
        events.compactMap { event in
            guard event.kind == .battery, let percent = event.percent else { return nil }
            return Reading(t: event.t, percent: percent, charging: event.charging ?? false)
        }
    }
}
