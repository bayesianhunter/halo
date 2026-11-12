// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import HaloCore

/// Watches the music link to a Bluetooth speaker or headphones for a fixed time, only when asked. It reads the
/// reports the Bluetooth daemon writes to the system log once a second while it streams; the log reader runs only
/// for the length of the check and is stopped at the end, or as soon as the check is cancelled.
final class AudioCheck {
    static let duration: TimeInterval = 30
    /// Without music playing the daemon reports nothing; give up rather than show an empty chart.
    static let firstReportWithin: TimeInterval = 10

    enum Outcome { case finished, cancelled, noData, failed }

    private(set) var samples: [(time: TimeInterval, sample: LinkQualitySample)] = []
    private(set) var started: Date?
    /// How the last check ended; nil while one runs.
    private(set) var outcome: Outcome?
    var running: Bool { stream != nil }
    var onSample: (() -> Void)?
    var onEnd: ((Outcome) -> Void)?
    private var stream: LogStream?
    private var buffer = Data()
    private var deadline: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?

    func start() {
        guard stream == nil else { return }
        samples = []
        buffer = Data()
        outcome = nil
        // Under `script`, `log` writes to a terminal, so each report arrives as it is written rather than when a pipe
        // buffer fills. On a lifeline (see `LogStream`), so it ends with the check or with Halo.
        let stream = LogStream(["/usr/bin/log", "stream", "--style", "compact",
                                "--predicate", "process == \"bluetoothd\" AND eventMessage CONTAINS \"A2DP LinkQualityReport\""],
                               terminal: true, queue: .main)
        stream.onData = { [weak self] data in self?.received(data) }
        stream.onEnd = { [weak self] in self?.endedEarly() }
        guard stream.start() else {
            started = Date()
            outcome = .failed
            onEnd?(.failed)
            return
        }
        self.stream = stream
        started = Date()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.samples.isEmpty else { return }
            self.stop(.noData)
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstReportWithin, execute: watchdog)
        let deadline = DispatchWorkItem { [weak self] in self?.stop(.finished) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: deadline)
    }

    func stop(_ outcome: Outcome = .finished) {
        guard let stream else { return }
        stream.onEnd = nil
        stream.stop()
        self.stream = nil
        deadline?.cancel()
        watchdog?.cancel()
        self.outcome = outcome
        onEnd?(outcome)
    }

    /// The log reader stopped by itself before the check was over.
    private func endedEarly() {
        guard stream != nil else { return }
        stop(samples.isEmpty ? .failed : .finished)
    }

    private func received(_ data: Data) {
        guard stream != nil, let started else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            guard let sample = LinkQualitySample.parse(line) else { continue }
            // One stream at a time: the first one heard is the one charted.
            if let first = samples.first, first.sample.handle != sample.handle { continue }
            samples.append((Date().timeIntervalSince(started), sample))
            onSample?()
        }
        if buffer.count > 1 << 16 { buffer.removeAll() }
    }
}
