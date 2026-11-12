// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// A clipboard handed to the paired Mac: what it holds and how big each part is, followed by the bytes in chunks.
/// It lives only in memory on both Macs.
public struct LinkClip: Codable, Equatable {
    /// A screenshot of a large display fits; anything bigger is not sent.
    public static let maxTotal = 16 * 1024 * 1024
    /// Raw bytes per chunk: base64 inside JSON makes it about 43 KB, well under the 64 KB frame cap.
    public static let chunkSize = 32 * 1024
    /// Text, rich text, web text and images. Files and anything an app made up stay behind.
    public static let types = ["public.utf8-plain-text", "public.rtf", "public.html", "public.png"]

    public struct Item: Codable, Equatable {
        public var type: String
        public var size: Int

        public init(type: String, size: Int) {
            self.type = type
            self.size = size
        }
    }

    public var id: String
    public var items: [Item]
    /// Of all items' bytes in order, checked once the last chunk is in.
    public var sha256: Data
    /// Marked as a password by the app it came from: the receiver keeps the mark, shows no preview and clears it soon.
    public var concealed: Bool?

    public var total: Int { items.reduce(0) { $0 + $1.size } }

    public init(id: String, items: [Item], sha256: Data, concealed: Bool? = nil) {
        self.id = id
        self.items = items
        self.sha256 = sha256
        self.concealed = concealed
    }

    /// Refuses a header that cannot describe a real clip before a single chunk is kept. A type this version does not
    /// know is allowed, since a newer Halo may send one; the assembler leaves it out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        items = try c.decode([Item].self, forKey: .items)
        sha256 = try c.decode(Data.self, forKey: .sha256)
        concealed = try? c.decodeIfPresent(Bool.self, forKey: .concealed)
        let types = items.map(\.type)
        // Each size is bounded before they are added up, so a hostile header cannot overflow the sum.
        guard UUID(uuidString: id) != nil, (1...8).contains(items.count), Set(types).count == types.count,
              types.allSatisfy({ (1...200).contains($0.count) }), items.allSatisfy({ (1...Self.maxTotal).contains($0.size) }),
              total <= Self.maxTotal, sha256.count == 32 else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "bad clip")
        }
    }

    /// The header and the chunks for these items; nil when there is nothing to send or it is over the cap.
    public static func pack(_ items: [(type: String, data: Data)], concealed: Bool = false) -> (clip: LinkClip, chunks: [LinkClipChunk])? {
        let items = items.filter { types.contains($0.type) && !$0.data.isEmpty }
        let bytes = items.reduce(into: Data()) { $0.append($1.data) }
        guard !items.isEmpty, bytes.count <= maxTotal else { return nil }
        let clip = LinkClip(id: UUID().uuidString, items: items.map { Item(type: $0.type, size: $0.data.count) },
                            sha256: Data(SHA256.hash(data: bytes)), concealed: concealed ? true : nil)
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).enumerated().map { index, start in
            LinkClipChunk(id: clip.id, index: index, data: bytes.subdata(in: start..<min(start + chunkSize, bytes.count)))
        }
        return (clip, chunks)
    }
}

public struct LinkClipChunk: Codable, Equatable {
    public var id: String
    public var index: Int
    public var data: Data

    public init(id: String, index: Int, data: Data) {
        self.id = id
        self.index = index
        self.data = data
    }
}

/// Puts a clip back together from its header and chunks, in order, and hands over the items once the hash matches.
public struct ClipAssembler {
    public enum Failure: Error { case unexpected, oversized, corrupt }

    private var clip: LinkClip?
    private var buffer = Data()
    private var next = 0
    /// The clip given up on: its remaining chunks are let pass quietly, so one broken transfer is one failure, not
    /// one per chunk.
    private var abandoned: String?
    public init() {}

    /// A new header drops whatever was still arriving.
    public mutating func begin(_ clip: LinkClip) {
        // A header sent again starts that clip afresh.
        if clip.id == abandoned { abandoned = nil }
        self.clip = clip
        buffer = Data()
        next = 0
    }

    /// The items this Mac knows once this chunk completes the clip (empty when it knows none), nil while more are due
    /// or when the chunk belongs to a clip already given up on. Throws, and gives the clip up, when the chunk does not
    /// fit it.
    public mutating func add(_ chunk: LinkClipChunk) throws -> [(type: String, data: Data)]? {
        if chunk.id == abandoned { return nil }
        guard let clip, chunk.id == clip.id, chunk.index == next else { abandon(chunk.id); throw Failure.unexpected }
        guard chunk.data.count <= LinkClip.chunkSize, buffer.count + chunk.data.count <= clip.total else {
            abandon(clip.id)
            throw Failure.oversized
        }
        buffer.append(chunk.data)
        next += 1
        guard buffer.count == clip.total else { return nil }
        defer { reset() }
        guard Data(SHA256.hash(data: buffer)) == clip.sha256 else { throw Failure.corrupt }
        var offset = buffer.startIndex
        return clip.items.compactMap { item in
            defer { offset += item.size }
            return LinkClip.types.contains(item.type) ? (item.type, buffer.subdata(in: offset..<offset + item.size)) : nil
        }
    }

    private mutating func reset() {
        clip = nil
        buffer = Data()
        next = 0
    }

    private mutating func abandon(_ id: String) {
        reset()
        abandoned = id
    }
}

/// Why a Mac kept its clipboard: something an app put there for a moment or forwarded, a locked screen, over the cap,
/// macOS not letting Halo read it without asking, or nothing Halo carries.
public enum ClipDecline: String, Codable, Error {
    case privateContents = "private", locked, tooLarge, notAllowed, empty
}

/// Decided from the clipboard's types alone (the markers of nspasteboard.org, older names included), never its contents.
public enum ClipFilter {
    /// What an app put there for a moment or made up itself, rather than something the person copied, and what
    /// Universal Clipboard already brought in from another device. None of it goes to the other Mac.
    public static let kept: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping", "Pasteboard generator type", "com.apple.is-remote-clipboard",
    ]
    /// A password copied from a password manager. It does go over, since the person may well mean to paste it there.
    public static let concealed: Set<String> = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"]

    public static func mayShare(_ types: [String]) -> Bool {
        !types.isEmpty && kept.isDisjoint(with: types)
    }

    public static func isConcealed(_ types: [String]) -> Bool {
        !concealed.isDisjoint(with: types)
    }
}

/// Tracks the clipboard over one stay on this Mac: what it was when the person arrived, so on leaving Halo knows
/// whether they copied something here. Halo's own writes move the baseline, so they never count as a copy.
public struct ClipVisit {
    private var baseline: Int?
    public init() {}

    public mutating func arrived(count: Int) { baseline = count }
    public mutating func wrote(count: Int) { baseline = count }

    /// Whether the person copied something here since arriving, or since Halo last wrote the clipboard.
    public func copied(count: Int) -> Bool { baseline.map { $0 != count } ?? false }

    /// On leaving: whether the clipboard changed since the person arrived or Halo last wrote it.
    public mutating func left(count: Int) -> Bool {
        defer { baseline = count }
        guard let baseline else { return false }
        return count != baseline
    }
}

/// What a clipboard handed to a background job may still do when the job is done. Sleep, a locked screen, the switch
/// turned off or unpairing start a new era; a job from an earlier one is dropped, even if the switch is back on by then.
public struct ClipEra {
    public private(set) var current = 0
    public init() {}

    /// Everything from before this is gone.
    public mutating func end() { current &+= 1 }

    /// Whether a job begun in `era` may still send or write: the same era, sharing on, the screen not locked.
    public func allows(_ era: Int, enabled: Bool, locked: Bool) -> Bool {
        era == current && enabled && !locked
    }
}
