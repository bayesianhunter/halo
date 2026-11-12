// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// The app's interface text: every key it asks for is in the String Catalog with Simplified Chinese, English stays
/// as written, and each translation takes the same arguments as its key.
final class LocalizationTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Keys that name a piece of punctuation rather than spell it, because the two languages split it differently.
    static let named: Set<String> = ["CLAUSE_SEPARATOR", "LIST_SEPARATOR"]

    /// Each key's text per language, from packaging/Localizable.xcstrings. English falls back to the key, as
    /// xcstringstool compiles it.
    func catalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        return strings.mapValues { entry in
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            return localizations.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
    }

    /// The literal keys passed to L(…) across the app's sources.
    func sourceKeys() throws -> Set<String> {
        let folder = root.appendingPathComponent("Sources/Halo")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return keys
    }

    /// What a format string takes, in argument order: "%2$@ … %1$ld" takes ["ld", "@"].
    func arguments(_ format: String) -> [String] {
        let specifier = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])"#)
        var byPosition: [Int: String] = [:]
        var next = 1
        for match in specifier.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let group = { (index: Int) in Range(match.range(at: index), in: format).map { String(format[$0]) } }
            guard let conversion = group(3), conversion != "%" else { continue }
            let position = group(1).flatMap { Int($0) } ?? next
            next = position + 1
            byPosition[position] = (group(2) ?? "") + conversion
        }
        return byPosition.keys.sorted().map { byPosition[$0]! }
    }

    func testEverySourceKeyIsInTheCatalog() throws {
        let keys = try sourceKeys()
        XCTAssertFalse(keys.isEmpty, "no L(…) calls found under \(root.path)/Sources/Halo")
        for key in keys {
            // An interpolation or escape would make the key differ from what the catalog holds.
            XCTAssertFalse(key.contains("\\"), "L(\"\(key)\") must be plain text; pass values as format arguments")
        }
        let catalog = try catalog()
        for key in keys.sorted() where catalog[key] == nil { XCTFail("the catalog lacks \"\(key)\"") }
        for key in Set(catalog.keys).subtracting(keys).sorted() { XCTFail("the catalog has \"\(key)\", which no source uses") }
    }

    func testTranslationsKeepTheirArguments() throws {
        for (key, texts) in try catalog() {
            let english = texts["en"] ?? key
            if Self.named.contains(key) {
                XCTAssertNotNil(texts["en"], "\(key) names its text, so English must spell it out")
            } else {
                XCTAssertEqual(english, key, "English is the key itself")
            }
            let chinese = try XCTUnwrap(texts["zh-Hans"], "\"\(key)\" has no Simplified Chinese")
            XCTAssertFalse(chinese.isEmpty, "\"\(key)\" has empty Simplified Chinese")
            XCTAssertEqual(arguments(chinese), arguments(english), "\"\(key)\" → \"\(chinese)\"")
        }
    }

    func testArgumentsFollowPositions() {
        XCTAssertEqual(arguments("%@ 电量 %ld%%"), ["@", "ld"])
        XCTAssertEqual(arguments("%2$ld for %1$@"), ["@", "ld"])
        XCTAssertEqual(arguments("100%%"), [])
    }
}
