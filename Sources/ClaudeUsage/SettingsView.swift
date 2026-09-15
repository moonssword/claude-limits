import SwiftUI

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var lang = L10n.shared

    var body: some View {
        Form {
            Section(T("set.sectionAppearance")) {
                Picker(T("set.language"), selection: $prefs.language) {
                    ForEach(Lang.allCases) { item in
                        Text(item == .system ? T("set.languageSystem") : item.nativeName).tag(item)
                    }
                }
                Picker(T("set.appTheme"), selection: $prefs.appTheme) {
                    ForEach(AppTheme.allCases) { Text(T($0.titleKey)).tag($0) }
                }
                Picker(T("set.iconColor"), selection: $prefs.iconTheme) {
                    ForEach(IconTheme.allCases) { Text(T($0.titleKey)).tag($0) }
                }
                Text(T("set.iconColorHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(T("set.menuBarView")) {
                StyleGrid(selection: $prefs.iconStyle, snapshot: store.snapshot)
            }

            Section(T("set.sectionUpdates")) {
                Picker(T("set.refreshRate"), selection: $prefs.refreshSeconds) {
                    Text(T("refresh.1m")).tag(60)
                    Text(T("refresh.5m")).tag(300)
                    Text(T("refresh.10m")).tag(600)
                    Text(T("refresh.15m")).tag(900)
                    Text(T("refresh.30m")).tag(1800)
                }
            }

            Section(T("set.sectionSystem")) {
                Toggle(T("set.autostartOn"), isOn: $prefs.launchAtLogin)
            }

            Section(T("set.sectionNotifications")) {
                Toggle(T("set.notificationsOn"), isOn: $prefs.notificationsEnabled)
                Picker(T("set.beforeReset"), selection: $prefs.warnMinutesLeft) {
                    Text(T("warn.off")).tag(0)
                    Text(T("warn.15m")).tag(15)
                    Text(T("warn.30m")).tag(30)
                    Text(T("warn.1h")).tag(60)
                }
                .disabled(!prefs.notificationsEnabled)
                LabeledContent(T("set.sessionThreshold")) {
                    Stepper(T("set.thresholdValue", prefs.warnSessionPercent),
                            value: $prefs.warnSessionPercent, in: 50...99, step: 5)
                        .disabled(!prefs.notificationsEnabled)
                }
                LabeledContent(T("set.weekThreshold")) {
                    Stepper(T("set.thresholdValue", prefs.warnWeekPercent),
                            value: $prefs.warnWeekPercent, in: 50...99, step: 5)
                        .disabled(!prefs.notificationsEnabled)
                }
            }

            Section(T("auth.section")) {
                AuthSection()
            }

            Section {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "lock.shield").foregroundStyle(.tertiary)
                    Text(T("set.privacy"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .environment(\.layoutDirection, lang.isRTL ? .rightToLeft : .leftToRight)
        .id(lang.code)
        .preferredColorScheme(prefs.appTheme.colorScheme)
    }
}

// MARK: - Авторизация

private struct AuthSection: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var auth = AuthFlow.shared
    @State private var tokenSaved = TokenStore.hasToken
    @State private var code = ""
    @State private var manualToken = ""
    @State private var showManualField = false

    var body: some View {
        Picker(T("auth.source"), selection: $prefs.authSource) {
            ForEach(AuthSource.allCases) { Text(T($0.titleKey)).tag($0) }
        }
        .pickerStyle(.segmented)

        if prefs.authSource == .manualToken {
            VStack(alignment: .leading, spacing: 10) {
                switch auth.stage {
                case .idle, .failed:
                    Button {
                        auth.start()
                    } label: {
                        Label(T("auth.browser"), systemImage: "safari")
                    }
                    .controlSize(.large)
                    Text(T("auth.browserHint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = auth.stage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Severity.warning.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .starting:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(T("auth.starting")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                case .waitingForCode, .submitting:
                    Text(T("auth.codeHint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField(T("auth.codePlaceholder"), text: $code)
                            .textFieldStyle(.roundedBorder)
                        Button(T("auth.submit")) {
                            auth.submit(code: code)
                            code = ""
                        }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty
                                  || auth.stage == .submitting)
                    }
                    HStack(spacing: 12) {
                        Button(T("auth.openAgain")) { auth.openAuthorizePage() }
                            .controlSize(.small)
                        Button(T("auth.copyLink")) { auth.copyAuthorizeURL() }
                            .controlSize(.small)
                        Button(T("auth.cancel")) { auth.cancel() }
                            .controlSize(.small)
                        if auth.stage == .submitting { ProgressView().controlSize(.small) }
                    }

                case .saved:
                    Label(T("auth.done"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(Severity.normal.color)
                }

                if tokenSaved || auth.stage == .saved {
                    HStack(spacing: 10) {
                        Text(T("auth.stored")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(T("auth.clear")) {
                            TokenStore.clear()
                            tokenSaved = false
                            UsageStore.shared.refresh(force: true, interactive: true)
                        }
                        .controlSize(.small)
                    }
                }

                DisclosureGroup(T("auth.manualEntry"), isExpanded: $showManualField) {
                    HStack(spacing: 8) {
                        SecureField(T("auth.tokenPlaceholder"), text: $manualToken)
                            .textFieldStyle(.roundedBorder)
                        Button(T("auth.save")) {
                            TokenStore.save(manualToken.trimmingCharacters(in: .whitespacesAndNewlines))
                            manualToken = ""
                            tokenSaved = TokenStore.hasToken
                            UsageStore.shared.refresh(force: true, interactive: true)
                        }
                        .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            }
            .onChange(of: auth.stage) { _, stage in
                if stage == .saved { tokenSaved = true }
            }
        } else {
            Text(T("auth.keychainHint"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Выбор вида в строке меню

/// Плитки со всеми вариантами: выбор глазами, а не по названию.
private struct StyleGrid: View {
    @Binding var selection: IconStyle
    let snapshot: UsageSnapshot?

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(IconStyle.allCases) { style in
                Button { selection = style } label: {
                    VStack(spacing: 6) {
                        MenuBarSample(style: style, snapshot: snapshot)
                        Text(T(style.titleKey))
                            .font(.system(size: 10))
                            .foregroundStyle(selection == style ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == style ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == style ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: selection == style ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Кусочек строки меню в текущей теме оформления.
private struct MenuBarSample: View {
    let style: IconStyle
    let snapshot: UsageSnapshot?

    var body: some View {
        let dark = StatusItemController.menuBarIsDark
        let session = snapshot?.session.percent ?? 61
        let week = snapshot?.week.percent ?? 41
        let text = StatusItemController.titleText(for: snapshot, style: style, now: Date())

        HStack(spacing: 3) {
            if let image = StatusIcon.image(kind: style.icon, session: session, week: week,
                                            tint: dark ? .white : .black) {
                Image(nsImage: image)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(dark ? .white : .black)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(height: 24)
        .background(dark ? Color(white: 0.13) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
    }
}
