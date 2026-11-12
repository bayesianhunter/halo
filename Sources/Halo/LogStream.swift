// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A `log stream` child process on a lifeline. A small shell starts the command in the background, gives up its own
/// copy of the output, and waits on its input, which is Halo's end of a pipe: when Halo closes it (`stop`) or Halo
/// itself is gone, the shell ends the command, so the reader never outlives Halo. Because only the command holds the
/// output, its end shows as end-of-file the moment it exits by itself, and `onEnd` says so.
final class LogStream {
    /// Output as it arrives, on `queue`.
    var onData: ((Data) -> Void)?
    /// On the main queue, once, when the command ended without `stop` (a logd restart, an error).
    var onEnd: (() -> Void)?
    var running: Bool { process != nil }

    private let arguments: [String]
    private let queue: DispatchQueue
    private var process: Process?
    private var lifeline: Pipe?

    /// `arguments`: the command and its arguments. `terminal`: run it under `script`, which gives it a terminal.
    init(_ arguments: [String], terminal: Bool = false, queue: DispatchQueue) {
        self.arguments = terminal ? ["/usr/bin/script", "-q", "/dev/null"] + arguments : arguments
        self.queue = queue
    }

    /// Starts the command; false if it could not be started. Main queue.
    @discardableResult
    func start() -> Bool {
        guard process == nil else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #""$@" & exec >/dev/null; read _; kill $! 2>/dev/null"#, "sh"] + arguments
        let output = Pipe()
        let lifeline = Pipe()
        process.standardOutput = output
        process.standardInput = lifeline
        process.standardError = FileHandle.nullDevice
        let queue = self.queue
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of file: the command is gone. Called again at once forever unless the reader is removed.
                handle.readabilityHandler = nil
                DispatchQueue.main.async { if let process { self?.ended(process) } }
                return
            }
            queue.async { self?.onData?(data) }
        }
        process.terminationHandler = { [weak self] ended in DispatchQueue.main.async { self?.ended(ended) } }
        do { try process.run() } catch { return false }
        self.process = process
        self.lifeline = lifeline
        return true
    }

    /// Ends the command. Nothing more is delivered afterwards. Main queue.
    func stop() {
        guard let process else { return }
        detach(process)
    }

    private func ended(_ ended: Process) {
        guard process === ended else { return }
        detach(ended)
        onEnd?()
    }

    /// Shells told to end, held until they have, so each is reaped rather than left a zombie.
    private static var retiring: Set<Process> = []

    private func detach(_ process: Process) {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            Self.retiring.insert(process)
            process.terminationHandler = { done in DispatchQueue.main.async { Self.retiring.remove(done) } }
        } else {
            process.terminationHandler = nil
        }
        // Closing Halo's end makes the shell end the command and exit.
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        self.process = nil
    }
}
