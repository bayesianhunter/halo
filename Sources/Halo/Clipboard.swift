// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ImageIO
import HaloCore
import notify

/// Which Mac the person is at, from Universal Control's own notification: it is posted whenever the shared pointer or
/// keyboard moves between Macs, and its state says which of them is away. The name is undocumented (read from
/// Universal Control's log); if it never fires, the clipboard just does not follow, and the menu can still fetch it.
final class PointerWatch {
    /// Set while this Mac's pointer is on the other Mac; 0x1 is the keyboard, which follows on the next click.
    private static let pointerAway: UInt64 = 0x2
    private var token = NOTIFY_TOKEN_INVALID
    /// Whether the pointer is on this Mac; nil while not watching.
    private(set) var here: Bool?
    var onArrive: (() -> Void)?
    var onLeave: (() -> Void)?

    func start() {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        let status = notify_register_dispatch("user.uid.\(getuid()).com.apple.universalcontrol.inputstate", &token, .main) { [weak self] token in
            self?.update(token)
        }
        guard status == NOTIFY_STATUS_OK else { token = NOTIFY_TOKEN_INVALID; return }
        here = state(token).map { $0 & Self.pointerAway == 0 } ?? true
    }

    func stop() {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        token = NOTIFY_TOKEN_INVALID
        here = nil
    }

    private func state(_ token: Int32) -> UInt64? {
        var state: UInt64 = 0
        return notify_get_state(token, &state) == NOTIFY_STATUS_OK ? state : nil
    }

    private func update(_ token: Int32) {
        guard let state = state(token) else { return }
        let now = state & Self.pointerAway == 0
        guard now != here else { return }
        here = now
        now ? onArrive?() : onLeave?()
    }
}

/// The clipboard following the person between the two Macs. Leaving a Mac after copying there sends what was copied;
/// the other Mac writes it to its clipboard once it has all of it and the person is there, so ⌘V never waits on the
/// network. Nothing is polled and nothing touches the disk: the clipboard is read once on leaving, and what arrives
/// stays in memory until the next one, sleep or a locked screen. It never interrupts: what did not come over is noted
/// in the menu, not announced. Packing, hashing and thumbnails run off the main thread, where the scroll tap lives.
final class ClipboardShare {
    struct Received {
        let from: String
        let at: Date
        let items: [(type: String, data: Data)]
        /// The first line of text, for the menu; nil for a password.
        let text: String?
        let thumbnail: NSImage?
        let pixels: NSSize?
        let concealed: Bool
    }

    /// A password stays on the receiving Mac's clipboard this long, as password managers clear their own.
    static let concealedLifetime: TimeInterval = 90
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let work = DispatchQueue(label: "halo.clipboard", qos: .userInitiated)

    private(set) var received: Received?
    /// Why the last clipboard did not come over, for the menu; cleared when one does.
    private(set) var problem: String?
    var log: ((String) -> Void)?
    private let link: HaloLink
    private let watch = PointerWatch()
    private var visit = ClipVisit()
    private var assembler = ClipAssembler()
    /// Arrived while the person was at the other Mac; written when they come over.
    private var pending: Received?
    /// The header of the clip whose chunks are arriving, and whether it answers `fetch` (judged when the header
    /// came, so a large image's transfer does not count against the window).
    private var incoming: LinkClip?
    private var incomingAsked = false
    /// A clip being sent. A copy made or asked for meanwhile waits for it: `queued` says to send the clipboard as it
    /// is then, and whether the other Mac asked for it.
    private var sending = false
    private var queued: Bool?
    /// The clipboard change count right after Halo wrote a password, so only that write is ever cleared.
    private var concealedWrite: Int?
    private var clearWork: DispatchWorkItem?
    /// Drops a password from the menu and from `pending` when its lifetime is up, written or not.
    private var expireWork: DispatchWorkItem?
    /// When the person asked for the other Mac's clipboard (`fetch`): the clip that comes within `answerWindow` is
    /// the answer, written even over something copied here, since asking for it is the person's choice. An answer
    /// that never comes (the link dropped, the other Mac locked) does not reach past the window to a later push.
    private var requestedAt: Date?
    private static let answerWindow: TimeInterval = 15
    /// The clipboard was read once with macOS still at its default and nothing asked: reading does not prompt here.
    private var readQuietly = false
    private var observers: [NSObjectProtocol] = []
    /// Ends whenever everything is forgotten, so a clipboard still being packed or previewed then goes nowhere.
    private var era = ClipEra()

    /// This Mac's clipboard switch.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                watch.start()
                visit.arrived(count: NSPasteboard.general.changeCount)
            } else {
                watch.stop()
                forget()
            }
        }
    }

    /// Whether the paired Mac sends and takes clipboards: nil while no snapshot has come, false with its switch off.
    var peerClipboard: Bool? { link.peer?.snapshot?.clipboard }

    init(link: HaloLink) {
        self.link = link
        watch.onArrive = { [weak self] in self?.arrived() }
        watch.onLeave = { [weak self] in self?.left() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.forget()
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.forget()
        })
    }

    /// Asks the paired Mac for its clipboard now, from the menu.
    func fetch() {
        guard enabled else { return }
        requestedAt = link.send([.clipRequest]) ? Date() : nil
        if requestedAt == nil { note(L("Not connected to %@", link.peer?.name ?? "")) }
    }

    /// Whether macOS lets Halo read the clipboard without a paste and without asking. Asked on the Mac the person just
    /// left, the question would wait there unseen, so Halo reads only once it is allowed, or once a read at the default
    /// setting passed without a question.
    var readAllowed: Bool {
        let behavior = NSPasteboard.general.accessBehavior
        return behavior == .alwaysAllow || (behavior == .default && readQuietly)
    }

    /// Whether the person has to allow Halo in System Settings before the clipboard can follow from here.
    var readNeedsSettings: Bool {
        let behavior = NSPasteboard.general.accessBehavior
        return behavior == .ask || behavior == .alwaysDeny
    }

    /// Reads the clipboard once while the person is at this Mac, so if macOS asks, the question comes now, here.
    func prime() {
        guard NSPasteboard.general.accessBehavior == .default, !readQuietly else { return }
        if let type = NSPasteboard.general.pasteboardItems?.first?.types.first { _ = NSPasteboard.general.data(forType: type) }
        readQuietly = NSPasteboard.general.accessBehavior == .default
    }

    /// Puts the last clipboard from the other Mac back, after something else was copied here.
    func reuse() {
        guard let received else { return }
        write(received)
    }

    func handle(_ message: LinkMessage) {
        guard enabled else { return }
        switch message {
        case .clipRequest:
            send(asked: true)
        case .clipDeclined(let code):
            requestedAt = nil
            let name = link.peer?.name ?? ""
            log?("clipboard declined: \(code)")
            switch ClipDecline(rawValue: code) {
            case .privateContents: note(L("%@’s clipboard holds something temporary or forwarded", name))
            case .locked: note(L("%@ is locked", name))
            case .tooLarge: note(L("%@’s clipboard is over 16 MB", name))
            case .notAllowed: note(L("Halo on %@ can’t read the clipboard yet", name))
            case .empty: note(L("%@’s clipboard has no text or image", name))
            case nil: note(L("%@ didn’t send its clipboard", name))
            }
        case .clip(let clip):
            incoming = clip
            incomingAsked = requestedAt.map { Date().timeIntervalSince($0) < Self.answerWindow } ?? false
            requestedAt = nil
            assembler.begin(clip)
        case .clipChunk(let chunk):
            // The rest of a clip whose start was forgotten (sleep, a locked screen): nothing to say about it.
            guard incoming != nil else { return log?("clipboard dropped: its start was forgotten") ?? () }
            do {
                guard let items = try assembler.add(chunk) else { return }
                let concealed = incoming?.concealed == true
                incoming = nil
                // Only types a newer Halo added: nothing to write, and writing nothing would empty the clipboard.
                guard !items.isEmpty else { return log?("clipboard dropped: no type this version knows") ?? () }
                took(items, concealed: concealed, asked: incomingAsked)
            } catch {
                incoming = nil
                requestedAt = nil
                log?("clipboard dropped: \(error)")
                note(L("%@ didn’t send its clipboard", link.peer?.name ?? ""))
            }
        default:
            break
        }
    }

    private func arrived() {
        visit.arrived(count: NSPasteboard.general.changeCount)
        prime()
        if let pending {
            self.pending = nil
            write(pending)
        }
    }

    private func left() {
        guard visit.left(count: NSPasteboard.general.changeCount), enabled, peerClipboard == true else { return }
        send(asked: false)
    }

    /// Sends the clipboard, or says why not: always when asked; on leaving only when the person would otherwise wonder
    /// why ⌘V brings nothing, not for something an app only put there for a moment.
    private func send(asked: Bool) {
        guard peerClipboard == true else { return }
        guard !sending else {
            queued = (queued ?? false) || asked
            return
        }
        let outcome = asked && Self.screenLocked ? .failure(.locked) : read()
        guard case .success(let read) = outcome else {
            if case .failure(let reason) = outcome {
                log?("clipboard kept: \(reason.rawValue) (\(asked ? "asked" : "left"))")
                if asked || reason == .tooLarge || reason == .notAllowed { decline(reason) }
            }
            return
        }
        sending = true
        let peer = link.peer?.name ?? "", began = era.current
        Self.work.async { [weak self] in
            let frames = Self.frames(read)
            DispatchQueue.main.async {
                guard let self else { return }
                // Turned off, locked or asleep while it was packed, or the other Mac stopped taking clipboards: not sent.
                guard self.era.allows(began, enabled: self.enabled, locked: Self.screenLocked), self.peerClipboard == true else {
                    self.log?("clipboard not sent: forgotten, turned off, locked or no longer taken while packed (\(asked ? "asked" : "left"))")
                    return self.sent()
                }
                guard let frames else {
                    self.decline(.tooLarge)
                    return self.sent()
                }
                let sent = self.link.send(frames: frames.data) { [weak self] in self?.sent() }
                if sent {
                    // Sizes only; what was copied never goes into the log.
                    self.log?("sent clipboard: \(frames.summary) (\(asked ? "asked" : "left"))")
                } else {
                    self.queued = nil
                    self.sending = false
                    self.note(L("Not connected to %@", peer))
                }
            }
        }
    }

    /// One send is over; a clipboard wanted meanwhile goes now, as it is now.
    private func sent() {
        sending = false
        guard let asked = queued else { return }
        queued = nil
        // The switch may have gone off, or the screen locked, while the first one was on its way.
        guard enabled, !Self.screenLocked else { return }
        send(asked: asked)
    }

    /// The wire frames for a read clipboard, the image turned into PNG first if it came as TIFF; nil over the cap.
    private static func frames(_ read: Read) -> (data: [Data], summary: String)? {
        var items = read.items
        if let tiff = read.tiff, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            items.append((NSPasteboard.PasteboardType.png.rawValue, png))
        }
        while items.reduce(0, { $0 + $1.data.count }) > LinkClip.maxTotal,
              let extra = items.lastIndex(where: { $0.type == "public.html" || $0.type == "public.rtf" }) {
            items.remove(at: extra)
        }
        guard let packed = LinkClip.pack(items, concealed: read.concealed),
              let frames = try? ([.clip(packed.clip)] + packed.chunks.map(LinkMessage.clipChunk)).map(LinkFrame.encode) else { return nil }
        return (frames, packed.clip.items.map { "\($0.type) \($0.size)" }.joined(separator: ", "))
    }

    private func decline(_ reason: ClipDecline) {
        link.send([.clipDeclined(reason.rawValue)])
    }

    private struct Read {
        var items: [(type: String, data: Data)]
        /// An image only as TIFF, converted off the main thread.
        var tiff: Data?
        var concealed: Bool
    }

    /// What may go to the other Mac: nothing an app only put there for a moment or that came in from another device;
    /// else its text, rich text, web text and image, and whether it is a password.
    private func read() -> Result<Read, ClipDecline> {
        guard readAllowed else { return .failure(.notAllowed) }
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !types.isEmpty else { return .failure(.empty) }
        guard ClipFilter.mayShare(types) else { return .failure(.privateContents) }
        let items: [(type: String, data: Data)] = LinkClip.types.compactMap { type in
            types.contains(type) ? pasteboard.data(forType: .init(type)).map { (type, $0) } : nil
        }
        let tiff = types.contains(NSPasteboard.PasteboardType.png.rawValue) ? nil : pasteboard.data(forType: .tiff)
        guard !items.isEmpty || tiff != nil else { return .failure(.empty) }
        return .success(Read(items: items, tiff: tiff, concealed: ClipFilter.isConcealed(types)))
    }

    /// The preview is made off the main thread; then the clip is written, unless the person is still at the other Mac
    /// (written when they come over) or already copied something here since arriving (kept in the menu instead). An
    /// answer to `fetch` is written at once: the person asked for it here.
    private func took(_ items: [(type: String, data: Data)], concealed: Bool, asked: Bool) {
        let from = link.peer?.name ?? "", at = Date(), began = era.current
        log?("received clipboard: \(items.map { "\($0.type) \($0.data.count)" }.joined(separator: ", "))\(concealed ? " (concealed)" : "")")
        Self.work.async { [weak self] in
            // A password gets no preview, here or in the menu.
            let text = concealed ? nil : items.first { $0.type == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
            let image = concealed ? nil : items.first { $0.type == "public.png" }.flatMap { Self.preview($0.data) }
            let received = Received(from: from, at: at, items: items, text: text.flatMap(Self.firstLine),
                                    thumbnail: image?.thumbnail, pixels: image?.pixels, concealed: concealed)
            DispatchQueue.main.async {
                // Forgotten (sleep, a locked screen, the switch, unpairing) while the preview was made: it stays forgotten.
                guard let self, self.era.allows(began, enabled: self.enabled, locked: Self.screenLocked) else { return }
                self.received = received
                self.problem = nil
                if concealed { self.expire(received) }
                if asked {
                    // An older clip waiting for the person to come over would replace this one on arrival.
                    self.pending = nil
                    self.write(received)
                } else if self.watch.here == false {
                    self.pending = received
                } else if self.visit.copied(count: NSPasteboard.general.changeCount) {
                    self.log?("clipboard kept in the menu: something was copied here since arriving")
                } else {
                    self.write(received)
                }
            }
        }
    }

    /// Only on this Mac: Universal Clipboard does not pass it on to the other devices. A password keeps its mark, so
    /// clipboard managers here leave it alone too, and is cleared again after a while unless something replaced it.
    private func write(_ clip: Received) {
        // A password's 90 seconds run from when it came over, not from when it is written.
        let left = clip.at.addingTimeInterval(Self.concealedLifetime).timeIntervalSinceNow
        if clip.concealed, left <= 0 { return }
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        for (type, data) in clip.items { item.setData(data, forType: .init(type)) }
        if clip.concealed { item.setData(Data(), forType: Self.concealedType) }
        pasteboard.writeObjects([item])
        visit.wrote(count: pasteboard.changeCount)
        clearWork?.cancel()
        concealedWrite = clip.concealed ? pasteboard.changeCount : nil
        guard clip.concealed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clearConcealed()
            if let received = self.received, received.concealed, received.at == clip.at {
                self.received = nil
            }
        }
        clearWork = work
        // Wall-clock time: a Mac asleep in between does not stretch the 90 seconds.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + left, execute: work)
    }

    /// A password not yet written (waiting for the person to come over) or kept in the menu goes when its lifetime is
    /// up, as one on the clipboard does.
    private func expire(_ clip: Received) {
        expireWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let received = self.received, received.concealed, received.at == clip.at { self.received = nil }
            if let pending = self.pending, pending.at == clip.at { self.pending = nil }
        }
        expireWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, clip.at.addingTimeInterval(Self.concealedLifetime).timeIntervalSinceNow),
                                      execute: work)
    }

    /// Clears a password Halo wrote, if it is still what the clipboard holds.
    private func clearConcealed() {
        let pasteboard = NSPasteboard.general
        guard let written = concealedWrite, pasteboard.changeCount == written else { return }
        pasteboard.clearContents()
        visit.wrote(count: pasteboard.changeCount)
        concealedWrite = nil
    }

    private func note(_ text: String) {
        problem = text
    }

    /// Sleep, a locked screen, the switch turned off or unpairing: everything Halo holds from the other Mac goes, and a
    /// concealed password it wrote is cleared if the clipboard still holds it. Text or an image already written to the
    /// clipboard stays there.
    private func forget() {
        era.end()
        clearWork?.cancel()
        expireWork?.cancel()
        requestedAt = nil
        clearConcealed()
        queued = nil
        incoming = nil
        assembler = ClipAssembler()
        guard received != nil || pending != nil || problem != nil else { return }
        received = nil
        pending = nil
        problem = nil
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) }
    }

    /// The image's size and a thumbnail at twice the tile's size, made by ImageIO without decoding the full image, so
    /// neither a large screenshot nor a crafted one costs more than the thumbnail.
    private static func preview(_ png: Data) -> (thumbnail: NSImage, pixels: NSSize)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(RoundTile.side * 2)]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = RoundTile.side / CGFloat(max(width, height))
        let size = NSSize(width: max(1, (CGFloat(width) * scale).rounded()), height: max(1, (CGFloat(height) * scale).rounded()))
        return (NSImage(cgImage: thumbnail, size: size), NSSize(width: width, height: height))
    }
}
