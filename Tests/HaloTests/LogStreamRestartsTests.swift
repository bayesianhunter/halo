// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class LogStreamRestartsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// Sound plays, the stream starts at `at`, and ends by itself `after` seconds later.
    private func runAndEnd(_ restarts: inout LogStreamRestarts, at: Date, after: TimeInterval) -> TimeInterval? {
        restarts.started(at: at)
        return restarts.ended(at: at.addingTimeInterval(after), stopPending: false)
    }

    /// Sound reporting again and again that it plays, while a retry waits, must not start the stream before the delay.
    func testPlayingAgainDoesNotCutAWaitingRetryShort() {
        var restarts = LogStreamRestarts()
        XCTAssertTrue(restarts.setActive(true, running: false))
        XCTAssertEqual(runAndEnd(&restarts, at: t0, after: 1), 10)
        let starts = (0..<10).filter { _ in restarts.setActive(true, running: false) }.count
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(restarts.delay, 10, "the delay that was due still holds")
        XCTAssertTrue(restarts.retryDue(running: false), "the retry itself starts it, once")
        XCTAssertFalse(restarts.retryPending)
    }

    func testRetryDueWhileSilentLeavesNothingWaiting() {
        var restarts = LogStreamRestarts()
        _ = restarts.setActive(true, running: false)
        XCTAssertNotNil(runAndEnd(&restarts, at: t0, after: 1))
        XCTAssertFalse(restarts.setActive(false, running: false))
        XCTAssertFalse(restarts.retryDue(running: false))
        XCTAssertTrue(restarts.setActive(true, running: false), "sound plays again after the retry passed: start now")
    }

    func testNoRetryOnceSilentOrStopping() {
        var restarts = LogStreamRestarts()
        _ = restarts.setActive(true, running: false)
        restarts.started(at: t0)
        XCTAssertNil(restarts.ended(at: t0.addingTimeInterval(1), stopPending: true))
        _ = restarts.setActive(false, running: false)
        XCTAssertNil(restarts.ended(at: t0.addingTimeInterval(2), stopPending: false))
        XCTAssertFalse(restarts.retryPending)
    }

    func testDelayDoublesUpToFiveMinutesAndResetsAfterALongRun() {
        var restarts = LogStreamRestarts()
        _ = restarts.setActive(true, running: false)
        var delays: [TimeInterval] = []
        var now = t0
        for _ in 0..<7 {
            delays.append(runAndEnd(&restarts, at: now, after: 1)!)
            XCTAssertTrue(restarts.retryDue(running: false))
            now = now.addingTimeInterval(1000)
        }
        XCTAssertEqual(delays, [10, 20, 40, 80, 160, 300, 300])
        XCTAssertEqual(runAndEnd(&restarts, at: now, after: 61), 5, "a stream that ran over a minute starts the count again")
    }

    func testStopClearsTheRetryAndTheDelay() {
        var restarts = LogStreamRestarts()
        _ = restarts.setActive(true, running: false)
        _ = runAndEnd(&restarts, at: t0, after: 1)
        _ = restarts.retryDue(running: false)
        _ = runAndEnd(&restarts, at: t0.addingTimeInterval(100), after: 1)
        XCTAssertEqual(restarts.delay, 20)
        restarts.stopped()
        XCTAssertFalse(restarts.retryPending)
        XCTAssertFalse(restarts.active)
        XCTAssertEqual(restarts.delay, 5)
        XCTAssertTrue(restarts.setActive(true, running: false))
    }

    func testARunningStreamIsNotStartedTwice() {
        var restarts = LogStreamRestarts()
        XCTAssertFalse(restarts.setActive(true, running: true))
    }
}
