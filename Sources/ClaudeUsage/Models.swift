import Foundation

/// Один лимит (5-часовая сессия, недельная квота и т.п.).
struct LimitBucket: Equatable {
    var percent: Double          // использовано, 0…100+
    var resetsAt: Date?
    var lockedReason: String?

    var remaining: Double { max(0, 100 - percent) }
    var isExhausted: Bool { percent >= 100 || lockedReason != nil }
}

/// Дополнительные оплачиваемые кредиты сверх подписки.
struct ExtraUsage: Equatable {
    var isEnabled: Bool
    var usedMinor: Double
    var limitMinor: Double
    var decimalPlaces: Int
    var currency: String

    var utilization: Double { limitMinor > 0 ? usedMinor / limitMinor * 100 : 0 }

    private func format(_ minor: Double) -> String {
        let value = minor / pow(10, Double(decimalPlaces))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = decimalPlaces
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    var usedText: String { format(usedMinor) }
    var limitText: String { format(limitMinor) }
}

struct UsageSnapshot: Equatable {
    var session: LimitBucket
    var week: LimitBucket
    var weekOpus: LimitBucket?
    var extra: ExtraUsage?
    var plan: String?            // pro / max ...
    var fetchedAt: Date

    /// Наиболее «горячий» лимит — по нему красится иконка.
    var worstPercent: Double { max(session.percent, max(week.percent, weekOpus?.percent ?? 0)) }
}

enum UsageError: LocalizedError, Equatable {
    case notLoggedIn
    case keychainDenied(OSStatus)
    case keychainFailed(OSStatus)
    case malformedCredentials
    case unauthorized
    case rateLimited(Date?)
    case http(Int)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return T("err.notLoggedIn")
        case .keychainDenied: return T("err.keychainDenied")
        case .keychainFailed(let status): return T("err.keychainFailed", Int(status))
        case .malformedCredentials: return T("err.malformed")
        case .unauthorized: return T("err.unauthorized")
        case .rateLimited(let retryAt):
            if let retryAt, let wait = Fmt.duration(until: retryAt) {
                return T("err.rateLimited", wait)
            }
            return T("err.rateLimitedGeneric")
        case .http(let code): return T("err.http", code)
        case .network(let text): return T("err.network", text)
        case .badResponse: return T("err.badResponse")
        }
    }

    var isRecoverableByRelogin: Bool {
        switch self {
        case .notLoggedIn, .unauthorized, .malformedCredentials: return true
        default: return false
        }
    }
}
