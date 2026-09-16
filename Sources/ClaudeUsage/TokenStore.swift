import Foundation
import Security

/// Хранилище токенов приложения: собственный файл с правами 0600 в Application Support.
///
/// Раньше это была запись в связке ключей, но у неё есть неустранимый недостаток:
/// список доступа привязан к подписи приложения, а при ad-hoc подписи она меняется с каждой
/// сборкой — и обновлённое приложение спрашивало пароль у собственной же записи.
enum TokenStore {

    private struct Contents: Codable {
        var manualToken: String?
        var cached: CachedToken?
    }

    /// Копия действующего токена Claude Code: пока она жива, запись Claude Code не трогаем.
    struct CachedToken: Codable {
        var token: String
        var expiresAt: Date?

        var isUsable: Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > 120   // с запасом на дорогу
        }
    }

    // MARK: - Свой токен

    /// Токены Claude длиннее сотни символов; более короткая строка — почти наверняка
    /// обрезанная копия, и молча сохранять её нельзя.
    static func looksValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 90
    }

    static func save(_ token: String) { update { $0.manualToken = token } }
    static func load() -> String? { contents().manualToken }
    static func clear() { update { $0.manualToken = nil } }
    static var hasToken: Bool { load() != nil }

    // MARK: - Кэш токена Claude Code

    static func cache(_ cached: CachedToken) { update { $0.cached = cached } }
    static func cachedToken() -> CachedToken? { contents().cached }
    static func dropCache() { update { $0.cached = nil } }

    // MARK: - Файл

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("credentials.json")
    }()

    private static func contents() -> Contents {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Contents.self, from: data) else { return Contents() }
        return decoded
    }

    private static func update(_ change: (inout Contents) -> Void) {
        var current = contents()
        change(&current)
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        // Только владелец: файл хранит токен доступа.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Разовый перенос из прежних записей связки ключей и их удаление.
    /// Читаем и удаляем молча: диалог с паролем здесь недопустим.
    static func migrateFromKeychain() {
        let service = "com.ibulat.claudeusage.token"
        Keychain.withoutUserInteraction {
            if let data = rawItem(service: service, account: "manual-oauth-token"),
               let token = String(data: data, encoding: .utf8), !token.isEmpty,
               load() == nil {
                save(token)
            }
            for account in ["manual-oauth-token", "claude-code-token-cache"] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ] as CFDictionary)
            }
        }
    }

    private static func rawItem(service: String, account: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}

/// Доступ к связке ключей без системных диалогов.
enum Keychain {
    /// `kSecUseAuthenticationUI` в файловой связке ключей диалог не подавляет —
    /// проверено: чтение показывало окно с паролем. Работает только этот вызов.
    @discardableResult
    static func withoutUserInteraction<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }
}
