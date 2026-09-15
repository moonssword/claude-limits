import Foundation
import Security

/// Личное хранилище токена приложения (для режима «свой токен»).
/// Своя запись в связке ключей принадлежит приложению, поэтому системных запросов доступа нет.
enum TokenStore {
    private static let service = "com.ibulat.claudeusage.token"
    private static let account = "manual-oauth-token"
    private static let cacheAccount = "claude-code-token-cache"

    static func save(_ token: String) { write(Data(token.utf8), account: account) }

    static func load() -> String? { read(account: account).flatMap { String(data: $0, encoding: .utf8) } }

    static func clear() { delete(account: account) }

    static var hasToken: Bool { load() != nil }

    // MARK: - Кэш токена Claude Code

    /// Копия действующего токена Claude Code в собственной записи приложения.
    /// Своя запись принадлежит приложению, поэтому читается без запросов пароля;
    /// исходную запись Claude Code трогаем только когда копия устарела.
    struct CachedToken: Codable {
        var token: String
        var expiresAt: Date?

        var isUsable: Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > 120   // с запасом на дорогу
        }
    }

    static func cache(_ cached: CachedToken) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        write(data, account: cacheAccount)
    }

    static func cachedToken() -> CachedToken? {
        guard let data = read(account: cacheAccount) else { return nil }
        return try? JSONDecoder().decode(CachedToken.self, from: data)
    }

    static func dropCache() { delete(account: cacheAccount) }

    // MARK: - Примитивы

    private static func write(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var add = query
        add[kSecValueData as String] = data
        // kSecAttrAccessible здесь не задаём: в файловой связке ключей macOS этот атрибут
        // не поддерживается и запись просто не создаётся.
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return }

        var silent = query
        silent[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        if SecItemUpdate(silent as CFDictionary, [kSecValueData as String: data] as CFDictionary) != errSecSuccess {
            // Обновить чужую запись не вышло — пересоздаём свою.
            delete(account: account)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            // Запись осталась от прежней сборки приложения и больше нам не принадлежит:
            // выбрасываем её, чтобы следующая запись создала свою, без запросов пароля.
            delete(account: account)
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    private static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
