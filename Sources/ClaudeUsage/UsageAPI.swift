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
        var item: CFTypeRef?
        // Без явного действия пользователя диалог с паролем показывать нельзя.
        let status = interactive
            ? SecItemCopyMatching(query as CFDictionary, &item)
            : Keychain.withoutUserInteraction { SecItemCopyMatching(query as CFDictionary, &item) }

        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw UsageError.notLoggedIn
        case errSecInteractionNotAllowed where !interactive,
             errSecAuthFailed where !interactive:
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

    /// Диагностика доступа к связке ключей: `ClaudeUsage --keychain-check`.
    static func diagnose() {
        func describe(_ status: OSStatus) -> String {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "—"
            return "\(status) (\(text))"
        }
        func attempt(_ label: String, _ body: () -> OSStatus) {
            let before = Date()
            let status = body()
            let seconds = String(format: "%.2f", Date().timeIntervalSince(before))
            print("\(label): \(describe(status)), \(seconds) с")
        }

        func query(service: String, account: String?, silent: Bool) -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let account { q[kSecAttrAccount as String] = account }
            if silent { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
            return q
        }

        print("приложение:", Bundle.main.bundlePath)
        print("свой токен сохранён:", TokenStore.hasToken)
        attempt("Claude Code, тихое чтение") {
            Keychain.withoutUserInteraction {
                var item: CFTypeRef?
                return SecItemCopyMatching(query(service: keychainService, account: nil, silent: false) as CFDictionary, &item)
            }
        }
        if let cached = TokenStore.cachedToken() {
            print("кэш: годен до \(cached.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"), пригоден: \(cached.isUsable)")
        } else {
            print("кэш: пусто")
        }
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
                return try await request(Credentials(accessToken: cached.token,
                                                  subscriptionType: cached.subscriptionType))
            } catch UsageError.unauthorized {
                TokenStore.dropCache()      // токен отозван или обновлён — перечитаем исходник
            }
        }

        let creds = try readCredentials(interactive: interactive)
        let snapshot = try await request(creds)
        TokenStore.cache(TokenStore.CachedToken(token: creds.accessToken, expiresAt: creds.expiresAt,
                                                subscriptionType: creds.subscriptionType))
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

    /// `resets_at` приходит строкой ISO 8601; в массиве `limits` встречаются и секунды Unix.
    private static func date(_ raw: Any?) -> Date? {
        if let seconds = raw as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let s = raw as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// `utilization` может быть `null`: окно есть, но данных по нему нет — такое окно пропускаем.
    private static func bucket(_ raw: Any?) -> LimitBucket? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let utilization = dict["utilization"] as? Double else { return nil }
        return LimitBucket(percent: utilization,
                           resetsAt: date(dict["resets_at"]),
                           lockedReason: dict["locked_reason"] as? String)
    }

    /// Недельные лимиты отдельных моделей — так же, как их показывает `/usage` в Claude Code:
    /// Sonnet (только у Max и Team), устаревший Opus, если сервер его ещё присылает,
    /// и строки массива `limits` с привязкой к модели (например, Fable).
    private static func modelLimits(_ json: [String: Any], plan: String?) -> [ModelLimit] {
        var result: [ModelLimit] = []
        func add(_ name: String, _ bucket: LimitBucket?) {
            guard let bucket, !result.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            result.append(ModelLimit(name: name, bucket: bucket))
        }

        let sonnetPlans: Set<String> = ["max", "team"]
        if plan.map({ sonnetPlans.contains($0.lowercased()) }) ?? true {
            add("Sonnet", bucket(json["seven_day_sonnet"]))
        }
        add("Opus", bucket(json["seven_day_opus"]))

        for row in (json["limits"] as? [[String: Any]]) ?? [] {
            guard let scope = row["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let percent = row["percent"] as? Double
            else { continue }
            add(name, LimitBucket(percent: percent, resetsAt: date(row["resets_at"]), lockedReason: nil))
        }
        return result
    }

    private static func parse(_ json: [String: Any], plan: String?) throws -> UsageSnapshot {
        let session = bucket(json["five_hour"])
        let week = bucket(json["seven_day"])
        // Пустой ответ без обоих окон — это ошибка, а не «0 % использовано».
        guard session != nil || week != nil else { throw UsageError.badResponse }
        let empty = LimitBucket(percent: 0, resetsAt: nil, lockedReason: nil)

        var extra: ExtraUsage?
        // Суммы — в минимальных единицах валюты (центы для USD).
        if let e = json["extra_usage"] as? [String: Any],
           (e["is_enabled"] as? Bool) == true,
           let limit = e["monthly_limit"] as? Double, limit > 0 {
            extra = ExtraUsage(isEnabled: true,
                               usedMinor: (e["used_credits"] as? Double) ?? 0,
                               limitMinor: limit,
                               decimalPlaces: (e["decimal_places"] as? Int) ?? 2,
                               currency: (e["currency"] as? String) ?? "USD")
        }

        return UsageSnapshot(session: session ?? empty,
                             week: week ?? empty,
                             weekModels: modelLimits(json, plan: plan),
                             extra: extra,
                             plan: plan,
                             fetchedAt: Date())
    }
}
