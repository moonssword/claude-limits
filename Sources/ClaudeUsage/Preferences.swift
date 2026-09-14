import Foundation
import Combine
import ServiceManagement
import AppKit
import SwiftUI

enum IconKind { case ring, bars, battery, dots, none }
enum IconText { case none, time, percents, remaining, timeAndWeek }

enum IconStyle: String, CaseIterable, Identifiable {
    case ring, ringTime, ringPercents, ringRemaining
    case bars, barsTime
    case battery, batteryTime
    case dots
    case textOnly, textPercents

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .ring: return "style.ring"
        case .ringTime: return "style.ringTime"
        case .ringPercents: return "style.ringPercents"
        case .ringRemaining: return "style.ringRemaining"
        case .bars: return "style.bars"
        case .barsTime: return "style.barsTime"
        case .battery: return "style.battery"
        case .batteryTime: return "style.batteryTime"
        case .dots: return "style.dots"
        case .textOnly: return "style.text"
        case .textPercents: return "style.textPercents"
        }
    }

    var icon: IconKind {
        switch self {
        case .ring, .ringTime, .ringPercents, .ringRemaining: return .ring
        case .bars, .barsTime: return .bars
        case .battery, .batteryTime: return .battery
        case .dots: return .dots
        case .textOnly, .textPercents: return .none
        }
    }

    var text: IconText {
        switch self {
        case .ring, .bars, .battery, .dots: return .none
        case .ringTime, .barsTime, .batteryTime: return .time
        case .ringPercents, .textPercents: return .percents
        case .ringRemaining: return .remaining
        case .textOnly: return .timeAndWeek
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .system: return "appearance.system"
        case .light: return "appearance.light"
        case .dark: return "appearance.dark"
        }
    }
    /// Тема применяется к окнам приложения; nil — как в системе.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AuthSource: String, CaseIterable, Identifiable {
    case claudeCode, manualToken
    var id: String { rawValue }
    var titleKey: String { self == .claudeCode ? "auth.keychain" : "auth.manual" }
}

/// Как красить пункт строки меню. К светлой/тёмной теме отношения не имеет:
/// строка меню всегда живёт по теме системы, здесь выбирается только акцент.
enum IconTheme: String, CaseIterable, Identifiable {
    case adaptive = "system"     // rawValue сохранён ради ранее сохранённых настроек
    case monochrome
    case colored

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .adaptive: return "theme.adaptive"
        case .monochrome: return "theme.mono"
        case .colored: return "theme.colored"
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    /// Читается до создания L10n, поэтому статический доступ.
    static var storedLanguage: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    }

    @Published var language: Lang {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            L10n.shared.resolve(language)
            Fmt.localeDidChange()
        }
    }
    @Published var appTheme: AppTheme {
        didSet { defaults.set(appTheme.rawValue, forKey: "appTheme") }
    }
    @Published var authSource: AuthSource {
        didSet { defaults.set(authSource.rawValue, forKey: "authSource") }
    }
    @Published var iconStyle: IconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: "iconStyle") }
    }
    @Published var iconTheme: IconTheme {
        didSet { defaults.set(iconTheme.rawValue, forKey: "iconTheme") }
    }
    /// Предупредить, когда до сброса сессии осталось N минут, а лимит почти исчерпан. 0 — выключено.
    @Published var warnMinutesLeft: Int {
        didSet { defaults.set(warnMinutesLeft, forKey: "warnMinutesLeft") }
    }
    @Published var warnSessionPercent: Int {
        didSet { defaults.set(warnSessionPercent, forKey: "warnSessionPercent") }
    }
    @Published var warnWeekPercent: Int {
        didSet { defaults.set(warnWeekPercent, forKey: "warnWeekPercent") }
    }
    @Published var refreshSeconds: Int {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private init() {
        defaults.register(defaults: [
            "language": Lang.system.rawValue,
            "appTheme": AppTheme.system.rawValue,
            "authSource": AuthSource.claudeCode.rawValue,
            "iconStyle": IconStyle.ringTime.rawValue,
            "iconTheme": IconTheme.adaptive.rawValue,
            "warnMinutesLeft": 30,
            "warnSessionPercent": 85,
            "warnWeekPercent": 85,
            "refreshSeconds": 600,
            "notificationsEnabled": true
        ])
        language = Preferences.storedLanguage
        appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .system
        authSource = AuthSource(rawValue: defaults.string(forKey: "authSource") ?? "") ?? .claudeCode
        iconStyle = IconStyle(rawValue: defaults.string(forKey: "iconStyle") ?? "") ?? .ringTime
        iconTheme = IconTheme(rawValue: defaults.string(forKey: "iconTheme") ?? "") ?? .adaptive
        warnMinutesLeft = defaults.integer(forKey: "warnMinutesLeft")
        warnSessionPercent = defaults.integer(forKey: "warnSessionPercent")
        warnWeekPercent = defaults.integer(forKey: "warnWeekPercent")
        refreshSeconds = defaults.integer(forKey: "refreshSeconds")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("launchAtLogin error: \(error.localizedDescription)")
        }
    }
}
