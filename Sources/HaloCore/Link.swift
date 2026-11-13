// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// What one Halo tells its paired Mac about itself. The other side shows it; only the device settings in it can
/// change that Mac, and only once its own "match device settings" switch is on.
public struct LinkSnapshot: Codable, Equatable {
    public static let maxDevices = 64
    public var computer: String
    /// Whether Halo is reversing there right now; false while it is not listening (no permission, or the tap failed).
    public var active: Bool
    public var devices: [LinkDevice]
    /// The mouse and trackpad settings the person changed on the sender, for the receiver to match.
    public var settings: [LinkSetting]
    /// Whether the sender's clipboard switch is on, so it sends and takes clipboards.
    public var clipboard: Bool
    /// The two sharing switches as last set on either Mac, so turning one on here turns it on there too.
    public var sharing: LinkSharing?

    public init(computer: String, active: Bool, devices: [LinkDevice], settings: [LinkSetting] = [], clipboard: Bool = false,
                sharing: LinkSharing? = nil) {
        self.computer = computer
        self.active = active
        self.devices = devices
        self.settings = settings
        self.clipboard = clipboard
        self.sharing = sharing
    }

    /// A setting named for two same-named devices on the peer says nothing about which one changed: its device list
    /// shows the ambiguity even when its settings list holds one entry, so such a setting is not matched.
    public var matchableSettings: [LinkSetting] {
        settings.filter { setting in
            guard setting.own, !setting.builtIn else { return true }
            return devices.filter { $0.pointing && !$0.builtIn && $0.name.lowercased() == setting.name.lowercased() }.count <= 1
        }
    }

    /// Decodes defensively: unknown fields are ignored, text is shortened and the device list capped,
    /// so a confused or hostile peer cannot blow up the menu.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        computer = LinkText.clean(try c.decode(String.self, forKey: .computer))
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        let devices = (try? c.decodeIfPresent([Lossy<LinkDevice>].self, forKey: .devices)).flatMap { $0 } ?? []
        self.devices = Array(devices.compactMap(\.value).prefix(Self.maxDevices))
        let settings = (try? c.decodeIfPresent([Lossy<LinkSetting>].self, forKey: .settings)).flatMap { $0 } ?? []
        self.settings = Array(settings.compactMap(\.value).prefix(Self.maxDevices))
        clipboard = (try? c.decodeIfPresent(Bool.self, forKey: .clipboard)) ?? false
        sharing = try? c.decodeIfPresent(LinkSharing.self, forKey: .sharing)
    }
}

/// "Match device settings" and "clipboard follows you" belong to the pair, not to one Mac: the newer change to each
/// switch, on either side, sets it on both. Each switch keeps its own time, so changing one never undoes the other.
public struct LinkSharing: Codable, Equatable {
    public var match: Bool?
    public var matchChanged: Date?
    public var clipboard: Bool?
    public var clipboardChanged: Date?

    public init(match: Bool? = nil, matchChanged: Date? = nil, clipboard: Bool? = nil, clipboardChanged: Date? = nil) {
        self.match = match
        self.matchChanged = matchChanged
        self.clipboard = clipboard
        self.clipboardChanged = clipboardChanged
    }
}

/// One device's reverse switch and wheel speed as the person last set them on the sender, each stamped with when.
/// A device lent through Universal Control shows up on the borrowing Mac as a separate "V-" device with rules of its
/// own; these let both Macs keep the same settings for it, the newer change to each winning.
public struct LinkSetting: Codable, Equatable {
    /// The name its owner gives it, without Universal Control's "V-".
    public var name: String
    /// The sending Mac's built-in trackpad, which has the same name on every Mac.
    public var builtIn: Bool
    /// Attached to the sender; false for a device the sender borrows from the receiver.
    public var own: Bool
    /// Absent when never set, or when the device's wheel and smooth scrolling follow different rules there.
    public var reversed: Bool?
    public var reversedChanged: Date?
    /// The sender's macOS Natural Scrolling, which Halo's reverse switch flips relative to.
    public var natural: Bool?
    /// The wheel speed for mice; absent for trackpads, which have none, and when never set.
    public var speed: Double?
    public var speedChanged: Date?

    public init(name: String, builtIn: Bool, own: Bool, reversed: Bool? = nil, reversedChanged: Date? = nil, natural: Bool? = nil,
                speed: Double? = nil, speedChanged: Date? = nil) {
        self.name = name
        self.builtIn = builtIn
        self.own = own
        self.reversed = reversed
        self.reversedChanged = reversedChanged
        self.natural = natural
        self.speed = speed
        self.speedChanged = speedChanged
    }

    /// The reverse switch that scrolls the same way here: flipped when the two Macs' Natural Scrolling differ.
    public func reversed(naturalHere: Bool) -> Bool? {
        guard let reversed else { return nil }
        guard let natural else { return reversed }
        return reversed != (natural != naturalHere)
    }

    /// A value without its time, or a speed the menu does not offer, is dropped rather than applied.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = LinkText.clean(try c.decode(String.self, forKey: .name))
        builtIn = (try? c.decodeIfPresent(Bool.self, forKey: .builtIn)) ?? false
        own = try c.decode(Bool.self, forKey: .own)
        natural = try? c.decodeIfPresent(Bool.self, forKey: .natural)
        reversedChanged = try? c.decodeIfPresent(Date.self, forKey: .reversedChanged)
        reversed = reversedChanged == nil ? nil : try? c.decodeIfPresent(Bool.self, forKey: .reversed)
        speedChanged = try? c.decodeIfPresent(Date.self, forKey: .speedChanged)
        speed = speedChanged == nil ? nil
            : (try? c.decodeIfPresent(Double.self, forKey: .speed)).flatMap { $0 }.flatMap { Policy.speedSteps.contains($0) ? $0 : nil }
    }
}

/// Which received settings this Mac takes. Keys name a device from this Mac's side: "own:" for one attached here,
/// "borrowed:" for one the other Mac lends it; each setting of a device has its own time under the key plus a suffix.
public enum SettingSync {
    /// How far ahead of this Mac's clock a received time may be. A peer's clock a little ahead is normal; a time beyond
    /// this would let it overrule every later change made here, so such a setting is not taken.
    public static let maxAhead: TimeInterval = 60

    public static func key(name: String, builtIn: Bool, own: Bool) -> String {
        (own ? "own:" : "borrowed:") + (builtIn ? "#built-in" : name.lowercased())
    }

    /// A name can identify a setting only while it identifies one physical device. Several HID services with the
    /// same serial are one device; without a serial, distinct identities are ambiguous. The built-in trackpad can
    /// expose several services too, but a built-in keyboard or pointer must never inherit its reserved key.
    public static func localKey(for device: Device, among devices: [Device]) -> String? {
        func base(_ device: Device) -> String? {
            let name = device.local ? device.name : device.lent ? String(device.name.dropFirst(2)) : nil
            guard let name, device.transport != "UniversalControl" else { return nil }
            let builtIn = name.hasPrefix("Apple Internal")
            guard !builtIn || device.trackpad else { return nil }
            return key(name: name, builtIn: builtIn, own: device.local)
        }
        guard let wanted = base(device) else { return nil }
        let matches = devices.filter { base($0) == wanted }
        guard !matches.isEmpty else { return nil }
        if wanted.hasSuffix(":#built-in") { return wanted }
        if !device.serial.isEmpty {
            guard matches.allSatisfy({ !$0.serial.isEmpty }), Set(matches.map { $0.serial.lowercased() }).count == 1 else { return nil }
        } else if Set(matches.map(\.key)).count != 1 { return nil }
        return wanted
    }

    public static func reverseKey(_ key: String) -> String { key + "|reverse" }
    public static func speedKey(_ key: String) -> String { key + "|speed" }

    /// Whether a received time is one this Mac can take.
    public static func plausible(_ date: Date, now: Date = Date()) -> Bool { date <= now.addingTimeInterval(maxAhead) }

    /// The time for a change made here: now, and never at or before one already stored, so a peer whose clock runs a
    /// little ahead cannot undo it.
    public static func stamp(after stored: Date?, now: Date = Date()) -> Date {
        guard let stored, stored >= now else { return now }
        return stored.addingTimeInterval(0.001)
    }

    /// The time a sharing switch takes when it is chosen at pairing. Both Macs choose at once and the later time wins,
    /// so an off ticked on either must beat an on from the other whichever confirmed last, however far apart their
    /// clocks are. Fixed times, not the clock: one second after 1970 for an off, at it for an on. Any change made
    /// after pairing is stamped with the clock and beats both.
    public static func pairingStamp(on: Bool) -> Date { Date(timeIntervalSince1970: on ? 0 : 1) }

    /// Whether a received time beats the one stored for that setting here.
    public static func takes(_ date: Date?, over stored: Date?, now: Date = Date()) -> Bool {
        guard let date, plausible(date, now: now) else { return false }
        return date > (stored ?? .distantPast)
    }

    /// The received settings with something newer than the last change made or taken here, with the local key each
    /// belongs to and which of its values to take.
    public static func newer(_ incoming: [LinkSetting], than changed: [String: Date], now: Date = Date())
        -> [(key: String, setting: LinkSetting, reverse: Bool, speed: Bool)] {
        let groups = Dictionary(grouping: incoming) { key(name: $0.name, builtIn: $0.builtIn, own: !$0.own) }
        return incoming.compactMap { setting in
            // The sender's own device is one this Mac borrows, and the other way round.
            let key = key(name: setting.name, builtIn: setting.builtIn, own: !setting.own)
            guard groups[key]?.count == 1 else { return nil }
            let reverse = setting.reversed != nil && takes(setting.reversedChanged, over: changed[reverseKey(key)], now: now)
            let speed = setting.speed != nil && takes(setting.speedChanged, over: changed[speedKey(key)], now: now)
            return reverse || speed ? (key, setting, reverse, speed) : nil
        }
    }
}

/// Decodes what it can and leaves out the rest, so one element a newer Halo shapes differently does not cost the whole
/// list, nor the connection.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

public struct LinkDevice: Codable, Equatable {
    /// What the row's glyph shows; an unknown kind from a newer Halo reads as `other`.
    public enum Kind: String, Codable {
        case mouse, trackpad, keyboard, headphones, speaker, other

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// The name as the sender's menu shows it.
    public var name: String
    public var kind: Kind
    public var battery: Int?
    /// On a cable. Absent from a Halo before 0.8.2, which reads as not charging.
    public var charging: Bool
    public var reversed: Bool
    public var pointing: Bool
    /// Part of the sender itself (its built-in trackpad), so the receiver names it in its own language.
    public var builtIn: Bool

    public init(name: String, kind: Kind, battery: Int?, charging: Bool = false, reversed: Bool, pointing: Bool, builtIn: Bool = false) {
        self.name = name
        self.kind = kind
        self.battery = battery
        self.charging = battery != nil && charging
        self.reversed = reversed
        self.pointing = pointing
        self.builtIn = builtIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = LinkText.clean(try c.decode(String.self, forKey: .name))
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        battery = (try? c.decodeIfPresent(Int.self, forKey: .battery)).flatMap { $0 }.flatMap { (0...100).contains($0) ? $0 : nil }
        charging = battery != nil && ((try? c.decodeIfPresent(Bool.self, forKey: .charging)).flatMap { $0 } ?? false)
        pointing = try c.decodeIfPresent(Bool.self, forKey: .pointing) ?? false
        let reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        self.reversed = pointing && reversed
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

enum LinkText {
    static let maxLength = 120
    /// One line of at most `maxLength` characters: control characters would break a menu row.
    static func clean(_ text: String) -> String {
        String(String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(maxLength))
    }
}

/// One side's half of a pairing: who it is and its one-time X25519 public key. See `PairingExchange`.
public struct LinkPairing: Codable, Equatable {
    public var peer: String
    public var computer: String
    public var key: Data

    public init(peer: String, computer: String, key: Data) {
        self.peer = peer
        self.computer = computer
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peer = try c.decode(String.self, forKey: .peer)
        computer = LinkText.clean(try c.decode(String.self, forKey: .computer))
        key = try c.decode(Data.self, forKey: .key)
        guard LinkKeys.isPeerID(peer), key.count == 32 else {
            throw DecodingError.dataCorruptedError(forKey: .peer, in: c, debugDescription: "bad pairing")
        }
    }
}

/// Everything that crosses the link. The one request is for the other Mac's clipboard, answered only with that Mac's
/// clipboard switch on; a snapshot's device settings are state the receiver matches only with its own switch on.
public enum LinkMessage: Equatable {
    /// Pairing, in order: a commitment to the sender's half, the half itself once the other's commitment arrived,
    /// and the proof that the person at the sender confirmed the digits match. See `PairingExchange`.
    case pairCommit(Data)
    case pairReveal(LinkPairing)
    case pairConfirm(Data)
    /// The first message on a long-term connection, naming who holds the key.
    case hello(peer: String)
    case snapshot(LinkSnapshot)
    /// The sender's latest link check, so each side can show what the other measured.
    case report(LinkCheck)
    /// A clipboard, sent when the person leaves the sender's Mac after copying there, or when asked for; its bytes
    /// follow as chunks. The receiver writes it to its own clipboard only with its clipboard switch on.
    case clip(LinkClip)
    case clipChunk(LinkClipChunk)
    /// Asks for the sender's current clipboard, from the menu; answered only with the receiver's clipboard switch on.
    case clipRequest
    /// Why a clipboard was not sent, as a `ClipDecline` raw value; one from a newer Halo may be unknown.
    case clipDeclined(String)
    /// Universal Control between the two Macs: one dropped the other's keyboard and pointer, or the other's input is
    /// stuck on its way over and later came back. See `LinkHandoff`.
    case handoff(LinkHandoff)
    /// The sender deleted the pairing; the receiver forgets it too. Accepted only on the paired connection.
    case unpaired
}

/// What one Mac tells the other about Universal Control. A Mac that drops the devices the other lends it says
/// `dropped`; the other, if its own input is still routed away a moment later, is stuck until its Universal Control
/// notices, and says `stalled`, then `recovered` with how long it lasted, or `cleared` if it gave up waiting.
public struct LinkHandoff: Codable, Equatable {
    public enum Event: String {
        case dropped, stalled, recovered, cleared
        /// The devices the other Mac said it dropped were lent to it again: they were not lost.
        case lentAgain
    }
    /// An `Event` raw value, kept as a string on the wire so one a newer Halo adds does not break the frame.
    public let event: String
    /// Whole seconds the input was stuck, with `recovered`.
    public let seconds: Int?
    public var kind: Event? { Event(rawValue: event) }
    public init(_ kind: Event, seconds: Int? = nil) {
        self.event = kind.rawValue
        self.seconds = seconds
    }
}

/// Messages on the wire: a 4-byte big-endian length, then that many bytes of JSON.
public enum LinkFrame {
    /// Far above any real snapshot (a few hundred bytes per device); anything larger closes the connection.
    public static let maxBody = 64 * 1024

    private struct Envelope: Codable {
        var type: String
        var pair: LinkPairing?
        var proof: Data?
        var peer: String?
        var snapshot: LinkSnapshot?
        var report: LinkCheck?
        var clip: LinkClip?
        var chunk: LinkClipChunk?
        var reason: String?
        var handoff: LinkHandoff?

        init(type: String, pair: LinkPairing? = nil, proof: Data? = nil, peer: String? = nil, snapshot: LinkSnapshot? = nil, report: LinkCheck? = nil,
             clip: LinkClip? = nil, chunk: LinkClipChunk? = nil, reason: String? = nil, handoff: LinkHandoff? = nil) {
            self.type = type
            self.pair = pair
            self.proof = proof
            self.peer = peer
            self.snapshot = snapshot
            self.report = report
            self.clip = clip
            self.chunk = chunk
            self.reason = reason
            self.handoff = handoff
        }

        /// Each payload on its own: one this version cannot read leaves the rest of the frame readable, so the
        /// message can be told apart from a frame that is not a message at all.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            pair = try? c.decodeIfPresent(LinkPairing.self, forKey: .pair)
            proof = try? c.decodeIfPresent(Data.self, forKey: .proof)
            peer = try? c.decodeIfPresent(String.self, forKey: .peer)
            snapshot = try? c.decodeIfPresent(LinkSnapshot.self, forKey: .snapshot)
            report = try? c.decodeIfPresent(LinkCheck.self, forKey: .report)
            clip = try? c.decodeIfPresent(LinkClip.self, forKey: .clip)
            chunk = try? c.decodeIfPresent(LinkClipChunk.self, forKey: .chunk)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            handoff = try? c.decodeIfPresent(LinkHandoff.self, forKey: .handoff)
        }
    }

    /// `unreadable`: a well-formed message of a known kind whose contents this version cannot read (a newer Halo's
    /// snapshot, say). On a verified connection it is skipped; everything else ends the connection.
    public enum Failure: Error, Equatable { case oversized, malformed, unreadable(String) }

    public static func encode(_ message: LinkMessage) throws -> Data {
        let envelope: Envelope
        switch message {
        case .pairCommit(let proof): envelope = Envelope(type: "pairCommit", proof: proof)
        case .pairReveal(let pairing): envelope = Envelope(type: "pairReveal", pair: pairing)
        case .pairConfirm(let proof): envelope = Envelope(type: "pairConfirm", proof: proof)
        case .hello(let peer): envelope = Envelope(type: "hello", peer: peer)
        case .snapshot(let snapshot): envelope = Envelope(type: "snapshot", snapshot: snapshot)
        case .report(let report): envelope = Envelope(type: "report", report: report)
        case .clip(let clip): envelope = Envelope(type: "clip", clip: clip)
        case .clipChunk(let chunk): envelope = Envelope(type: "chunk", chunk: chunk)
        case .clipRequest: envelope = Envelope(type: "clipRequest")
        case .clipDeclined(let reason): envelope = Envelope(type: "clipDeclined", reason: reason)
        case .handoff(let handoff): envelope = Envelope(type: "handoff", handoff: handoff)
        case .unpaired: envelope = Envelope(type: "unpaired")
        }
        let encoder = JSONEncoder()
        // Stable bytes for the same content, so an unchanged snapshot is recognised and not sent again.
        // Unescaped slashes: base64 is full of them, and "\/" would double a chunk past the frame cap.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(envelope)
        guard body.count <= maxBody else { throw Failure.oversized }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The body length a header announces, or nil when it is empty or over the cap.
    public static func bodyLength(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        return (1...maxBody).contains(length) ? length : nil
    }

    /// A message, or nil for a type this version does not know (ignored, so a newer peer can add some).
    /// Throws for anything that is not a well-formed message.
    public static func decode(body: Data) throws -> LinkMessage? {
        guard body.count <= maxBody else { throw Failure.oversized }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: body) } catch { throw Failure.malformed }
        switch envelope.type {
        case "pairCommit":
            guard let proof = envelope.proof, proof.count == 32 else { throw Failure.malformed }
            return .pairCommit(proof)
        case "pairReveal":
            guard let pair = envelope.pair else { throw Failure.malformed }
            return .pairReveal(pair)
        case "pairConfirm":
            guard let proof = envelope.proof, proof.count == 32 else { throw Failure.malformed }
            return .pairConfirm(proof)
        case "hello":
            guard let peer = envelope.peer, LinkKeys.isPeerID(peer) else { throw Failure.malformed }
            return .hello(peer: peer)
        case "snapshot":
            guard let snapshot = envelope.snapshot else { throw Failure.unreadable(envelope.type) }
            return .snapshot(snapshot)
        case "report":
            guard let report = envelope.report else { throw Failure.unreadable(envelope.type) }
            return .report(report)
        case "clip":
            guard let clip = envelope.clip else { throw Failure.unreadable(envelope.type) }
            return .clip(clip)
        case "chunk":
            guard let chunk = envelope.chunk else { throw Failure.unreadable(envelope.type) }
            return .clipChunk(chunk)
        case "clipRequest":
            return .clipRequest
        case "clipDeclined":
            guard let reason = envelope.reason else { throw Failure.unreadable(envelope.type) }
            return .clipDeclined(String(reason.prefix(40)))
        case "handoff":
            // An event a newer Halo added is not this version's to act on.
            guard let handoff = envelope.handoff else { throw Failure.unreadable(envelope.type) }
            guard handoff.kind != nil else { return nil }
            return .handoff(handoff)
        case "unpaired":
            return .unpaired
        default:
            return nil
        }
    }
}

/// Sends a snapshot only when its encoding differs from the last one sent on this connection.
public struct LinkOutbox {
    private var lastSent: Data?
    public init() {}

    /// The frame to send, or nil when the peer already has exactly this. Throws when it cannot be sent at all (over
    /// the frame cap).
    public mutating func frame(for snapshot: LinkSnapshot) throws -> Data? {
        let frame = try LinkFrame.encode(.snapshot(snapshot))
        guard frame != lastSent else { return nil }
        lastSent = frame
        return frame
    }

    /// A new connection starts from nothing, so its first snapshot always goes out.
    public mutating func reset() { lastSent = nil }
}

public enum LinkKeys {
    /// How long a Mac looks for the other one to pair with, and how long the people get to compare the digits.
    public static let searchTime: TimeInterval = 180
    public static let compareTime: TimeInterval = 90

    public static func newPeerID() -> String { UUID().uuidString }
    public static func isPeerID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString == text }

    /// The 32-byte long-term key both sides arrive at after pairing, bound to both peer IDs.
    public static func longTermKey(own: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, ids: [String]) throws -> Data {
        let shared = try own.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("Halo Link v1".utf8),
                                                 sharedInfo: Data(ids.sorted().joined(separator: "|").utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

extension LinkSnapshot {
    /// Which of the paired Mac's devices one it lends through Universal Control is, or nil if it reports none such:
    /// by name, without the "V-" Universal Control puts before it; a built-in one by being built in and its kind, since
    /// that Mac names it in its own language. `taken`: slots other lent devices already fill, so two of the same name
    /// fill two. `anyKind`: a built-in one may also fill a built-in slot of another kind, for a second pass once every
    /// lent device had its chance at its own kind.
    public func index(ofLent device: Device, taken: Set<Int> = [], anyKind: Bool = false) -> Int? {
        guard device.lent else { return nil }
        let name = String(device.name.dropFirst(2))
        let builtIn = name.hasPrefix("Apple Internal")
        return devices.indices.first { index in
            let there = devices[index]
            guard !taken.contains(index) else { return false }
            if builtIn { return there.builtIn && there.pointing && (anyKind || (there.kind == .trackpad) == device.trackpad) }
            return !there.builtIn && there.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Where each lent device goes in this list, by its position in `lent`: same-kind matches first, then the rest.
    public func slots(ofLent lent: [Device]) -> [Int: Int] {
        var slots: [Int: Int] = [:], taken = Set<Int>()
        for anyKind in [false, true] {
            for (position, device) in lent.enumerated() where slots[position] == nil {
                guard let index = index(ofLent: device, taken: taken, anyKind: anyKind) else { continue }
                slots[position] = index
                taken.insert(index)
            }
        }
        return slots
    }
}
