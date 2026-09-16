import AppKit
import Combine

/// Авторизация через браузер без Терминала: запускаем штатную `claude setup-token`
/// подпроцессом в псевдотерминале, сами открываем напечатанную ссылку (браузер входит по
/// уже открытой сессии claude.ai), принимаем код из окна приложения и забираем токен.
@MainActor
final class AuthFlow: ObservableObject {
    static let shared = AuthFlow()

    enum Stage: Equatable {
        case idle
        case starting
        case waitingForCode
        case submitting
        case saved
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var authorizeURL: URL?

    private var process: Process?
    private var stdin: FileHandle?
    private var raw = ""
    private var timeout: Timer?
    private var submittedAt: Date?

    // ICU понимает \x{..}, а не \u{..}; и шаблоны не должны ронять приложение,
    // поэтому компилируем их мягко.
    private static let urlPattern = regex("https://claude\\.com/cai/oauth/authorize\\?[^\\s\\x{07}\\x{1B}\"']+")
    private static let tokenPattern = regex("sk-ant-[A-Za-z0-9_\\-]{20,}")

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { NSLog("AuthFlow regex error: \(error.localizedDescription)"); return nil }
    }

    // MARK: - Запуск

    func start() {
        cancel()
        raw = ""
        authorizeURL = nil
        stage = .starting

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let task = Process()
        // script выдаёт команде псевдотерминал: без него CLI не запускает интерактивный вход.
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = ["-q", "/dev/null", shell, "-lc", "claude setup-token"]

        let output = Pipe()
        let input = Pipe()
        task.standardOutput = output
        task.standardError = output
        task.standardInput = input
        stdin = input.fileHandleForWriting

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try task.run()
            process = task
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        timeout = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.stage != .saved else { return }
                self.cancel()
                self.stage = .failed(T("auth.timeout"))
            }
        }
    }

    /// Код, который пользователь скопировал в браузере.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stdin else { return }
        submittedAt = Date()
        stage = .submitting
        stdin.write(Data((trimmed + "\n").utf8))
    }

    func cancel() {
        timeout?.invalidate(); timeout = nil
        if let process, process.isRunning {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdin = nil
        if stage != .saved { stage = .idle }
    }

    func openAuthorizePage() {
        guard let authorizeURL else { return }
        NSWorkspace.shared.open(authorizeURL)
    }

    func copyAuthorizeURL() {
        guard let authorizeURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorizeURL.absoluteString, forType: .string)
    }

    // MARK: - Разбор вывода

    private func consume(_ text: String) {
        raw.append(text)
        if raw.count > 200_000 { raw = String(raw.suffix(100_000)) }

        if authorizeURL == nil, let link = Self.firstMatch(Self.urlPattern, in: raw),
           let url = URL(string: link) {
            authorizeURL = url
            stage = .waitingForCode
            // CLI обычно открывает браузер сам; если он этого не сделал, откроем мы.
            if !raw.contains("Opening") { NSWorkspace.shared.open(url) }
        }

        // Код не подошёл: команда снова просит его ввести — возвращаем поле ввода.
        if stage == .submitting, let submittedAt, Date().timeIntervalSince(submittedAt) > 2,
           raw.lowercased().contains("invalid") || raw.lowercased().contains("try again") {
            self.submittedAt = nil
            stage = .waitingForCode
        }

        if let token = Self.firstMatch(Self.tokenPattern, in: raw) {
            guard TokenStore.looksValid(token) else {
                stage = .failed(T("auth.tokenTruncated"))
                return
            }
            TokenStore.save(token)
            Preferences.shared.authSource = .manualToken
            stage = .saved
            timeout?.invalidate(); timeout = nil
            let finished = process
            process = nil
            stdin = nil
            (finished?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            finished?.terminationHandler = nil
            if finished?.isRunning == true { finished?.terminate() }
            UsageStore.shared.refresh(force: true)
        }
    }

    private func handleTermination() {
        guard stage != .saved else { return }
        stage = .failed(T("auth.noToken"))
        process = nil
        stdin = nil
    }

    private static func firstMatch(_ pattern: NSRegularExpression?, in text: String) -> String? {
        guard let pattern else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
    }
}
