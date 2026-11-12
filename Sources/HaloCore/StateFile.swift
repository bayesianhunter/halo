// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Halo's small JSON state files (rules, speeds, switches, the pairing). A file that exists but cannot be read is
/// never silently saved over: a damaged one is moved aside, and one that is sound JSON in a shape this version does not
/// know (written by a newer Halo, before a downgrade) is left in place for that version, and the caller does not save
/// over it.
public enum StateFile {
    public enum Load<Value> {
        /// No file yet: a first run.
        case absent
        case loaded(Value)
        /// The file was there but did not decode. `data` is what it held, for salvaging what still reads. `keptAs` is
        /// the name it was moved to beside the original; nil when it is still in place (unreadable as a file, sound
        /// JSON from a newer Halo, or a move that failed), and then the caller must not save over it.
        case unreadable(data: Data?, keptAs: String?)
    }

    public static func load<Value: Decodable>(_ type: Value.Type, from url: URL, now: Date = Date(),
                                               decoder: JSONDecoder = JSONDecoder()) -> Load<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data = try? Data(contentsOf: url)
        if let data, let value = try? decoder.decode(type, from: data) { return .loaded(value) }
        // Unreadable as a file (permissions), or well-formed JSON a newer Halo wrote: left where it is.
        guard let data, (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil else {
            return .unreadable(data: data, keptAs: nil)
        }
        return .unreadable(data: data, keptAs: moveAside(url, now: now))
    }

    /// Renames the file beside itself as `name.unreadable-<time>`; the new name, or nil if it could not be moved.
    public static func moveAside(_ url: URL, now: Date = Date()) -> String? {
        let kept = url.lastPathComponent + ".unreadable-" + stamp(now)
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(kept))
            return kept
        } catch {
            return nil
        }
    }

    /// A file-name-safe local time, to the second.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
