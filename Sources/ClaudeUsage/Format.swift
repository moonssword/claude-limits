import Foundation
import SwiftUI

enum Severity {
    case normal, warning, critical

    static func of(_ percent: Double) -> Severity {
        switch percent {
        case ..<75: return .normal
        case ..<90: return .warning
        default: return .critical
        }
    }

    var color: Color {
        switch self {
        case .normal: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.42, green: 0.80, blue: 0.55, alpha: 1)
                              : NSColor(srgbRed: 0.16, green: 0.55, blue: 0.33, alpha: 1)
        })
        case .warning: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.33, alpha: 1)
                              : NSColor(srgbRed: 0.72, green: 0.48, blue: 0.06, alpha: 1)
        })
        case .critical: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.95, green: 0.47, blue: 0.40, alpha: 1)
                              : NSColor(srgbRed: 0.75, green: 0.23, blue: 0.17, alpha: 1)
        })
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return NSColor.labelColor
        case .warning: return NSColor(srgbRed: 0.88, green: 0.60, blue: 0.12, alpha: 1)
        case .critical: return NSColor(srgbRed: 0.85, green: 0.27, blue: 0.20, alpha: 1)
        }
    }

    /// Акцент для строки меню. Тон один на светлую и тёмную полосу: в macOS содержимое
    /// строки меню контрастирует с обоями, а не с темой оформления, так что «угадывать»
    /// светлый или тёмный вариант нельзя — читаться должно в обоих случаях.
    var menuBarColor: NSColor {
        switch self {
        case .normal: return .controlAccentColor
        case .warning: return NSColor(srgbRed: 0.85, green: 0.56, blue: 0.05, alpha: 1)
        case .critical: return NSColor(srgbRed: 0.87, green: 0.26, blue: 0.20, alpha: 1)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

enum Fmt {
    // MARK: - Локаль

    private static var time = DateFormatter()
    private static var weekday = DateFormatter()
    private static var date = DateFormatter()

    static func localeDidChange() {
        let locale = L10n.shared.locale
        cachedLocaleID = locale.identifier
        time = formatter(template: "j:mm", locale: locale)
        weekday = formatter(template: "EEE", locale: locale)
        date = formatter(template: "d MMM", locale: locale)
    }

    private static func formatter(template: String, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static var timeFormatter: DateFormatter { ensureLocale(); return time }
    static var shortWeekday: DateFormatter { ensureLocale(); return weekday }

    private static var cachedLocaleID = ""

    private static func ensureLocale() {
        let id = L10n.shared.locale.identifier
        guard id != cachedLocaleID else { return }
        localeDidChange()
    }

    // MARK: - Длительности и даты

    /// «1 ч 23 мин», «47 мин», «6 д 4 ч»
    static func duration(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let d = T("time.day"), h = T("time.hour"), m = T("time.min")
        if days > 0 { return hours > 0 ? "\(days) \(d) \(hours) \(h)" : "\(days) \(d)" }
        if hours > 0 { return minutes > 0 ? "\(hours) \(h) \(minutes) \(m)" : "\(hours) \(h)" }
        return "\(max(minutes, 1)) \(m)"
    }

    /// Компактно для строки меню: «1:23», «0:47», «6d»
    static func compact(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "0:00" }
        if seconds >= 86400 { return "\(seconds / 86400)\(T("time.day"))" }
        return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    /// «сегодня в 17:05», «пн в 09:00», «21 сен в 09:00»
    static func resetPoint(_ value: Date?) -> String {
        guard let value else { return "—" }
        let cal = Calendar.current
        let clock = timeFormatter.string(from: value)
        if cal.isDateInToday(value) { return T("date.today", clock) }
        if cal.isDateInTomorrow(value) { return T("date.tomorrow", clock) }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: value)).day ?? 0
        let label = days < 7 ? shortWeekday.string(from: value) : dateOnly.string(from: value)
        return T("date.at", label, clock)
    }

    private static var dateOnly: DateFormatter { ensureLocale(); return date }

    static func percent(_ value: Double) -> String {
        value >= 10 || value == 0 ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }
}
