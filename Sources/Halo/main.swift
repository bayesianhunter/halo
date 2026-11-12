// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloHID
import HaloCore

final class Observation {
    var records: [String] = []
    let devices: [UInt64: Device]
    init() {
        let list = HaloHID.devices().map(Device.init(properties:))
        devices = Dictionary(list.map { ($0.sender, $0) }, uniquingKeysWith: { a, _ in a })
    }
    func run(seconds: Double) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, context in
                if type == .scrollWheel, let context {
                    let observer = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
                    let sender = HaloHID.sender(of: event)
                    if observer.records.count < 8192 {
                        observer.records.append("sender=\(String(sender, radix: 16)) continuous=\(event.getIntegerValueField(.scrollWheelEventIsContinuous)) y=\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) source=\(observer.devices[sender]?.name ?? "unknown")")
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            print("Listen-only tap unavailable; no permission prompt or input changes made")
            exit(2)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Listen-only tap started; duration=\(seconds)s; never modifies or posts events")
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        print("Captured \(records.count) scroll events")
        records.forEach { print($0) }
    }
}

// The language settles before the first text is looked up.
Language.alignSystemText()
// Set before anything lists devices or batteries; saved rules do not depend on it.
Device.unnamed = L("Unnamed Device")

// A flag this binary does not know would otherwise start a second copy of the whole app, event tap included; an agent
// trying `--help` gets the usage instead.
let knownFlags: Set<String> = ["--events", "--watch", "--for", "--since", "--until", "--kind", "--json", "--observe", "--diagnostics", "--set", "--record", "--audio-check", "--link-check", "--probe",
                               "--peer", "--pair", "--unpair", "--loopback", "--render", "--render-docs", "--smoke", "--general", "--uninstall"]
// The event log's options mean nothing alone, and a bare `Halo --since 2h` must not start the app.
let eventOptions: Set<String> = ["--since", "--until", "--kind", "--json", "--for"]
let eventsAsked = CommandLine.arguments.contains("--events") || CommandLine.arguments.contains("--watch")
let unknownFlags = CommandLine.arguments.dropFirst().filter {
    $0.hasPrefix("--") && (!knownFlags.contains($0) || (eventOptions.contains($0) && !eventsAsked))
}
if !unknownFlags.isEmpty {
    let help = unknownFlags.contains("--help")
    let text = DiagnosticsExport.usage + "\n"
    FileHandle(fileDescriptor: help ? 1 : 2).write(Data(text.utf8))
    exit(help ? 0 : 2)
}

if eventsAsked {
    exit(EventsCommand.run(CommandLine.arguments))
} else if let index = CommandLine.arguments.firstIndex(of: "--observe") {
    let value = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 10
    guard value.isFinite, value > 0, value <= 60 else { exit(2) }
    Observation().run(seconds: value)
} else if !Set(CommandLine.arguments).isDisjoint(with: ["--diagnostics", "--set", "--record", "--audio-check", "--link-check"]) {
    exit(DiagnosticsExport.runCommand(CommandLine.arguments))
} else if CommandLine.arguments.contains("--uninstall") {
    exit(UninstallList.run())
} else if CommandLine.arguments.contains("--render-docs") {
    _ = NSApplication.shared
    exit(DocsRender.run(CommandLine.arguments))
} else if CommandLine.arguments.contains("--peer") {
    PeerMode.run(CommandLine.arguments)
} else if CommandLine.arguments.contains("--probe") {
    let records = HaloHID.devices()
    print("HID SPI available: \(HaloHID.available)")
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    for record in records {
        let device = Device(properties: record)
        print("sender=\(String(device.sender, radix: 16)) id=\(Events.deviceID(device)) \(device.name) | \(AppDelegate.category(device)) | \(device.transport) | sessionOnly=\(device.sessionOnly)")
    }
    for battery in HaloHID.batteries().compactMap(Battery.init(properties:)) {
        // Keyed IDs, as in the export: a serial is often the Bluetooth address, and this output goes into chats.
        print("battery \(battery.percent)% \(battery.name) | id=\(Events.batteryID(battery))")
    }
} else if !CommandLine.arguments.contains("--general"), DiagnosticsExport.appRunning {
    // Started from a terminal (a bare `Halo`, a mistyped flag) while Halo already runs: a second app would add a second
    // event tap, and two reversals cancel out. LaunchServices activates the running copy instead, so only a direct
    // start gets here. A language change relaunches with --general while the old copy is still quitting.
    FileHandle.standardError.write(Data(("Halo is already running, so a second copy would undo its reversing; nothing was started.\n"
        + DiagnosticsExport.usage + "\n").utf8))
    exit(2)
} else {
    let application = NSApplication.shared
    // First, so the devices and batteries the app finds while starting come after it in the log.
    Events.launched()
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
