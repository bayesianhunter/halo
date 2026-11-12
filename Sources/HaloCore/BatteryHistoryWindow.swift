// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The forecast's in-memory history follows the log's lookback, including during a long-running app session.
/// Trimming happens on a new reading or a forecast request, at most once a day; it never schedules work.
public struct BatteryHistoryWindow {
    public static let retention = Double(EventLog.keepDays) * 86400
    public private(set) var events: [String: [EventRecord]]
    private var trimmedAt: Date?

    public init(events: [String: [EventRecord]] = [:], now: Date = Date()) {
        self.events = events
        trimIfNeeded(at: now)
    }

    /// Returns whether older history was removed, so forecasts cached for other devices can be invalidated too.
    @discardableResult
    public mutating func append(_ event: EventRecord, now: Date = Date()) -> Bool {
        let trimmed = trimIfNeeded(at: now)
        guard event.kind == .battery, let id = event.id, event.t >= now.addingTimeInterval(-Self.retention) else { return trimmed }
        events[id, default: []].append(event)
        return trimmed
    }

    /// A backwards clock step keeps existing readings, and resets the next check's reference time.
    @discardableResult
    public mutating func trimIfNeeded(at now: Date = Date()) -> Bool {
        if let trimmedAt, now >= trimmedAt, now.timeIntervalSince(trimmedAt) < 86400 { return false }
        trimmedAt = now
        let oldest = now.addingTimeInterval(-Self.retention)
        var removed = false
        for (id, lines) in events {
            let kept = lines.filter { $0.t >= oldest }
            guard kept.count != lines.count else { continue }
            events[id] = kept.isEmpty ? nil : kept
            removed = true
        }
        return removed
    }
}
