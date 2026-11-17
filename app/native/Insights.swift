import AppKit

// The Home dashboard: every figure is drawn from local counts. Nothing here compares the user with anyone else.
private func caps(_ text: String, _ color: NSColor = Theme.quiet) -> NSAttributedString {
    NSAttributedString(string: text.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color, .kern: 0.9])
}
private func styled(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = Theme.ink, numeral: Bool = false) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: numeral ? Theme.numeral(size, weight) : NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
private let grouping: NumberFormatter = { let format = NumberFormatter(); format.numberStyle = .decimal; return format }()
private func grouped(_ value: Int) -> String { grouping.string(from: NSNumber(value: value)) ?? "\(value)" }

class TileView: NSView {
    var stats = Stats() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    let inset: CGFloat = 18
    func drawCard() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.radius, yRadius: Theme.radius)
        Theme.card.setFill(); path.fill()
        Theme.hairline.setStroke(); path.lineWidth = 1; path.stroke()
    }
    func rule(at y: CGFloat) { Theme.hairline.setFill(); NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: 1).fill() }
    // The headline number with its small-capitals label underneath. A changed number follows the library's
    // "number subtle change": over 455 ms on smooth-out the old figure lifts away and fades while the new
    // one rises into place, travelling 0.14 of the type size.
    private var shown = "", leaving = "", changed: TimeInterval = 0
    private var ticker: Timer?
    func headline(_ number: String, _ label: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if number != shown {
            if !shown.isEmpty && window?.isVisible == true && !Motion.reduced {
                leaving = shown; changed = now
                if ticker == nil {
                    let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                        guard let self else { timer.invalidate(); return }
                        self.needsDisplay = true
                        if ProcessInfo.processInfo.systemUptime - self.changed > 0.455 { timer.invalidate(); self.ticker = nil; self.leaving = "" }
                    }
                    RunLoop.main.add(tick, forMode: .common); ticker = tick
                }
            }
            shown = number
        }
        let progress = leaving.isEmpty ? 1 : Motion.smoothOut(CGFloat(min(1, (now - changed) / 0.455)))
        let travel: CGFloat = 30 * 0.14
        if progress < 1 { styled(leaving, 30, .semibold, Theme.ink.withAlphaComponent(1 - progress), numeral: true).draw(at: NSPoint(x: inset, y: 14 - travel * progress)) }
        // At rest the figure is drawn in the label colour as it is, which carries its own slight transparency.
        styled(number, 30, .semibold, progress < 1 ? Theme.ink.withAlphaComponent(progress) : Theme.ink, numeral: true).draw(at: NSPoint(x: inset, y: 14 + travel * (1 - progress)))
        caps(label).draw(at: NSPoint(x: inset, y: 54))
    }
}

// Speaking pace, with a gauge against a typical typing speed.
final class PaceTile: TileView {
    static let typing = 40.0, full = 200.0
    override func draw(_ dirtyRect: NSRect) {
        drawCard()
        let pace = stats.wordsPerMinute
        headline(pace.map(String.init) ?? "–", "Words per minute")
        let centre = NSPoint(x: bounds.midX, y: bounds.height - 26), radius: CGFloat = 62
        let track = NSBezierPath(); track.appendArc(withCenter: centre, radius: radius, startAngle: 180, endAngle: 360)
        track.lineWidth = 13; track.lineCapStyle = .round; Theme.track.setStroke(); track.stroke()
        if let pace {
            let value = NSBezierPath(); value.appendArc(withCenter: centre, radius: radius, startAngle: 180, endAngle: 180 + 180 * CGFloat(min(1, Double(pace) / Self.full)))
            value.lineWidth = 13; value.lineCapStyle = .round; NSColor.controlAccentColor.setStroke(); value.stroke()
            let times = styled(String(format: "%.1f×", Double(pace) / Self.typing), 17, .semibold, numeral: true), note = styled("typing speed", 10.5, .regular, Theme.quiet)
            times.draw(at: NSPoint(x: centre.x - times.size().width / 2, y: centre.y - 40))
            note.draw(at: NSPoint(x: centre.x - note.size().width / 2, y: centre.y - 18))
        } else {
            let note = styled("after a few dictations", 10.5, .regular, Theme.quiet)
            note.draw(at: NSPoint(x: centre.x - note.size().width / 2, y: centre.y - 24))
        }
    }
}

// What cleanup has done, and how much has been dictated.
final class TidyTile: TileView {
    override func draw(_ dirtyRect: NSRect) {
        drawCard()
        headline(grouped(stats.tidied), "Words tidied by cleanup")
        rule(at: 84)
        let minutes = Int((stats.seconds / 60).rounded())
        for (index, line) in ["\(grouped(stats.dictations)) \(stats.dictations == 1 ? "dictation" : "dictations")", "\(grouped(minutes)) \(minutes == 1 ? "minute" : "minutes") speaking"].enumerated() {
            styled(line, 13).draw(at: NSPoint(x: inset, y: 100 + CGFloat(index) * 26))
        }
    }
}

final class TotalTile: TileView {
    var today = Date()
    override func draw(_ dirtyRect: NSRect) {
        drawCard()
        headline(grouped(stats.words), "Total words dictated")
        if let trend = stats.monthTrend(today: today) {
            let text = NSAttributedString(string: "\(trend >= 0 ? "↗" : "↘") \(abs(trend))% in 30 days", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: trend >= 0 ? Theme.good : Theme.quiet])
            let size = text.size(), box = NSRect(x: bounds.width - inset - size.width - 16, y: 18, width: size.width + 16, height: 22)
            // A very large total needs the room; the badge gives way.
            if box.minX >= inset + styled(grouped(stats.words), 30, .semibold, numeral: true).size().width + 10 {
                (trend >= 0 ? Theme.good.withAlphaComponent(0.14) : Theme.track).setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
                text.draw(at: NSPoint(x: box.minX + 8, y: box.midY - size.height / 2))
            }
        }
        rule(at: 84)
        let pages = stats.words / 300
        let milestone = stats.words < 300 ? "Your first page is on its way." : stats.words < 60_000 ? "About \(grouped(pages)) \(pages == 1 ? "page" : "pages") of writing." : "Enough for \(stats.words / 60_000) short \(stats.words / 60_000 == 1 ? "book" : "books")."
        styled(milestone, 13).draw(at: NSPoint(x: inset, y: 100))
        // Today against the busiest day so far.
        let now = stats.wordsToday(today), best = max(1, stats.days.values.max() ?? 1)
        let bar = NSRect(x: inset, y: 134, width: bounds.width - inset * 2, height: 22)
        Theme.track.setFill(); NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        let filled = now > 0 ? max(12, bar.width * CGFloat(now) / CGFloat(best)) : 0
        if now > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: filled, height: bar.height), xRadius: 6, yRadius: 6).fill()
        }
        // Inside the fill when it fits there, otherwise just after it.
        let plain = "Today  \(grouped(now))", font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let fits = (plain as NSString).size(withAttributes: [.font: font]).width + 16 <= filled
        let label = NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: fits ? NSColor.white : Theme.quiet])
        label.draw(at: NSPoint(x: bar.minX + (fits ? 8 : filled + 8), y: bar.midY - label.size().height / 2))
    }
}

// Words by app, from the app that was in front for each dictation. Only its identifier and a count are kept.
final class UsageCard: TileView {
    static let rows = 5
    // An app's real name and icon when it is installed; otherwise the last part of its identifier.
    private static var known: [String: (name: String, icon: NSImage?)] = [:]
    static func describe(_ bundle: String) -> (name: String, icon: NSImage?) {
        if let cached = known[bundle] { return cached }
        let found = lookUp(bundle); known[bundle] = found
        return found
    }
    private static func lookUp(_ bundle: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            return (bundle.split(separator: ".").last.map(String.init) ?? bundle, nil)
        }
        return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), NSWorkspace.shared.icon(forFile: url.path))
    }
    override func draw(_ dirtyRect: NSRect) {
        drawCard()
        styled("Where you dictate", 17, .semibold).draw(at: NSPoint(x: inset, y: 16))
        let used = stats.apps.filter { $0.value > 0 }
        let count = caps("Apps used | \(used.count)")
        count.draw(at: NSPoint(x: bounds.width - inset - count.size().width, y: 22))
        guard !used.isEmpty else {
            styled("The apps you dictate into will appear here.", 12.5, .regular, Theme.quiet).draw(at: NSPoint(x: inset, y: 62))
            return
        }
        let total = CGFloat(max(1, used.values.reduce(0, +)))
        // Busiest first; ties in a stable order so the list does not shuffle between redraws.
        let top = used.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(Self.rows)
        let left = inset + 32, room = bounds.width - left - inset, most = CGFloat(top.first?.value ?? 1)
        for (index, entry) in top.enumerated() {
            let y = 58 + CGFloat(index) * 36, share = CGFloat(entry.value) / total
            let app = Self.describe(entry.key)
            app.icon?.draw(in: NSRect(x: inset, y: y, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // The bar is never narrower than its percentage label.
            let percent = styled("\(Int((share * 100).rounded()))%", 11, .semibold, .white, numeral: true)
            // Lengths are relative to the busiest app, so the ranking reads at a glance.
            let width = max(40, room * 0.45 * CGFloat(entry.value) / most)
            NSColor.controlAccentColor.withAlphaComponent(0.5 + 0.5 * CGFloat(entry.value) / most).setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: width, height: 24), xRadius: 6, yRadius: 6).fill()
            percent.draw(at: NSPoint(x: left + (width - percent.size().width) / 2, y: y + (24 - percent.size().height) / 2))
            // The name gives way before the count does.
            let words = caps(grouped(entry.value), Theme.ink)
            let space = bounds.width - inset - (left + width + 10) - words.size().width - 8
            let name = NSMutableAttributedString(attributedString: styled(app.name, 12.5))
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            name.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: name.length))
            if space > 20 { name.draw(in: NSRect(x: left + width + 10, y: y + (24 - name.size().height) / 2, width: space, height: name.size().height)) }
            words.draw(at: NSPoint(x: bounds.width - inset - words.size().width, y: y + (24 - words.size().height) / 2))
        }
    }
}

// Day streak with a calendar of the last weeks, darker for busier days.
final class StreakCard: TileView {
    var today = Date()
    static let weeks = 16
    static func shade(_ words: Int?) -> NSColor {
        guard let words else { return .clear }
        let band = Stats.band(words)
        return band == 0 ? Theme.track : NSColor.controlAccentColor.withAlphaComponent([0.28, 0.5, 0.75, 1][band - 1])
    }
    override func draw(_ dirtyRect: NSRect) {
        drawCard()
        let streak = stats.streaks(today: today)
        styled("\(streak.current) day streak", 17, .semibold).draw(at: NSPoint(x: inset, y: 16))
        let longest = caps("Longest streak | \(streak.longest) \(streak.longest == 1 ? "day" : "days")")
        longest.draw(at: NSPoint(x: bounds.width - inset - longest.size().width, y: 22))
        let grid = stats.heatmap(weeks: Self.weeks, today: today)
        let cell: CGFloat = 13, step: CGFloat = 17, left = inset + 34, top: CGFloat = 76
        let calendar = Calendar.current
        for (row, name) in calendar.shortWeekdaySymbols.enumerated() {
            styled(name, 10, .regular, Theme.quiet).draw(at: NSPoint(x: inset, y: top + CGFloat(row) * step))
        }
        var lastMonth = -1
        for (column, week) in grid.enumerated() {
            if let first = week.first {
                let month = calendar.component(.month, from: first.date)
                if month != lastMonth && column < grid.count - 1 {
                    if lastMonth != -1 || calendar.component(.day, from: first.date) <= 7 { styled(calendar.shortMonthSymbols[month - 1], 10, .regular, Theme.quiet).draw(at: NSPoint(x: left + CGFloat(column) * step, y: top - 20)) }
                    lastMonth = month
                }
            }
            for (row, day) in week.enumerated() {
                Self.shade(day.words).setFill()
                NSBezierPath(roundedRect: NSRect(x: left + CGFloat(column) * step, y: top + CGFloat(row) * step, width: cell, height: cell), xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
        // Legend
        let legendY = top + 7 * step + 14
        let more = styled("More", 10, .regular, Theme.quiet); more.draw(at: NSPoint(x: left, y: legendY))
        var x = left + more.size().width + 8
        for words in [750, 500, 250, 1, 0] {
            Self.shade(words).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: legendY, width: cell, height: cell), xRadius: 3.5, yRadius: 3.5).fill(); x += step
        }
        styled("Less", 10, .regular, Theme.quiet).draw(at: NSPoint(x: x + 4, y: legendY))
    }
}

final class InsightsView: NSView {
    private let pace = PaceTile(), tidy = TidyTile(), total = TotalTile(), usage = UsageCard(), streak = StreakCard()
    init() {
        super.init(frame: .zero)
        func row(_ views: [NSView], height: CGFloat) -> NSStackView {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 12; row.alignment = .top
            for view in views { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
            return row
        }
        let top = row([pace, tidy, total], height: 176), bottom = row([usage, streak], height: 246)
        pace.widthAnchor.constraint(equalToConstant: 190).isActive = true
        tidy.widthAnchor.constraint(equalToConstant: 216).isActive = true
        usage.widthAnchor.constraint(equalToConstant: 344).isActive = true
        let column = NSStackView(views: [top, bottom]); column.orientation = .vertical; column.spacing = 12; column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     top.widthAnchor.constraint(equalTo: column.widthAnchor), bottom.widthAnchor.constraint(equalTo: column.widthAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func show(_ stats: Stats, today: Date = Date()) {
        total.today = today; streak.today = today
        for tile in [pace, tidy, total, usage, streak] as [TileView] { tile.stats = stats }
    }
}
