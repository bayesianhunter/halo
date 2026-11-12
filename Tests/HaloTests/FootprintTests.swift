// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// What Uninstall takes away: only Halo's own places under a home, and only Halo's own skill links. Every test uses a
/// home of its own in the temporary folder, never the person's.
final class FootprintTests: XCTestCase {
    var home: URL!
    var footprint: Footprint { Footprint(home: home) }
    let files = FileManager.default

    override func setUpWithError() throws {
        home = files.temporaryDirectory.appendingPathComponent("halo-home-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: home)
    }

    private func make(_ path: String, folder: Bool = false) throws {
        let url = home.appendingPathComponent(path)
        try files.createDirectory(at: folder ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !folder { try Data("x".utf8).write(to: url) }
    }

    private func link(_ path: String, to target: String) throws {
        let url = home.appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    func testAnEmptyHomeHasNothing() {
        XCTAssertEqual(footprint.present(), [])
    }

    func testEveryPlaceIsUnderTheHomeAndHalosOwn() {
        for url in footprint.files + footprint.skillLinks {
            XCTAssertTrue(url.path.hasPrefix(home.path + "/"), url.path)
            XCTAssertTrue(url.path.contains("Halo") || url.path.contains(Footprint.bundleID) || url.lastPathComponent == "halo", url.path)
        }
    }

    func testListsWhatIsThereInOrder() throws {
        try make("Library/Caches/com.liuzhekan.Halo", folder: true)
        try make("Library/Application Support/Halo/rules.json")
        try make("Library/Preferences/com.liuzhekan.Halo.plist")
        try make("Library/Application Support/Other/rules.json")
        XCTAssertEqual(footprint.present().map(footprint.shown),
                       ["~/Library/Application Support/Halo", "~/Library/Preferences/com.liuzhekan.Halo.plist",
                        "~/Library/Caches/com.liuzhekan.Halo"])
    }

    func testOnlyHalosOwnSkillLinks() throws {
        try link(".agents/skills/halo", to: "/Applications/Halo.app/Contents/Resources/AgentSkill/")
        // Someone's own skill of that name, and a link to somewhere else, are theirs.
        try make(".claude/skills/halo", folder: true)
        XCTAssertEqual(footprint.present().map(footprint.shown), ["~/.agents/skills/halo"])
        try files.removeItem(at: home.appendingPathComponent(".claude/skills/halo"))
        try link(".claude/skills/halo", to: "/Users/someone/skills/halo")
        XCTAssertEqual(footprint.present().map(footprint.shown), ["~/.agents/skills/halo"])
    }

    func testABrokenLinkOfHalosIsStillListed() throws {
        try link(".claude/skills/halo", to: "/Volumes/Gone/Halo.app/Contents/Resources/AgentSkill")
        XCTAssertEqual(footprint.present().map(footprint.shown), ["~/.claude/skills/halo"])
    }

    func testRemoveHandsEachToTheTrashAndReportsFailures() throws {
        try make("Library/Application Support/Halo/rules.json")
        try make("Library/Caches/com.liuzhekan.Halo", folder: true)
        var trashed: [String] = []
        let failed = footprint.remove(footprint.present()) { url in
            if url.lastPathComponent == "com.liuzhekan.Halo" { throw CocoaError(.fileWriteNoPermission) }
            trashed.append(footprint.shown(url))
        }
        XCTAssertEqual(trashed, ["~/Library/Application Support/Halo"])
        XCTAssertEqual(failed.map(footprint.shown), ["~/Library/Caches/com.liuzhekan.Halo"])
    }

    func testAStoppedEventLogWritesNothingMore() {
        let folder = home.appendingPathComponent("Library/Application Support/Halo/events", isDirectory: true)
        let log = EventLog(folder: folder)
        log.stop()
        log.record(EventRecord(kind: .app, event: "late"))
        log.flush()
        XCTAssertFalse(files.fileExists(atPath: folder.path))
    }
}
