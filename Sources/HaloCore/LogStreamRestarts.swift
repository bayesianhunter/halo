// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// When the Bluetooth log stream may start, and how long to wait after it ends by itself. The reader does the timers
/// and the process; this holds the decisions, so a retry waiting out its delay is not cut short by sound that keeps
/// reporting it plays.
public struct LogStreamRestarts {
    /// Whether sound plays; a stream that ends by itself is started again only while it does.
    public private(set) var active = false
    /// A retry is waiting out `delay`. Until it is due, nothing starts the stream.
    public private(set) var retryPending = false
    /// Seconds before a stream that ended by itself is started again: doubled each time one ends within a minute,
    /// up to five minutes, so a `log` that keeps failing is not started every few seconds for as long as sound plays.
    public private(set) var delay: TimeInterval = 5
    private var startedAt = Date.distantPast

    public init() {}

    /// Sound started or stopped playing. True when the stream should start now: sound plays, no stream runs, and no
    /// retry is waiting.
    public mutating func setActive(_ active: Bool, running: Bool) -> Bool {
        self.active = active
        return active && !running && !retryPending
    }

    public mutating func started(at now: Date) {
        startedAt = now
    }

    /// The stream ended by itself. The delay before trying again, or nil when there is none to schedule: sound has
    /// stopped, or the stream is about to be stopped anyway.
    public mutating func ended(at now: Date, stopPending: Bool) -> TimeInterval? {
        guard active, !stopPending else { return nil }
        delay = now.timeIntervalSince(startedAt) > 60 ? 5 : min(delay * 2, 300)
        retryPending = true
        return delay
    }

    /// The retry's delay is over. True when it should start the stream; either way, nothing is waiting any more.
    public mutating func retryDue(running: Bool) -> Bool {
        retryPending = false
        return active && !running
    }

    /// Stopped on purpose: no retry waits, and the next failure starts from the shortest delay.
    public mutating func stopped() {
        active = false
        retryPending = false
        delay = 5
    }
}
