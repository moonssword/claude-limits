import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var systemThemeObserver: NSObjectProtocol?
    /// Слепок того, что уже нарисовано: таймер тикает раз в секунду, а меняется куда реже.
    private var renderedKey: String?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(openSettings: { [weak self] in
            self?.showSettings()
        }))
        // Без этого popover берёт размер один раз и обрезает выросший контент.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Строка меню живёт по теме системы, а не по теме приложения из настроек.
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }

        let store = UsageStore.shared
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)

        Preferences.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)

        render()
    }

    deinit {
        if let systemThemeObserver {
            DistributedNotificationCenter.default().removeObserver(systemThemeObserver)
        }
    }

    // MARK: - Отрисовка

    private func render() {
        guard let button = statusItem.button else { return }
        let store = UsageStore.shared
        let prefs = Preferences.shared

        guard let snapshot = store.snapshot else {
            renderedKey = nil
            button.image = StatusIcon.offline()
            button.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.toolTip = store.error?.localizedDescription ?? T("tip.loading")
            return
        }

        let severity = Severity.of(snapshot.worstPercent)
        let key = [
            prefs.iconStyle.rawValue, prefs.iconTheme.rawValue,
            String(Int(snapshot.session.percent.rounded())), String(Int(snapshot.week.percent.rounded())),
            Self.titleText(for: snapshot, style: prefs.iconStyle, now: UsageStore.shared.now),
            snapshot.session.isExhausted || snapshot.week.isExhausted ? "out" : "ok",
            Fmt.timeFormatter.string(from: snapshot.fetchedAt),
            store.error == nil ? "" : "err"
        ].joined(separator: "|")
        guard key != renderedKey else { return }
        renderedKey = key
        // Иконка и подпись всегда одного цвета: либо обе монохромные (шаблонные),
        // либо обе окрашены по уровню риска.
        let accent: NSColor? = {
            switch prefs.iconTheme {
            case .monochrome:
                return nil                                   // всегда цвет строки меню
            case .adaptive:
                // Строка меню в macOS монохромная, поэтому подкрашиваемся только у самого лимита.
                return severity == .critical ? severity.menuBarColor : nil
            case .colored:
                return severity.menuBarColor
            }
        }()

        if snapshot.session.isExhausted || snapshot.week.isExhausted {
            button.image = StatusIcon.exhausted(tint: Severity.critical.menuBarColor)
        } else {
            button.image = StatusIcon.image(kind: prefs.iconStyle.icon,
                                            session: snapshot.session.percent,
                                            week: snapshot.week.percent,
                                            tint: accent)
        }

        let text = Self.titleText(for: snapshot, style: prefs.iconStyle, now: UsageStore.shared.now)
        let label = (prefs.iconStyle.icon == .none || text.isEmpty) ? text : " " + text
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        ]
        // Без своего цвета подпись рисует система — в строке меню macOS подбирает контраст
        // по обоям под ней, а не по теме оформления, и повторить это вручную нельзя.
        if let accent { attributes[.foregroundColor] = accent }
        button.attributedTitle = NSAttributedString(string: label, attributes: attributes)
        button.toolTip = [
            T("tip.session", Fmt.percent(snapshot.session.percent), Fmt.resetPoint(snapshot.session.resetsAt)),
            T("tip.week", Fmt.percent(snapshot.week.percent), Fmt.resetPoint(snapshot.week.resetsAt)),
            T("tip.updated", Fmt.timeFormatter.string(from: snapshot.fetchedAt))
        ].joined(separator: "\n")
    }

    /// Только для предпросмотра в настройках: сам пункт меню своей темы не получает —
    /// монохромную иконку и подпись рисует система, подбирая контраст к строке меню.
    static var menuBarIsDark: Bool {
        NSApp.effectiveAppearance.isDark
    }

    /// Текстовая часть пункта меню — используется и в предпросмотре настроек.
    static func titleText(for snapshot: UsageSnapshot?, style: IconStyle, now: Date) -> String {
        let session = snapshot?.session.percent ?? 61
        let week = snapshot?.week.percent ?? 41
        let resets = snapshot?.session.resetsAt ?? now.addingTimeInterval(6900)
        switch style.text {
        case .none: return ""
        case .time: return Fmt.compact(until: resets, now: now)
        case .percents: return "\(Int(session.rounded()))·\(Int(week.rounded()))"
        case .remaining: return "\(Int((100 - session).rounded()))%"
        case .timeAndWeek: return "\(Fmt.compact(until: resets, now: now)) · \(Int(week.rounded()))%"
        }
    }

    // MARK: - Взаимодействие

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            UsageStore.shared.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: T("btn.refresh"), action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: T("btn.settingsDots"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: T("btn.quit"), action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { UsageStore.shared.refresh(force: true) }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        popover.performClose(nil)
        settingsWindow?.title = T("window.settings")
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = T("window.settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        // Окно должно появляться там, где пользователь сейчас, а не там, где его открывали в прошлый раз.
        window.collectionBehavior.insert(.moveToActiveSpace)
        if !window.isVisible { moveToActiveScreen(window) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Закрыли настройки — обрываем незавершённую авторизацию, чтобы не висел процесс.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        AuthFlow.shared.cancel()
    }

    private func moveToActiveScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return window.center() }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }
}
