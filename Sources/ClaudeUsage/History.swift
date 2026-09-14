import Foundation

struct Sample: Codable {
    var t: Double      // unix time
    var s: Double      // сессия, %
    var w: Double      // недельная квота, %
}

/// Локальная история замеров: нужна для графика по дням и оценки темпа.
final class HistoryStore {
    static let shared = HistoryStore()

    private let url: URL
    private let statusURL: URL
    private var samples: [Sample] = []
    private let queue = DispatchQueue(label: "claude-usage.history")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        statusURL = base.appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = decoded
        }
    }

    /// Диагностика последнего опроса — помогает понять, что происходит, когда панель закрыта.
    func recordStatus(ok: Bool, error: String?) {
        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "ok": ok,
            "error": error as Any
        ]
        queue.async {
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? data.write(to: self.statusURL, options: .atomic)
            }
        }
    }

    func record(_ snapshot: UsageSnapshot) {
        let sample = Sample(t: snapshot.fetchedAt.timeIntervalSince1970,
                            s: snapshot.session.percent,
                            w: snapshot.week.percent)
        queue.async {
            if let last = self.samples.last {
                let sameValues = abs(last.w - sample.w) < 0.01 && abs(last.s - sample.s) < 0.01
                if sameValues && sample.t - last.t < 600 { return }
            }
            self.samples.append(sample)
            let cutoff = Date().addingTimeInterval(-35 * 24 * 3600).timeIntervalSince1970
            self.samples.removeAll { $0.t < cutoff }
            if let data = try? JSONEncoder().encode(self.samples) {
                try? data.write(to: self.url, options: .atomic)
            }
        }
    }

    private func currentSamples() -> [Sample] {
        queue.sync { samples }
    }

    /// Расход недельной квоты по дням текущей недели — нужен для оценки темпа.
    private func dailyBurn() -> [Double] {
        let data = currentSamples()
        var cal = Calendar.current
        cal.firstWeekday = 2
        var perDay: [Date: Double] = [:]
        for (prev, next) in zip(data, data.dropFirst()) {
            let delta = next.w - prev.w
            guard delta > 0 else { continue }      // отрицательная разница — сброс недели
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: next.t))
            perDay[day, default: 0] += delta
        }
        return Array(perDay.values)
    }

    /// Средний расход недельной квоты в сутки за дни, где была активность.
    func averageDailyBurn() -> Double? {
        let days = dailyBurn().filter { $0 > 0.5 }
        guard !days.isEmpty else { return nil }
        return days.reduce(0, +) / Double(days.count)
    }
}
