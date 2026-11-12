// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import HaloCore

/// The interface language: the system's unless the person picks one in General.
enum Language: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"
    case system

    /// Each language in its own name, so it can be found whatever the current one is.
    var title: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        case .system: return L("Follow System")
        }
    }

    private static let defaultsKey = "HaloLanguage"

    static var current: Language {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Language.init(rawValue:)) ?? .system }
        set {
            // Back to the system: the value Halo wrote for the language left behind goes, or it would still win.
            if newValue == .system, current != .system,
               UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String] == [current.rawValue] {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            alignSystemText()
            strings = bundle(for: newValue)
        }
    }

    /// Text the system draws for Halo (the Bluetooth prompt, standard menus) follows the app's AppleLanguages from
    /// the next launch; a chosen language is written there so the two agree. Following the system leaves that key
    /// alone, so a language set for Halo in System Settings › Language & Region › Applications still applies.
    static func alignSystemText() {
        let chosen = current
        guard chosen != .system else { return }
        if UserDefaults.standard.stringArray(forKey: "AppleLanguages") != [chosen.rawValue] {
            UserDefaults.standard.set([chosen.rawValue], forKey: "AppleLanguages")
        }
    }

    fileprivate static var strings = bundle(for: current)

    /// A moment such as "Today 21:03", in Halo's language rather than the system's.
    func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        if self != .system { formatter.locale = Locale(identifier: rawValue) }
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private static func bundle(for language: Language) -> Bundle {
        guard language != .system, let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// The text for `key` in the chosen language. Keys are the English wording itself, so a missing entry still reads
/// in English; HaloTests checks every key against packaging/Localizable.xcstrings.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: Language.strings, value: namedText[key] ?? key, comment: "")
}

/// English for the keys that name their text rather than spell it, for when no table is loaded (a binary run from
/// .build, outside the app bundle).
private let namedText = ["LIST_SEPARATOR": ", ", "CLAUSE_SEPARATOR": ", "]

/// A localized format string filled in with `arguments`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
