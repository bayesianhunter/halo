// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import notify

/// UC's connection state survives a pointer handoff and an empty lent-HID list. The system's state notification
/// triggers a single bounded log read; nothing polls or streams in the background. The list is scoped to the
/// current system agent's PID and start time, so another run's old connection cannot appear after a restart.
/// The notification and log format are undocumented: a failed/unknown read preserves the last known answer,
/// and `current` exposes that uncertainty. No identifiers or raw system log are retained in Halo's state files.
final class UniversalControlWatch {
    private(set) var connected: Bool?
    private(set) var session: String?
    private(set) var current = false
    var onChange: (() -> Void)?
    private var token = NOTIFY_TOKEN_INVALID
    private var revision: UInt64 = 0
    private var agent: pid_t?
    private var agentStarted: Date?
    private var since: Date?
    private var searchedFullHistory = false
    /// Lifetime reads that ran out of time for this agent; one more is tried before reading only new events.
    private var fullHistoryTimeouts = 0
    private var scheduled: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var query: Process?

    func start() {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        let status = notify_register_dispatch("com.apple.universalcontrol.state", &token, .main) { [weak self] _ in
            self?.refresh()
        }
        if status != NOTIFY_STATUS_OK { token = NOTIFY_TOKEN_INVALID }
        refresh()
    }

    /// Also read on menu opening and wake, allowing recovery if the system's notification was missed.
    func refresh() {
        revision &+= 1
        let request = revision
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read(revision: request) }
        scheduled = work
        // One state change can publish several announcements; let its final connection event reach the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func read(revision request: UInt64) {
        guard request == revision else { return }
        scheduled = nil
        deadline?.cancel()
        if query?.isRunning == true { query?.terminate() }
        query = nil
        guard let (pid, info) = systemAgent() else {
            // LaunchServices can temporarily omit a still-running system agent. Missing lookup evidence is not
            // evidence of disconnection; clear the old session only when that process is known to have exited.
            if let agent, kill(agent, 0) == -1, errno == ESRCH {
                self.agent = nil
                agentStarted = nil
                since = nil
                searchedFullHistory = false
                fullHistoryTimeouts = 0
                update(nil, reset: true)
            } else { update(nil) }
            return
        }
        let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
        if agent != pid || agentStarted != started {
            agent = pid
            agentStarted = started
            since = nil
            searchedFullHistory = false
            fullHistoryTimeouts = 0
            update(nil, reset: true)
        }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.calendar = Calendar(identifier: .gregorian)
        dates.timeZone = TimeZone(secondsFromGMT: 0)
        dates.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let process = Process()
        let readAt = Date()
        let agentStart = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
        let fullHistory = since == nil && searchedFullHistory
        // Most launches have recent UC events. Avoid scanning days of logs under a short deadline when a small
        // window can answer; if it cannot, perform one longer, bounded bootstrap read of this agent's lifetime.
        let from = since ?? (fullHistory ? agentStart : max(agentStart, readAt.addingTimeInterval(-15 * 60)))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "ndjson", "--start", dates.string(from: from),
                             "--predicate", "(\(UniversalControlLog.predicate)) AND processID == \(pid)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { update(nil); return }
        query = process
        let timeout = DispatchWorkItem { [weak process] in if process?.isRunning == true { process?.terminate() } }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (fullHistory ? 15 : 5), execute: timeout)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let snapshot = process.terminationStatus == 0 ? UniversalControlLog.snapshot(data) : nil
            DispatchQueue.main.async {
                guard let self, self.revision == request else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.query = nil
                switch snapshot {
                case .known(let value, let session):
                    self.since = readAt.addingTimeInterval(-5)
                    self.update(value, session: session)
                case .unchanged:
                    if self.connected == nil, self.since == nil, !fullHistory, from > agentStart {
                        self.searchedFullHistory = true
                        self.refresh()
                        return
                    }
                    // Subsequent reads only cover new events. No event means the last known state still applies.
                    self.since = readAt.addingTimeInterval(-5)
                case .unknown, nil:
                    // A lifetime read is not repeated on every trigger. A format this version cannot read will not
                    // read next time either; a read that failed or ran out of time gets one more try. After that only
                    // new events are read, and the next one Universal Control logs says where it stands.
                    if fullHistory {
                        if snapshot == nil, self.fullHistoryTimeouts == 0 {
                            self.fullHistoryTimeouts = 1
                        } else {
                            self.since = readAt.addingTimeInterval(-5)
                        }
                    }
                    self.update(nil)
                }
            }
        }
    }

    private func systemAgent() -> (pid_t, proc_bsdinfo)? {
        func verified(_ pid: pid_t) -> (pid_t, proc_bsdinfo)? {
            guard pid > 0 else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path) == "/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl" else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            return (pid, info)
        }
        // On the measured system, UC puts its publisher PID in the high half of the state seed. Treat that as a
        // candidate only: require the exact system executable and its real start time before reading any log.
        var state: UInt64 = 0
        if token != NOTIFY_TOKEN_INVALID, notify_get_state(token, &state) == NOTIFY_STATUS_OK,
           state >> 32 <= UInt64(Int32.max), let match = verified(pid_t(state >> 32)) { return match }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.universalcontrol")
            .compactMap { verified($0.processIdentifier) }.first
    }

    private func update(_ value: Bool?, reset: Bool = false, session: String? = nil) {
        let next = reset ? value : (value ?? connected)
        let nextSession = reset ? nil : (session ?? self.session)
        let changed = next != connected || current != (value != nil) || nextSession != self.session
        connected = next
        self.session = nextSession
        current = value != nil
        if changed { onChange?() }
    }

    func stop() {
        revision &+= 1
        scheduled?.cancel()
        deadline?.cancel()
        if query?.isRunning == true { query?.terminate() }
        query = nil
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        token = NOTIFY_TOKEN_INVALID
    }

    deinit { stop() }
}
