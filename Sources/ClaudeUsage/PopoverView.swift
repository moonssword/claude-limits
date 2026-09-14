import SwiftUI

struct PopoverView: View {
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var lang = L10n.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = store.error, store.snapshot == nil {
                ErrorBanner(error: error)
            } else if let snapshot = store.snapshot {
                MetricBlock(title: T("label.session"),
                            bucket: snapshot.session,
                            trailing: remainingText(snapshot.session))
                Divider().opacity(0.5)
                MetricBlock(title: T("label.week"),
                            bucket: snapshot.week,
                            trailing: nil,
                            footnote: paceText(snapshot))

                if let opus = snapshot.weekOpus {
                    CompactRow(label: T("label.opus"),
                               percent: opus.percent,
                               detail: Fmt.percent(opus.percent))
                }
                if let extra = snapshot.extra {
                    CompactRow(label: T("label.extra"),
                               percent: extra.utilization,
                               detail: "\(extra.usedText) / \(extra.limitText)")
                }
                if store.manualTokenRejected && prefs.authSource == .manualToken {
                    Text(T("auth.rejectedFallback"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Severity.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = store.error {
                    Text(error.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(Severity.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(T("state.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }

            footer
        }
        .padding(16)
        .frame(width: 316)
        .environment(\.layoutDirection, lang.isRTL ? .rightToLeft : .leftToRight)
        .id(lang.code)
        .preferredColorScheme(prefs.appTheme.colorScheme)
    }

    // MARK: - Части

    private var header: some View {
        HStack(spacing: 8) {
            Text(T("app.title"))
                .font(.system(size: 13, weight: .semibold))
            if let plan = store.snapshot?.plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { store.refresh(force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(store.isLoading ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .help(T("btn.refresh"))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(updatedText)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(T("btn.settings"), action: openSettings)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button(T("btn.quit"), action: { NSApp.terminate(nil) })
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var updatedText: String {
        guard let snapshot = store.snapshot else { return T("state.noData") }
        let seconds = Int(store.now.timeIntervalSince(snapshot.fetchedAt))
        if seconds < 60 { return T("updated.now") }
        return T("updated.at", Fmt.timeFormatter.string(from: snapshot.fetchedAt))
    }

    private func remainingText(_ bucket: LimitBucket) -> String? {
        guard let left = Fmt.duration(until: bucket.resetsAt, now: store.now) else { return nil }
        return T("state.remaining", left)
    }

    /// Оценка темпа расхода недельной квоты.
    private func paceText(_ snapshot: UsageSnapshot) -> String? {
        guard let burn = HistoryStore.shared.averageDailyBurn(), burn > 0.5,
              let resets = snapshot.week.resetsAt else { return nil }
        let daysLeft = max(0, resets.timeIntervalSince(store.now) / 86400)
        let projected = snapshot.week.percent + burn * daysLeft
        let pace = T("pace.rate", Fmt.percent(burn))
        if projected >= 100 {
            let daysToEmpty = (100 - snapshot.week.percent) / burn
            let date = store.now.addingTimeInterval(daysToEmpty * 86400)
            return T("pace.runout", pace, Fmt.resetPoint(date))
        }
        return T("pace.forecast", pace, Fmt.percent(projected))
    }
}

// MARK: - Блок метрики

private struct MetricBlock: View {
    let title: String
    let bucket: LimitBucket
    var trailing: String?
    var footnote: String?

    private var severity: Severity { Severity.of(bucket.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.percent(bucket.percent))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(severity == .normal ? Color.primary : severity.color)
                Text(bucket.isExhausted ? T("state.exhausted") : T("state.used"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            UsageBar(percent: bucket.percent, color: severity.color, height: 6)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(T("state.reset", Fmt.resetPoint(bucket.resetsAt)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let footnote {
                    Text("·").foregroundStyle(.quaternary).font(.system(size: 10.5))
                    Text(footnote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CompactRow: View {
    let label: String
    let percent: Double
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            UsageBar(percent: percent, color: Severity.of(percent).color, height: 5)
            Text(detail)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

private struct ErrorBanner: View {
    let error: UsageError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Severity.warning.color)
                Text(T("err.title")).font(.system(size: 12, weight: .semibold))
            }
            Text(error.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if error.isRecoverableByRelogin {
                Text(T("err.hintRelogin"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(T("btn.retry")) { UsageStore.shared.refresh(force: true) }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
