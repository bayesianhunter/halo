// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore
import HaloHID

/// Which device came out the wrong way round, and the programs that could have done it.
struct Blocked: Equatable {
    let device: Device
    let tools: [ScrollTool]
    /// With one other program able to modify scrolling, it is the one; with several, any of them could be.
    var sole: Bool { tools.count == 1 }

    static func == (a: Blocked, b: Blocked) -> Bool {
        a.device.sender == b.device.sender && a.tools.map(\.key) == b.tools.map(\.key)
    }
}

/// Measures whether scrolls reach apps in the direction Halo meant, without knowing what any other program does.
/// Two listen-only taps watch the same events at the head of the chain (the device's own direction) and at its end
/// (what apps receive). They exist only for a short check while another program can modify scrolling,
/// so with no such program running, or between checks, nothing extra runs.
final class DirectionCheck {
    enum Result { case blocked(Device), fine, inconclusive }

    /// How long a check keeps watching after the first scroll, and at most after it starts.
    static let window: TimeInterval = 30
    static let limit: TimeInterval = 60
    /// The two ends stamp the same event a fraction of a millisecond apart (measured: about 0.3 ms).
    static let pairing: UInt64 = 3_000_000
    private unowned let engine: Engine
    private var ports: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    /// Head-of-chain readings per device, oldest first, stamped in nanoseconds. The head stamps events in host
    /// ticks and the end in nanoseconds, so readings are converted and paired by time; one that never reaches
    /// the end (swallowed by another program) is dropped instead of shifting every later pair.
    private var pending: [UInt64: [(time: UInt64, continuous: Bool, delta: Double)]] = [:]
    private var tallies: [UInt64: DirectionTally] = [:]
    private var deadline: Timer?
    private var windowTimer: Timer?
    private var finished = false
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    /// A device found blocked earlier; only its own samples can clear it.
    var watch: UInt64?
    /// The programs that could interfere when the measuring began.
    var suspects: Set<String> = []
    var onFinish: ((Result) -> Void)?

    init?(engine: Engine) {
        self.engine = engine
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The end first: an event caught between the two would otherwise reach the head only.
        for (location, place, head) in [(CGEventTapLocation.cgAnnotatedSessionEventTap, CGEventTapPlacement.tailAppendEventTap, false),
                                        (.cghidEventTap, .headInsertEventTap, true)] {
            let callback: CGEventTapCallBack = head
                ? { _, type, event, context in
                    if let context { Unmanaged<DirectionCheck>.fromOpaque(context).takeUnretainedValue().saw(type, event, head: true) }
                    return Unmanaged.passUnretained(event)
                }
                : { _, type, event, context in
                    if let context { Unmanaged<DirectionCheck>.fromOpaque(context).takeUnretainedValue().saw(type, event, head: false) }
                    return Unmanaged.passUnretained(event)
                }
            guard let port = CGEvent.tapCreate(tap: location, place: place, options: .listenOnly, eventsOfInterest: mask,
                                               callback: callback, userInfo: context),
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                stop()
                return nil
            }
            ports.append(port)
            sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        // Ends even if nothing ever scrolls, so the taps never outlive the check.
        deadline = Self.schedule(Self.limit) { [weak self] in self?.conclude() }
    }

    /// Fires in every run-loop mode, so an open alert or menu cannot keep the taps installed past their time.
    private static func schedule(_ interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    deinit { stop() }

    func stop() {
        deadline?.invalidate()
        windowTimer?.invalidate()
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for port in ports { CFMachPortInvalidate(port) }
        sources = []
        ports = []
    }

    /// A rule or the set of suspects changed: what was measured so far no longer says anything.
    func restart() {
        tallies = [:]
        pending = [:]
        windowTimer?.invalidate()
        windowTimer = nil
    }

    private func saw(_ type: CGEventType, _ event: CGEvent, head: Bool) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            ports.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
            return
        }
        guard type == .scrollWheel, !finished else { return }
        let sender = HaloHID.sender(of: event)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // Only devices Halo reverses: another program reversing a device Halo leaves alone is not in Halo's way.
        guard let device = engine.devices[sender], engine.policy.shouldReverse(device: device, continuous: continuous) else { return }
        // The delta apps scroll by: pixels for trackpads and smooth scrolling, the fixed-point value for wheels.
        let delta = continuous ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                               : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        if head {
            let time = event.timestamp * UInt64(timebase.numer) / UInt64(timebase.denom)
            pending[sender, default: []].append((time, continuous, delta))
            if pending[sender]!.count > 32 { pending[sender]!.removeFirst() }
            return
        }
        // While the system has paused Halo's own tap, scrolls pass unreversed through no fault of anyone else.
        guard let tap = engine.tap, CGEvent.tapIsEnabled(tap: tap) else { return }
        let time = event.timestamp
        pending[sender, default: []].removeAll { $0.time + Self.pairing < time }
        guard let index = pending[sender]?.firstIndex(where: { $0.time <= time + Self.pairing }) else { return }
        let raw = pending[sender]!.remove(at: index)
        var tally = tallies[sender, default: DirectionTally()]
        tally.add(raw: raw.delta, final: delta, reversed: true)
        tallies[sender] = tally
        if tally.blocked {
            finish(.blocked(device))
        } else if sender == watch, tally.fine {
            finish(.fine)
        } else if windowTimer == nil {
            windowTimer = Self.schedule(Self.window) { [weak self] in self?.conclude() }
        }
    }

    /// Time is up: fine only if the device in question was actually measured, otherwise nothing new is known.
    private func conclude() {
        guard !finished else { return }
        if let watch {
            finish(tallies[watch]?.fine == true ? .fine : .inconclusive)
        } else {
            finish(tallies.values.contains(where: \.done) ? .fine : .inconclusive)
        }
    }

    /// Reports after the callback returns, so the taps are not torn down from inside their own callback.
    private func finish(_ result: Result) {
        finished = true
        DispatchQueue.main.async { [weak self] in
            self?.stop()
            self?.onFinish?(result)
        }
    }
}

extension Engine {
    /// Other programs whose scroll taps can change events; only they could undo Halo's direction.
    var otherModifiers: [ScrollTool] { tools.filter { $0.modifies && !$0.isSelf } }
    var suspectKeys: Set<String> { Set(otherModifiers.map(\.key)) }

    /// A finding whose suspect quit, or whose device is gone or no longer reversed, can never be measured again.
    func dropStaleBlocked() {
        guard let blocked else { return }
        if blocked.tools.contains(where: { !suspectKeys.contains($0.key) })
            || devices[blocked.device.sender] == nil || !isReversed(blocked.device) {
            setBlocked(nil)
        }
    }

    /// Starts a check if one could find something: Halo is reversing and another program could interfere.
    /// Called when that program list changes, when Halo turns on, when a rule changes and when the menu opens.
    func checkDirection() {
        guard policy.enabled, tap != nil, !otherModifiers.isEmpty else {
            check = nil
            recheckOnReversedScroll = false
            setBlocked(nil)
            return
        }
        // The remaining suspects were never measured on their own, so the next check decides.
        dropStaleBlocked()
        let suspects = suspectKeys
        if let check {
            // Samples taken with a different set of programs running say nothing about this one.
            if check.suspects != suspects {
                check.restart()
                check.suspects = suspects
            }
            return
        }
        guard let check = DirectionCheck(engine: self) else { return }
        check.suspects = suspects
        check.watch = blocked?.device.sender
        let reversedBefore = reversed
        check.onFinish = { [weak self, unowned check] result in
            guard let self else { return }
            // Read before letting go: `self.check` is all that keeps the check alive while its callback runs.
            let checkedSuspects = check.suspects
            self.check = nil
            self.recheckOnReversedScroll = false
            switch result {
            case let .blocked(device):
                // The programs changed between the verdict and now: it would name the wrong one.
                guard checkedSuspects == self.suspectKeys else { return }
                let suspects = self.otherModifiers
                self.setBlocked(suspects.isEmpty ? nil : Blocked(device: device, tools: suspects))
            case .fine:
                self.setBlocked(nil)
            case .inconclusive:
                self.recheckOnReversedScroll = self.reversed == reversedBefore
            }
        }
        self.check = check
    }

    func setBlocked(_ value: Blocked?) {
        guard value != blocked else { return }
        blocked = value
        onBlockedChanged?()
    }
}
