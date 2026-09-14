import Foundation
import Combine

enum Lang: String, CaseIterable, Identifiable {
    case system, en, ru, de, fr, es, it, pt, ar, ko, kk, ky, uz
    var id: String { rawValue }

    /// Родное название языка — в списке выбора оно понятнее переведённого.
    var nativeName: String {
        switch self {
        case .system: return "" // подставляется локализованной строкой
        case .en: return "English"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ar: return "العربية"
        case .ko: return "한국어"
        case .kk: return "Қазақша"
        case .ky: return "Кыргызча"
        case .uz: return "Oʻzbekcha"
        }
    }
}

/// Локализация без ресурсных бандлов: таблица строк в коде + выбор языка в настройках.
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published private(set) var code: String = "en"
    private(set) var locale: Locale = Locale(identifier: "en")

    private init() { resolve(Preferences.storedLanguage) }

    /// Язык интерфейса: явный выбор пользователя либо первый подходящий из системных.
    func resolve(_ preference: Lang) {
        let resolved: String
        if preference != .system {
            resolved = preference.rawValue
        } else {
            let supported = Set(Lang.allCases.map(\.rawValue)).subtracting(["system"])
            let fromSystem = Locale.preferredLanguages
                .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
                .first { supported.contains($0) }
            resolved = fromSystem ?? "en"
        }
        code = resolved
        locale = Locale(identifier: localeIdentifier(for: resolved))
        objectWillChange.send()
    }

    private func localeIdentifier(for code: String) -> String {
        switch code {
        case "en": return "en_US"
        case "ru": return "ru_RU"
        case "pt": return "pt_BR"
        case "ar": return "ar"
        default: return code
        }
    }

    var isRTL: Bool { code == "ar" }

    // MARK: - Доступ к строкам

    func callAsFunction(_ key: String) -> String { string(key) }

    func string(_ key: String) -> String {
        guard let entry = Strings.table[key] else {
            assertionFailure("нет строки для ключа \(key)")
            return key
        }
        return entry[code] ?? entry["en"] ?? key
    }

    func string(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: args)
    }
}

/// Короткий доступ: T("label.session")
func T(_ key: String) -> String { L10n.shared.string(key) }
func T(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.shared.string(key), locale: L10n.shared.locale, arguments: args)
}
