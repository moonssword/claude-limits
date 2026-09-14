import Foundation
import Combine
import AppKit
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isLoading = false
    /// Свой токен не дал доступа к лимитам, работаем через связку ключей.
    @Published private(set) var manualTokenRejected = false
    /// Тикает раз в несколько секунд, чтобы обратный отсчёт в интерфейсе был живым.
    @Published private(set) var now = Date()

    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// После 429 не трогаем сервер до этого момента; пауза растёт при повторных отказах.
    private var pausedUntil: Date?
    private var rateLimitStrikes = 0
    /// Ключ окна сессии с точностью до минуты: сервер шлёт resets_at с микросекундами,
    /// которые меняются от ответа к ответу, поэтому сравнивать даты напрямую нельзя.
    private var notifiedSessionWindow: Int? {
        get { UserDefaults.standard.object(forKey: "notifiedSessionWindow") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "notifiedSessionWindow") }
    }
    /// Порог недели, о котором уже сообщили (переживает перезапуск).
    private var notifiedWeekThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "notifiedWeekThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "notifiedWeekThreshold") }
    }
    private var lastNotificationAt: Date?

    private init() {
        // Всё, что зависит от времени, показывается с точностью до минуты — секундный тик не нужен.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Preferences.shared.$refreshSeconds
            .removeDuplicates()
            .sink { [weak self] seconds in self?.scheduleRefresh(every: seconds) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    private func scheduleRefresh(every seconds: Int) {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(60, seconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = interval * 0.2
    }

    func start() {
        scheduleRefresh(every: Preferences.shared.refreshSeconds)
        refresh()
    }

    func refresh(force: Bool = false) {
        guard !isLoading else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        // Эндпоинт лимитов сам ограничен по частоте — не дёргаем его чаще раза в минуту.
        if !force, error == nil, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 50 { return }
        isLoading = true
        Task {
            do {
                let fresh = try await UsageAPI.fetch()
                self.manualTokenRejected = UsageAPI.manualTokenWasRejected
                self.pausedUntil = nil
                self.rateLimitStrikes = 0
                self.snapshot = fresh
                self.error = nil
                HistoryStore.shared.record(fresh)
                HistoryStore.shared.recordStatus(ok: true, error: nil)
                self.evaluateNotifications(fresh)
            } catch let e as UsageError {
                if case .rateLimited(let retryAt) = e {
                    // Лимит считается по аккаунту, Retry-After приходит нулевым и бесполезен:
                    // отступаем сами — 5, 10, 20, 40 минут, но не дольше часа.
                    self.rateLimitStrikes = min(self.rateLimitStrikes + 1, 4)
                    let backoff = min(3600, 300 * pow(2, Double(self.rateLimitStrikes - 1)))
                    let until = max(Date().addingTimeInterval(backoff), retryAt ?? .distantPast)
                    self.pausedUntil = until
                    // Показываем ровно ту паузу, которую выдерживаем сами.
                    self.error = .rateLimited(until)
                    HistoryStore.shared.recordStatus(ok: false, error: String(describing: e))
                    self.isLoading = false
                    return
                }
                self.error = e
                HistoryStore.shared.recordStatus(ok: false, error: String(describing: e))
            } catch {
                self.error = .network(error.localizedDescription)
                HistoryStore.shared.recordStatus(ok: false, error: error.localizedDescription)
            }
            self.isLoading = false
        }
    }

    /// Демонстрационные данные для режима `--render`.
    func loadPreviewSnapshot() {
        snapshot = UsageSnapshot(
            session: LimitBucket(percent: 61, resetsAt: Date().addingTimeInterval(6900), lockedReason: nil),
            week: LimitBucket(percent: 41, resetsAt: Date().addingTimeInterval(3.4 * 86400), lockedReason: nil),
            weekOpus: LimitBucket(percent: 18, resetsAt: nil, lockedReason: nil),
            extra: ExtraUsage(isEnabled: true, usedMinor: 172, limitMinor: 5000,
                              decimalPlaces: 2, currency: "USD"),
            plan: "pro",
            fetchedAt: Date())
    }

    // MARK: - Уведомления

    private func evaluateNotifications(_ snapshot: UsageSnapshot) {
        let prefs = Preferences.shared
        guard prefs.notificationsEnabled else { return }

        // Сессия: сообщаем один раз на окно — и только если лимит уже заметно израсходован.
        if prefs.warnMinutesLeft > 0,
           let resets = snapshot.session.resetsAt,
           snapshot.session.percent >= Double(prefs.warnSessionPercent) {
            let window = Int(resets.timeIntervalSince1970 / 60)
            let minutesLeft = Int(resets.timeIntervalSinceNow / 60)
            if notifiedSessionWindow != window, minutesLeft > 0, minutesLeft <= prefs.warnMinutesLeft {
                notifiedSessionWindow = window
                notify(title: T("notif.sessionTitle", Fmt.percent(snapshot.session.percent)),
                       body: T("notif.sessionBody", Fmt.resetPoint(resets), Fmt.percent(snapshot.week.percent)))
            }
        }

        // Недельная квота: один раз на пересечение порога, пока квота не сбросится.
        let threshold = prefs.warnWeekPercent
        if snapshot.week.percent >= Double(threshold) {
            if notifiedWeekThreshold != threshold {
                notifiedWeekThreshold = threshold
                notify(title: T("notif.weekTitle", Fmt.percent(snapshot.week.percent)),
                       body: T("notif.weekBody", Fmt.resetPoint(snapshot.week.resetsAt)))
            }
        } else {
            notifiedWeekThreshold = 0   // квота сбросилась или порог подняли — можно сообщить снова
        }
    }

    private func notify(title: String, body: String) {
        guard Notifier.isAvailable else { return }
        // Подстраховка от лавины: не чаще одного уведомления в десять минут.
        if let last = lastNotificationAt, Date().timeIntervalSince(last) < 600 { return }
        lastNotificationAt = Date()
        Notifier.post(title: title, body: body)
    }
}
