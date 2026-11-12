// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore

/// `Halo --peer`: the link alone, with made-up devices, so pairing and syncing can be tried against a second process
/// on the same Mac. No event tap, no status item, no rules. It insists on its own HALO_STATE_DIR and keeps its key
/// under a separate Keychain service, so it never shares an identity or a key with a real Halo.
///
///     HALO_STATE_DIR=/tmp/a Halo --peer --pair           pairs with another --pair, confirming the digits itself
///     HALO_STATE_DIR=/tmp/b Halo --peer --pair           (both print the digits); exits 1 if pairing fails
///     HALO_STATE_DIR=/tmp/b Halo --peer                  reconnects with the stored key
///     HALO_STATE_DIR=/tmp/b Halo --peer --unpair         forgets the pairing and its key
///
/// `--loopback` keeps advertising and connections on this Mac. `--render DIR` draws the other side's devices with the
/// menu's and the settings window's own row views into DIR/menu.png and DIR/settings.png whenever they change. SIGUSR1 lowers the fake mouse's charge by one and
/// SIGUSR2 pauses or resumes, each producing one changed snapshot.
enum PeerMode {
    static let keychainService = "Halo (peer test)"

    private final class Fake {
        var battery = 80
        var active = true
    }

    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let directory = ProcessInfo.processInfo.environment["HALO_STATE_DIR"] else {
            print("--peer needs HALO_STATE_DIR, so it never uses a real Halo's state")
            exit(2)
        }
        // Its own keychain service has no key for the real pairing, so pointed at the real folder it would unpair it.
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Halo", isDirectory: true)
        guard URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
                != real.resolvingSymlinksInPath().standardizedFileURL.path else {
            print("--peer needs a HALO_STATE_DIR of its own, not the real Halo's state folder")
            exit(2)
        }
        let name = ProcessInfo.processInfo.environment["HALO_PEER_NAME"] ?? "Halo Peer"
        let link = HaloLink(directory: URL(fileURLWithPath: directory, isDirectory: true), keychainService: keychainService,
                            computerName: name, loopbackOnly: arguments.contains("--loopback"))
        let fake = Fake()
        link.log = { print("[\(name)] \($0)") }
        link.snapshot = {
            LinkSnapshot(computer: name, active: fake.active, devices: [
                // Devices' factory names, so a render can stand in for a screenshot without naming anyone's own.
                LinkDevice(name: "Magic Mouse", kind: .mouse, battery: fake.battery, reversed: true, pointing: true),
                LinkDevice(name: "Built-in", kind: .trackpad, battery: nil, reversed: false, pointing: true, builtIn: true),
                LinkDevice(name: "Magic Trackpad", kind: .trackpad, battery: 64, reversed: false, pointing: true),
                LinkDevice(name: "Magic Keyboard", kind: .keyboard, battery: 55, reversed: false, pointing: false)
            ])
        }
        let pairing = arguments.contains("--pair")
        let render = arguments.firstIndex(of: "--render").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        link.onChange = {
            if let render { draw(AppDelegate.remoteSection(peer: link.peer, online: link.online), into: URL(fileURLWithPath: render)) }
            print("[\(name)] state peer=\(link.peer?.name ?? "-") online=\(link.online) pairing=\(link.pairing) notice=\(link.notice ?? "-")")
            // A test peer confirms the digits itself; both print them, so a run shows they matched.
            if case .comparing(let code, _, false) = link.pairing {
                print("[\(name)] digits \(code)")
                link.confirmPairing()
            }
            if pairing, link.pairing == .idle, link.peer == nil {
                print("[\(name)] PAIRING FAILED")
                exit(1)
            }
        }
        print("[\(name)] id \(link.id)")
        link.start()
        if arguments.contains("--unpair") {
            link.unpair()
            exit(0)
        }
        if pairing { link.startPairing() }
        var sources: [DispatchSourceSignal] = []
        for (number, change) in [(SIGUSR1, { fake.battery -= 1 }), (SIGUSR2, { fake.active.toggle() })] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // Signals sent close together arrive as one event; apply each of them.
                for _ in 0..<source.data { change() }
                link.snapshotChanged()
            }
            source.resume()
            sources.append(source)
        }
        // The main run loop rather than dispatchMain(), which retires the main thread; drawing rows needs it.
        withExtendedLifetime(sources) { RunLoop.main.run() }
        exit(0)
    }

    private static func draw(_ section: (title: String, rows: [(AppDelegate.RowSpec, Bool)], note: String?)?, into folder: URL) {
        guard let section else { return }
        print("render \(section.title): " + section.rows.map { "\($0.0.title) lit=\($0.1) battery=\($0.0.battery?.percent ?? -1)" }.joined(separator: ", ")
              + " note=\(section.note ?? "-")")
        let menu = section.rows.map { DeviceRowView(symbol: $0.0.symbol, title: $0.0.title, facts: [], battery: $0.0.battery, isOn: nil, active: $0.1) as NSView }
        let list = section.rows.map { DeviceListRow(spec: $0.0, dimmed: false) as NSView }
        for (name, rows, width) in [("menu", menu, 320.0), ("settings", list, 520.0)] {
            let stack = NSStackView(views: [NSTextField(labelWithString: section.title)] + rows + [NSTextField(labelWithString: section.note ?? "")])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            // Menu rows are sized by frame, as NSMenuItem views are; inside a stack they need it spelled out.
            for row in rows {
                row.widthAnchor.constraint(equalToConstant: width).isActive = true
                if name == "menu" { row.heightAnchor.constraint(equalToConstant: row.frame.height).isActive = true }
            }
            stack.frame.size = stack.fittingSize
            stack.layoutSubtreeIfNeeded()
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            guard let bitmap = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) else { continue }
            stack.cacheDisplay(in: stack.bounds, to: bitmap)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
