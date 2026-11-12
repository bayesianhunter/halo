// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// A damaged state file is kept aside rather than saved over.
final class StateFileTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("halo-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testAbsentLoadedAndDamaged() throws {
        let url = folder.appendingPathComponent("rules.json")
        guard case .absent = StateFile.load([String: String].self, from: url) else { return XCTFail("no file is a first run") }

        try Data(#"{"a":"reverse"}"#.utf8).write(to: url)
        guard case .loaded(let rules) = StateFile.load([String: String].self, from: url) else { return XCTFail("a good file loads") }
        XCTAssertEqual(rules, ["a": "reverse"])

        let damaged = Data(#"{"a":"rev"#.utf8)
        try damaged.write(to: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .unreadable(let data, let kept) = StateFile.load([String: String].self, from: url, now: now) else {
            return XCTFail("a cut-off file is unreadable")
        }
        XCTAssertEqual(data, damaged)
        let name = try XCTUnwrap(kept)
        XCTAssertTrue(name.hasPrefix("rules.json.unreadable-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved, so the next save does not destroy it")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), damaged)
        guard case .absent = StateFile.load([String: String].self, from: url) else { return XCTFail("afterwards it starts afresh") }
    }

    func testANewerHalosFileIsLeftInPlace() throws {
        let url = folder.appendingPathComponent("rules.json")
        let newer = Data(#"{"a":{"rule":"reverse","since":3}}"#.utf8)
        try newer.write(to: url)
        guard case .unreadable(let data, let kept) = StateFile.load([String: String].self, from: url) else {
            return XCTFail("a shape this version does not know is not loaded")
        }
        XCTAssertEqual(data, newer)
        XCTAssertNil(kept, "sound JSON from a newer Halo stays for it, after a downgrade and back")
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }
}
