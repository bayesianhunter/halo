// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import HaloCore

/// bluetoothd's own log, read only while a Bluetooth speaker or headphones plays, and for half a minute after:
/// link quality behind crackle, the call ring that pulls a speaker into call mode, and the battery a speaker reports
/// over its hands-free link. `log stream` runs as a child process with a narrow filter; nothing runs while silent.
final class BluetoothLog {
    var onEvent: ((BluetoothLogParser.Event) -> Void)?
    private var stream: LogStream?
    private var stopWork: DispatchWorkItem?
    /// Set exactly while `restarts.retryPending`.
    private var restartWork: DispatchWorkItem?
    private var restarts = LogStreamRestarts()
    private let queue = DispatchQueue(label: "Halo bluetooth log", qos: .utility)
    /// Read and written on `queue` only.
    private var buffer = Data()
    private var parser = BluetoothLogParser()

    private static let predicate = BluetoothLogParser.logPredicate

    /// Starts reading at once; stops 30 s after sound stops playing (the first `false` since it last played), so a
    /// pause between songs costs nothing. A stream that ended by itself waits out its retry delay even while sound
    /// keeps playing.
    func setActive(_ active: Bool) {
        let startNow = restarts.setActive(active, running: stream != nil)
        if active {
            stopWork?.cancel()
            stopWork = nil
            if startNow { start() }
        } else if stream != nil, stopWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    func stop() {
        restarts.stopped()
        stopWork?.cancel()
        stopWork = nil
        restartWork?.cancel()
        restartWork = nil
        stream?.stop()
        stream = nil
    }

    private func start() {
        guard stream == nil else { return }
        let stream = LogStream(["/usr/bin/log", "stream", "--style", "ndjson", "--predicate", Self.predicate], queue: queue)
        // A new stream starts clean: half a line or a device named by the last stream's final line would mislead.
        queue.async { [weak self] in
            self?.buffer = Data()
            self?.parser = BluetoothLogParser()
        }
        stream.onData = { [weak self] data in self?.consume(data) }
        stream.onEnd = { [weak self] in
            guard let self else { return }
            self.stream = nil
            // Ended by itself while sound still plays: start again a little later, for as long as it plays.
            guard let delay = self.restarts.ended(at: Date(), stopPending: self.stopWork != nil) else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.restartWork = nil
                if self.restarts.retryDue(running: self.stream != nil) { self.start() }
            }
            self.restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        guard stream.start() else { return }
        self.stream = stream
        restarts.started(at: Date())
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String, let event = parser.parse(message) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    /// The last battery level each device reported in the past ten minutes, read once from the stored log at launch.
    /// A connected speaker reports every few seconds, so ten minutes is plenty and costs a fraction of a longer read.
    /// Calls back on the main queue.
    static func recentBatteries(done: @escaping ([String: (percent: Int, at: Date)]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "10m", "--style", "ndjson", "--predicate",
                                 #"process == "bluetoothd" AND category == "Server.Handsfree" AND eventMessage CONTAINS "HF indicator""#]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var found: [String: (percent: Int, at: Date)] = [:]
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var parser = BluetoothLogParser()
                let dates = DateFormatter()
                // A fixed format must not follow the person's calendar or 12/24-hour setting.
                dates.locale = Locale(identifier: "en_US_POSIX")
                dates.calendar = Calendar(identifier: .gregorian)
                dates.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
                for line in data.split(separator: 0x0A) {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = object["eventMessage"] as? String,
                          case .battery(let address, let percent)? = parser.parse(message) else { continue }
                    guard let at = (object["timestamp"] as? String).flatMap(dates.date) else { continue }
                    found[address] = (percent, at)
                }
            }
            DispatchQueue.main.async { done(found) }
        }
    }
}
