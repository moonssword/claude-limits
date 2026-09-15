import Foundation
import Security

/// Читает OAuth-токен Claude Code из связки ключей и запрашивает актуальные лимиты.
enum UsageAPI {

    /// Отметка о том, что свой токен отвергнут (пишется только с главного актора).
    @MainActor static var manualTokenWasRejected = false

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // MARK: - Keychain

    private struct Credentials {
        var accessToken: String
        var subscriptionType: String?
        var expiresAt: Date?
    }

    /// Чтение записи Claude Code. При `interactive: false` система не показывает диалог:
    /// если доступ не разрешён, возвращается ошибка, и пароль у пользователя не спрашивается.
    private static func readCredentials(interactive: Bool) throws -> Credentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw UsageError.notLoggedIn
        case errSecInteractionNotAllowed where !interactive:
            throw UsageError.needsPermission
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw UsageError.keychainDenied(status)
        default: throw UsageError.keychainFailed(status)
        }

        guard let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw UsageError.malformedCredentials }

        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token,
                           subscriptionType: oauth["subscriptionType"] as? String,
                           expiresAt: expiresAt)
    }

    // MARK: - Fetch

    /// - Parameter interactive: разрешено ли показывать системный запрос доступа к связке
    ///   ключей. Автоматические опросы ходят тихо, диалог появляется только по действию
    ///   пользователя — иначе после каждого обновления токена Claude Code приложение
    ///   само по себе спрашивало бы пароль.
    static func fetch(interactive: Bool) async throws -> UsageSnapshot {
        if Preferences.shared.authSource == .manualToken, let token = TokenStore.load() {
            do {
                let snapshot = try await request(Credentials(accessToken: token, subscriptionType: nil))
                await MainActor.run { manualTokenWasRejected = false }
                return snapshot
            } catch UsageError.unauthorized {
                // Токен от `claude setup-token` может не иметь доступа к лимитам —
                // тогда просто берём рабочие учётные данные Claude Code.
                await MainActor.run { manualTokenWasRejected = true }
            }
        }

        // Пока копия токена жива, запись Claude Code не трогаем вовсе.
        if let cached = TokenStore.cachedToken(), cached.isUsable {
            do {
                return try await request(Credentials(accessToken: cached.token, subscriptionType: nil))
            } catch UsageError.unauthorized {
                TokenStore.dropCache()      // токен отозван или обновлён — перечитаем исходник
            }
        }

        let creds = try readCredentials(interactive: interactive)
        let snapshot = try await request(creds)
        TokenStore.cache(TokenStore.CachedToken(token: creds.accessToken, expiresAt: creds.expiresAt))
        return snapshot
    }

    private static func request(_ creds: Credentials) async throws -> UsageSnapshot {

        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        if http.statusCode == 429 {
            let seconds = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init) ?? 0
            throw UsageError.rateLimited(seconds > 0 ? Date().addingTimeInterval(seconds) : nil)
        }
        guard (200..<300).contains(http.statusCode) else { throw UsageError.http(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        return try parse(json, plan: creds.subscriptionType)
    }

    // MARK: - Parsing

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func bucket(_ raw: Any?) -> LimitBucket? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let utilization = dict["utilization"] as? Double else { return nil }
        return LimitBucket(percent: utilization,
                           resetsAt: date(dict["resets_at"]),
                           lockedReason: dict["locked_reason"] as? String)
    }

    private static func parse(_ json: [String: Any], plan: String?) throws -> UsageSnapshot {
        guard let session = bucket(json["five_hour"]) else { throw UsageError.badResponse }
        let week = bucket(json["seven_day"]) ?? LimitBucket(percent: 0, resetsAt: nil, lockedReason: nil)
        let opus = bucket(json["seven_day_opus"])

        var extra: ExtraUsage?
        if let e = json["extra_usage"] as? [String: Any],
           (e["is_enabled"] as? Bool) == true,
           let limit = e["monthly_limit"] as? Double {
            extra = ExtraUsage(isEnabled: true,
                               usedMinor: (e["used_credits"] as? Double) ?? 0,
                               limitMinor: limit,
                               decimalPlaces: (e["decimal_places"] as? Int) ?? 2,
                               currency: (e["currency"] as? String) ?? "USD")
        }

        return UsageSnapshot(session: session,
                             week: week,
                             weekOpus: opus,
                             extra: extra,
                             plan: plan,
                             fetchedAt: Date())
    }
}
