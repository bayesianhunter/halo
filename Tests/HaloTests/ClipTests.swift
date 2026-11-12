// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import XCTest
@testable import HaloCore

/// The clipboard between the two Macs without the network: packing, the frame cap, reassembly and what never leaves.
final class ClipTests: XCTestCase {
    func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

    func testAScreenshotRoundTripsInChunksUnderTheFrameCap() throws {
        let text = Data("Halo 0.6.0".utf8), png = bytes(1_272_735)
        let packed = try XCTUnwrap(LinkClip.pack([("public.utf8-plain-text", text), ("public.png", png)]))
        XCTAssertEqual(packed.clip.total, text.count + png.count)
        XCTAssertEqual(packed.chunks.count, (packed.clip.total + LinkClip.chunkSize - 1) / LinkClip.chunkSize)
        var assembler = ClipAssembler()
        guard case .clip(let header)? = try LinkFrame.decode(body: LinkFrame.encode(.clip(packed.clip)).dropFirst(4)) else {
            return XCTFail("header expected")
        }
        XCTAssertEqual(header, packed.clip)
        assembler.begin(header)
        var result: [(type: String, data: Data)]?
        for chunk in packed.chunks {
            let frame = try LinkFrame.encode(.clipChunk(chunk))
            XCTAssertLessThanOrEqual(frame.count - 4, LinkFrame.maxBody)
            guard case .clipChunk(let read)? = try LinkFrame.decode(body: frame.dropFirst(4)) else { return XCTFail("chunk expected") }
            XCTAssertNil(result, "nothing after the last chunk")
            result = try assembler.add(read)
        }
        XCTAssertEqual(result?.map(\.type), ["public.utf8-plain-text", "public.png"])
        XCTAssertEqual(result?.map(\.data), [text, png])
    }

    /// Sizes that would overflow when added up are refused one by one, before the sum is taken.
    func testAHeaderCannotOverflowTheTotal() {
        let sha = Data(repeating: 1, count: 32).base64EncodedString()
        let json = #"{"type":"clip","clip":{"id":"\#(UUID().uuidString)","items":[{"type":"a","size":9223372036854775807},{"type":"b","size":1}],"sha256":"\#(sha)"}}"#
        XCTAssertThrowsError(try LinkFrame.decode(body: Data(json.utf8)))
    }

    /// Base64 is full of "/"; escaped as "\/" a chunk of the worst bytes would no longer fit a frame.
    func testAChunkOfTheWorstBytesStillFitsAFrame() throws {
        let chunk = LinkClipChunk(id: UUID().uuidString, index: 0, data: Data(repeating: 0xFF, count: LinkClip.chunkSize))
        XCTAssertLessThanOrEqual(try LinkFrame.encode(.clipChunk(chunk)).count - 4, LinkFrame.maxBody)
    }

    func testNothingOverTheCapOrOfUnknownTypesIsPacked() {
        XCTAssertNil(LinkClip.pack([("public.png", bytes(LinkClip.maxTotal + 1))]))
        XCTAssertNil(LinkClip.pack([("public.file-url", Data("file:///etc/hosts".utf8))]))
        XCTAssertNil(LinkClip.pack([]))
    }

    func testChunksThatDoNotFitAreRefused() throws {
        let packed = try XCTUnwrap(LinkClip.pack([("public.png", bytes(LinkClip.chunkSize * 2 + 10))]))
        var assembler = ClipAssembler()
        assembler.begin(packed.clip)
        XCTAssertThrowsError(try assembler.add(packed.chunks[1]), "out of order")
        assembler.begin(packed.clip)
        var tampered = packed.chunks
        tampered[2].data[0] ^= 1
        XCTAssertNil(try assembler.add(tampered[0]))
        XCTAssertNil(try assembler.add(tampered[1]))
        XCTAssertThrowsError(try assembler.add(tampered[2]), "the hash catches a changed byte")
        XCTAssertThrowsError(try assembler.add(packed.chunks[0]), "a failed clip is forgotten")
    }

    func testHeadersAreDefensiveButAllowNewerTypes() throws {
        func header(_ items: String, id: String = UUID().uuidString) throws -> LinkMessage? {
            let sha = Data(repeating: 1, count: 32).base64EncodedString()
            return try LinkFrame.decode(body: Data(#"{"type":"clip","clip":{"id":"\#(id)","items":[\#(items)],"sha256":"\#(sha)"}}"#.utf8))
        }
        XCTAssertThrowsError(try header(#"{"type":"public.png","size":\#(LinkClip.maxTotal + 1)}"#))
        XCTAssertThrowsError(try header(""))
        XCTAssertThrowsError(try header(#"{"type":"public.png","size":0}"#))
        XCTAssertThrowsError(try header(#"{"type":"public.png","size":5}"#, id: "x"))
        XCTAssertNotNil(try header(#"{"type":"public.file-url","size":5}"#), "a newer Halo may send a type this one leaves out")
    }

    func testTheAssemblerLeavesOutTypesItDoesNotKnow() throws {
        let png = bytes(100), future = Data("future".utf8)
        let joined = future + png
        let clip = LinkClip(id: UUID().uuidString, items: [.init(type: "public.file-url", size: future.count), .init(type: "public.png", size: png.count)],
                            sha256: Data(SHA256.hash(data: joined)))
        var assembler = ClipAssembler()
        assembler.begin(clip)
        let items = try assembler.add(LinkClipChunk(id: clip.id, index: 0, data: joined))
        XCTAssertEqual(items?.map(\.type), ["public.png"])
        XCTAssertEqual(items?.first?.data, png)
    }

    /// A transfer broken off (the screen locked mid-way, so the header was forgotten) fails once, not once per chunk.
    func testABrokenTransferFailsOnce() throws {
        var assembler = ClipAssembler()
        let id = UUID().uuidString
        XCTAssertThrowsError(try assembler.add(LinkClipChunk(id: id, index: 3, data: Data([1]))))
        for index in 4..<10 { XCTAssertNil(try assembler.add(LinkClipChunk(id: id, index: index, data: Data([1])))) }
        let png = bytes(10)
        let clip = LinkClip(id: UUID().uuidString, items: [.init(type: "public.png", size: png.count)], sha256: Data(SHA256.hash(data: png)))
        assembler.begin(clip)
        XCTAssertEqual(try assembler.add(LinkClipChunk(id: clip.id, index: 0, data: png))?.first?.data, png, "the next clip comes through")
    }

    func testPasswordsGoMarkedButMomentaryAndForwardedClipboardsStay() throws {
        let packed = try XCTUnwrap(LinkClip.pack([("public.utf8-plain-text", Data("hunter2".utf8))], concealed: true))
        guard case .clip(let header)? = try LinkFrame.decode(body: LinkFrame.encode(.clip(packed.clip)).dropFirst(4)) else {
            return XCTFail("header expected")
        }
        XCTAssertEqual(header.concealed, true)
        XCTAssertNil(LinkClip.pack([("public.utf8-plain-text", Data("hi".utf8))])?.clip.concealed)

        XCTAssertTrue(ClipFilter.mayShare(["public.utf8-plain-text", "public.html"]))
        XCTAssertTrue(ClipFilter.mayShare(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), "a password may be meant for the other Mac")
        XCTAssertTrue(ClipFilter.isConcealed(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ClipFilter.isConcealed(["public.utf8-plain-text"]), "a password copied from a plain note looks like any text")
        XCTAssertFalse(ClipFilter.mayShare(["public.utf8-plain-text", "org.nspasteboard.TransientType"]), "put there for a moment")
        XCTAssertFalse(ClipFilter.mayShare(["public.png", "com.apple.is-remote-clipboard"]), "Universal Clipboard already brought it")
        XCTAssertFalse(ClipFilter.mayShare([]))
    }

    /// Only a copy made during this stay is sent on leaving; Halo's own write is not one.
    func testOnlyACopyMadeHereIsSentOnLeaving() {
        var visit = ClipVisit()
        XCTAssertFalse(visit.left(count: 5), "Halo started while the person was elsewhere")
        visit.arrived(count: 5)
        XCTAssertFalse(visit.left(count: 5))
        visit.arrived(count: 5)
        visit.wrote(count: 6)
        XCTAssertFalse(visit.left(count: 6), "what came from the other Mac does not go back")
        visit.arrived(count: 6)
        XCTAssertFalse(visit.copied(count: 6))
        XCTAssertTrue(visit.copied(count: 7), "a copy made here since arriving is not overwritten")
        XCTAssertTrue(visit.left(count: 7))
    }

    func testSnapshotsSayWhetherClipboardsAreTaken() throws {
        let snapshot = LinkSnapshot(computer: "Studio", active: true, devices: [], clipboard: true,
                                    sharing: LinkSharing(clipboard: true, clipboardChanged: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(try LinkFrame.decode(body: LinkFrame.encode(.snapshot(snapshot)).dropFirst(4)), .snapshot(snapshot))
        let old = #"{"type":"snapshot","snapshot":{"computer":"Studio","devices":[]}}"#
        guard case .snapshot(let read)? = try LinkFrame.decode(body: Data(old.utf8)) else { return XCTFail("snapshot expected") }
        XCTAssertFalse(read.clipboard, "a snapshot without the switch reads as off")
        XCTAssertNil(read.sharing)
        XCTAssertEqual(try LinkFrame.decode(body: LinkFrame.encode(.clipRequest).dropFirst(4)), .clipRequest)
        XCTAssertEqual(try LinkFrame.decode(body: LinkFrame.encode(.clipDeclined(ClipDecline.locked.rawValue)).dropFirst(4)), .clipDeclined("locked"))
        XCTAssertNil(ClipDecline(rawValue: "future"), "a reason from a newer Halo reads as unknown, not as an error")
    }

    // MARK: ClipEra: a clipboard packed or previewed in the background, and what may still happen to it.

    func testAJobFromTheCurrentEraGoesOnWhileSharing() {
        let era = ClipEra()
        XCTAssertTrue(era.allows(era.current, enabled: true, locked: false))
    }

    /// Turned off, locked or asleep while the job ran: dropped, even with the switch back on before it is done.
    func testAJobFromBeforeForgettingIsDropped() {
        var era = ClipEra()
        let began = era.current
        era.end()
        XCTAssertFalse(era.allows(began, enabled: true, locked: false))
        XCTAssertTrue(era.allows(era.current, enabled: true, locked: false))
    }

    func testOffOrLockedDropsEvenInTheSameEra() {
        let era = ClipEra()
        XCTAssertFalse(era.allows(era.current, enabled: false, locked: false))
        XCTAssertFalse(era.allows(era.current, enabled: true, locked: true))
    }
}
