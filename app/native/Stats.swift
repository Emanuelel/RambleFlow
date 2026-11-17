import Foundation

func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}

// Usage counts only: how much was dictated, when, in what kind of writing and into which apps (by bundle
// identifier). No dictated text, window title or address is ever stored.
struct Stats: Codable, Equatable {
    var words = 0
    var seconds = 0.0
    var dictations = 0
    // Local calendar day (yyyy-MM-dd) to words dictated that day.
    var days: [String: Int] = [:]
    // Words the cleanup step removed: recognized words minus the words that were kept.
    var tidied = 0
    // Writing style in use (prompt, formal, casual, minimal) to words. Recorded for a later view; nothing shows it yet.
    var kinds: [String: Int] = [:]
    // Bundle identifier of the app that was in front to words. The identifier is all that is kept about it.
    var apps: [String: Int] = [:]

    init() {}
    // Fields added later are optional on disk, so an older file still loads.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        words = try values.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        dictations = try values.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        days = try values.decodeIfPresent([String: Int].self, forKey: .days) ?? [:]
        tidied = try values.decodeIfPresent(Int.self, forKey: .tidied) ?? 0
        kinds = try values.decodeIfPresent([String: Int].self, forKey: .kinds) ?? [:]
        apps = try values.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    mutating func record(words count: Int, seconds duration: Double, tidied removed: Int = 0, kind: String? = nil, app: String? = nil, on date: Date = Date(), calendar: Calendar = .current) {
        guard count > 0 else { return }
        words += count; seconds += max(0, duration); dictations += 1; tidied += max(0, removed)
        days[Self.dayKey(date, calendar: calendar), default: 0] += count
        if let kind { kinds[kind, default: 0] += count }
        if let app, !app.isEmpty { apps[app, default: 0] += count }
    }
    // Speaking pace while the microphone was open. Hidden until there is enough to be meaningful.
    var wordsPerMinute: Int? {
        seconds >= 10 && words > 0 ? Int((Double(words) / (seconds / 60)).rounded()) : nil
    }
    func wordsToday(_ today: Date = Date(), calendar: Calendar = .current) -> Int {
        days[Self.dayKey(today, calendar: calendar)] ?? 0
    }
    // A streak survives until the end of the day after the last dictation.
    func streaks(today: Date = Date(), calendar: Calendar = .current) -> (current: Int, longest: Int) {
        func used(_ offset: Int) -> Bool {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return false }
            return (days[Self.dayKey(day, calendar: calendar)] ?? 0) > 0
        }
        var current = 0
        var offset = used(0) ? 0 : 1
        while used(offset) { current += 1; offset += 1 }
        var longest = 0, run = 0
        var previous: Date?
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone; format.dateFormat = "yyyy-MM-dd"
        for key in days.keys.sorted() where (days[key] ?? 0) > 0 {
            guard let day = format.date(from: key) else { continue }
            if let last = previous, let next = calendar.date(byAdding: .day, value: 1, to: last), calendar.isDate(next, inSameDayAs: day) { run += 1 } else { run = 1 }
            longest = max(longest, run); previous = day
        }
        return (current, max(longest, current))
    }
    private func words(daysAgo range: Range<Int>, from today: Date, calendar: Calendar) -> Int {
        range.reduce(0) { total, offset in
            total + (calendar.date(byAdding: .day, value: -offset, to: today).map { days[Self.dayKey($0, calendar: calendar)] ?? 0 } ?? 0)
        }
    }
    // Percent change of the last 30 days over the 30 before them. A calendar month would compare a
    // part month with a whole one. Nil when the earlier period is empty.
    func monthTrend(today: Date = Date(), calendar: Calendar = .current) -> Int? {
        let before = words(daysAgo: 30..<60, from: today, calendar: calendar)
        guard before > 0 else { return nil }
        return Int((Double(words(daysAgo: 0..<30, from: today, calendar: calendar) - before) / Double(before) * 100).rounded())
    }
    // Word totals worth a small celebration. Returns the highest one passed between two totals, if any.
    static let milestones = [100, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
    static func milestone(from before: Int, to after: Int) -> Int? {
        milestones.last { before < $0 && after >= $0 }
    }
    // Runs of days worth marking, so a long run is celebrated now and then, not every morning.
    static let streakMarks = [3, 7, 14, 30, 60, 100, 200, 365]
    static func streakMilestone(from before: Int, to after: Int) -> Int? {
        streakMarks.last { before < $0 && after >= $0 }
    }
    // Shading band for a day's words: 0 for none, then 1 to 4 for 1+, 250+, 500+ and 750+.
    static func band(_ words: Int) -> Int {
        words <= 0 ? 0 : words < 250 ? 1 : words < 500 ? 2 : words < 750 ? 3 : 4
    }
    // Whole weeks ending with the current one, each Sunday to Saturday. Days still to come carry no count.
    func heatmap(weeks: Int, today: Date = Date(), calendar: Calendar = .current) -> [[(date: Date, words: Int?)]] {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start) - 1
        guard let sunday = calendar.date(byAdding: .day, value: -weekday - 7 * (weeks - 1), to: start) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day, to: sunday) else { return nil }
                // Compared by calendar day: where clocks skip midnight, a day's first instant is not 00:00.
                let future = calendar.compare(date, to: start, toGranularity: .day) == .orderedDescending
                return (date, future ? nil : days[Self.dayKey(date, calendar: calendar)] ?? 0)
            }
        }
    }

    static func load(from path: String) -> Stats {
        guard let data = FileManager.default.contents(atPath: path), let stats = try? JSONDecoder().decode(Stats.self, from: data) else { return Stats() }
        return stats
    }
    func save(to path: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
