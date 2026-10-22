import Foundation

/// The UI language the user picked from the More menu. Switches live, without relaunching.
enum Language: String, CaseIterable {
    case zh, en

    /// Each language is listed in its own name, so it's findable whichever one is showing.
    var title: String {
        switch self {
        case .zh: return "繁體中文"
        case .en: return "English"
        }
    }

    private static let key = "menusqlite.language"

    /// Posted after `current` changes, so views built earlier can relabel themselves.
    static let didChange = Notification.Name("menusqlite.languageDidChange")

    static var current: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .zh }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// Picks the Chinese or English text for the current language.
func tr(_ zh: String, _ en: String) -> String {
    Language.current == .zh ? zh : en
}
