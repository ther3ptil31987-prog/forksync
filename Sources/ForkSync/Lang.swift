import Foundation

/// Oberflächensprache (Deutsch/Englisch). Standard: Systemsprache, umschaltbar in der Toolbar.
enum Lang: String, CaseIterable, Identifiable {
    case de, en
    var id: String { rawValue }
    static let key = "forksync.lang"

    static var system: Lang {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? .de : .en
    }

    static var current: Lang {
        UserDefaults.standard.string(forKey: key).flatMap(Lang.init(rawValue:)) ?? system
    }
}

/// Liefert den deutschen oder englischen Text je nach gewählter Sprache.
func tr(_ de: String, _ en: String) -> String { Lang.current == .de ? de : en }
