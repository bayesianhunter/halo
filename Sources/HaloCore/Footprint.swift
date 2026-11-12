// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Everything Halo puts on a Mac outside its own app: fixed places under the person's home, each Halo's alone, so
/// taking them away again touches nothing of anyone else's. Not here: the pairing key in the keychain and Open at
/// Login, which the app removes through its own unpair and login switch; the app itself; and macOS's privacy lists,
/// which only the person can edit.
public struct Footprint {
    public static let bundleID = "com.liuzhekan.Halo"

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// Halo's own files and folders: its state, its preferences, and what macOS keeps for it (caches, web storage for
    /// update notes, window state). The order is the order they are listed in.
    public var files: [URL] {
        ["Library/Application Support/Halo",
         "Library/Preferences/\(Self.bundleID).plist",
         "Library/Caches/\(Self.bundleID)",
         "Library/HTTPStorages/\(Self.bundleID)",
         "Library/HTTPStorages/\(Self.bundleID).binarycookies",
         "Library/WebKit/\(Self.bundleID)",
         "Library/Saved Application State/\(Self.bundleID).savedState"].map { home.appendingPathComponent($0) }
    }

    /// Where the Agent Skill is linked from: `~/.agents/skills` and `~/.claude/skills`.
    public var skillLinks: [URL] {
        [".agents/skills", ".claude/skills"].map { home.appendingPathComponent("\($0)/halo", isDirectory: true) }
    }

    /// A link into some copy of Halo's bundled skill. Anything else at that place, a folder or someone's own link, is
    /// theirs.
    public static func isHaloSkill(target: String) -> Bool {
        (target.hasSuffix("/") ? String(target.dropLast()) : target).hasSuffix("/Contents/Resources/AgentSkill")
    }

    /// The skill links that are Halo's.
    public func ownSkillLinks(_ files: FileManager = .default) -> [URL] {
        skillLinks.filter { (try? files.destinationOfSymbolicLink(atPath: $0.path)).map(Self.isHaloSkill) == true }
    }

    /// What is there now: Halo's files that exist, then its skill links.
    public func present(_ files: FileManager = .default) -> [URL] {
        // The item itself, not what a link at that place points to.
        self.files.filter { (try? files.attributesOfItem(atPath: $0.path)) != nil } + ownSkillLinks(files)
    }

    /// Hands each of `urls` to `trash`, which moves it to the Trash; returns the ones it could not.
    public func remove(_ urls: [URL], trash: (URL) throws -> Void) -> [URL] {
        urls.filter {
            do {
                try trash($0)
                return false
            } catch {
                return true
            }
        }
    }

    /// As people read it: under the home folder, with `~`.
    public func shown(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}
