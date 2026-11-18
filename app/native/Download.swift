import AppKit

// What the worker has said about getting the two models ready: their sizes, the bytes fetched so far, and
// which are in memory. Kept apart from drawing so the arithmetic can be checked without a window.
struct ModelSetup {
    enum Phase: Equatable { case waiting, loading, fetching, preparing, ready }
    struct Part: Equatable {
        let key: String, name: String
        var size: Int64?
        var fetched: Int64 = 0
        var phase = Phase.waiting
        // Already on this Mac: it is read, not fetched, so it stays out of the byte counts.
        var stored = false
        // Bytes this part counts towards the whole: all of it once ready.
        var counted: Int64 { phase == .ready ? size ?? 0 : min(fetched, size ?? fetched) }
    }
    private(set) var parts: [Part] = []
    // Smoothed bytes per second, measured over at least half a second at a time.
    private(set) var speed: Double?
    private var sample: (time: TimeInterval, bytes: Int64)?, samples = 0
    static let names = ["speech": "Speech recognition", "cleanup": "Text cleanup"]

    // The worker may name each model; older workers send only the key.
    mutating func plan(_ models: [(key: String, size: Int64?, name: String?)]) {
        parts = models.map { Part(key: $0.key, name: $0.name ?? Self.names[$0.key] ?? $0.key, size: $0.size) }
        speed = nil; sample = nil; samples = 0
    }
    mutating func plan(_ models: [(key: String, size: Int64?)]) {
        plan(models.map { ($0.key, $0.size, nil) })
    }
    mutating func started(_ key: String) { edit(key) { if $0.phase == .waiting { $0.phase = .loading } }; sample = nil }
    mutating func progress(_ key: String, fetched: Int64, total: Int64, at time: TimeInterval) {
        edit(key) { part in
            // The reported total wins over the planned size: the speech model also brings a Core ML encoder
            // that the SDK's size for it leaves out.
            if total > 0 { part.size = total }
            // A first report that is already complete means the file was on disk: loading, not downloading.
            if part.phase == .loading && fetched >= total && part.fetched == 0 { part.stored = true; return }
            part.fetched = fetched
            part.phase = fetched >= total ? .preparing : .fetching
        }
        let bytes = parts.reduce(0) { $0 + $1.fetched }
        // A gap of more than three seconds is a pause between files (36 s preparing the speech model, 15 s before
        // the cleanup download, measured on November 11), not a slow line: start measuring again from here.
        guard let last = sample, time - last.time <= 3 else { sample = (time, bytes); return }
        guard time - last.time >= 0.5 else { return }
        let instant = Double(bytes - last.bytes) / (time - last.time)
        speed = speed.map { 0.7 * $0 + 0.3 * instant } ?? instant
        sample = (time, bytes); samples += 1
    }
    mutating func loaded(_ key: String) { edit(key) { $0.phase = .ready }; sample = nil }
    private mutating func edit(_ key: String, _ change: (inout Part) -> Void) {
        guard let index = parts.firstIndex(where: { $0.key == key }) else { return }
        change(&parts[index])
    }

    var ready: Bool { !parts.isEmpty && parts.allSatisfy { $0.phase == .ready } }
    // True once any byte has come over the network in this run, which is what makes this a first run.
    var downloading: Bool { parts.contains { $0.fetched > 0 && ($0.phase == .fetching || $0.phase == .preparing || $0.phase == .ready) } }
    var total: Int64 { parts.reduce(0) { $0 + ($1.stored ? 0 : $1.size ?? 0) } }
    var done: Int64 { parts.reduce(0) { $0 + ($1.stored ? 0 : $1.counted) } }
    // Never shown as full before both models are in memory: the last moments are spent loading, not fetching.
    var fraction: Double {
        if ready { return 1 }
        guard total > 0 else { return 0 }
        return min(0.99, Double(done) / Double(total))
    }
    var remaining: TimeInterval? {
        guard downloading, samples >= 2, let speed, speed > 1 else { return nil }
        let left = parts.reduce(Int64(0)) { $0 + ($1.stored ? 0 : max(0, ($1.size ?? 0) - ($1.phase == .ready ? $1.size ?? 0 : $1.fetched))) }
        return left > 0 ? Double(left) / speed : nil
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 50 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 90 { return minutes == 1 ? "about a minute left" : "about \(minutes) minutes left" }
        return "about \(Int((seconds / 3600).rounded())) hours left"
    }
    var headline: String {
        if ready { return "Models ready" }
        return downloading ? "Downloading the speech models" : "Loading the speech models"
    }
    // The line under the headline, and the whole status for places with room for one sentence.
    var detail: String {
        if ready { return "Everything now runs on this Mac, offline." }
        guard downloading else { return "Reading them from this Mac." }
        var text = "\(Self.bytes(done)) of \(Self.bytes(total))"
        if let remaining { text += " · \(Self.timeLeft(remaining))" }
        return text
    }
    func state(of part: Part) -> String {
        switch part.phase {
        case .waiting: return "Waiting"
        case .loading: return "Loading"
        case .fetching: return part.size.map { "\(Self.bytes(part.fetched)) of \(Self.bytes($0))" } ?? Self.bytes(part.fetched)
        case .preparing: return "Getting ready"
        case .ready: return part.size.map(Self.bytes) ?? "Ready"
        }
    }
}

// First-run progress, drawn: one bar split between the models by size, a line per model, and the overall
// share in rounded numerals. The compact form is a single line of text over a thin bar, for the bottom of a screen.
final class DownloadView: NSView {
    var setup = ModelSetup() { didSet { updateAccessibility(); if Motion.reduced { settle() }; run() } }
    let compact: Bool
    // Shown values ease towards the reported ones, so ten updates a second still read as one smooth fill.
    private var shown: [Double] = [], shownWhole = 0.0
    private var clock: TimeInterval = 0
    private var timer: Timer?
    // For previews: a fixed moment of the shine, with every value already arrived.
    var frozen: TimeInterval? { didSet { settle(); needsDisplay = true } }

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0); setAccessibilityMaxValue(1)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { compact ? NSSize(width: 300, height: 26) : NSSize(width: 460, height: 132) }
    override var isFlipped: Bool { true }

    // The frame timer runs only while there is something to move, and stops itself once everything has arrived.
    override func viewDidMoveToWindow() { run() }
    override func viewDidUnhide() { run() }
    private func run() {
        guard timer == nil, window != nil, !isHiddenOrHasHiddenAncestor, frozen == nil, moving else { return }
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    // Shine, breathing and turning rings play while a model is fetched or read; values move until they arrive.
    private var moving: Bool {
        let busy = !Motion.reduced && setup.parts.contains { [.loading, .fetching, .preparing].contains($0.phase) }
        return busy || abs(shownWhole - setup.fraction) > 0.0005 || zip(shown, targets()).contains { abs($0 - $1) > 0.0005 } || shown.count != setup.parts.count
    }
    private func targets() -> [Double] { setup.parts.map { part in part.phase == .ready ? 1 : part.size.map { $0 > 0 ? Double(part.counted) / Double($0) : 0 } ?? 0 } }
    func settle() { shown = targets(); shownWhole = setup.fraction }
    private func tick() {
        guard frozen == nil, window != nil, !isHiddenOrHasHiddenAncestor, moving else { timer?.invalidate(); timer = nil; needsDisplay = true; return }
        // Covered or minimised: keep time, skip the drawing.
        guard window?.occlusionState.contains(.visible) == true else { return }
        let goal = targets()
        if shown.count != goal.count { shown = goal }
        let pull = Motion.reduced ? 1 : 0.12
        shown = zip(shown, goal).map { $0 + ($1 - $0) * pull }
        shownWhole += (setup.fraction - shownWhole) * pull
        clock += 1.0 / 60
        needsDisplay = true
    }
    private var announced = -1
    private func updateAccessibility() {
        setAccessibilityLabel("\(setup.headline). \(setup.detail)")
        setAccessibilityValue(setup.fraction)
        // VoiceOver hears about each whole percent, not each of the ten updates a second.
        let percent = Int(setup.fraction * 100)
        if percent != announced, !isHiddenOrHasHiddenAncestor { announced = percent; NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let time = frozen ?? clock
        if compact { drawCompact(time); return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.radius, yRadius: Theme.radius)
        Theme.card.setFill(); card.fill(); Theme.hairline.setStroke(); card.lineWidth = 1; card.stroke()
        let inset: CGFloat = 18, width = bounds.width - inset * 2
        write(setup.headline, at: NSPoint(x: inset, y: 16), font: .systemFont(ofSize: 14.5, weight: .semibold), color: Theme.ink)
        // Reading from disk has no byte count to show; a percentage there would only sit at nought.
        if setup.downloading {
            let percent = NSAttributedString(string: "\(Int((shownWhole * 100).rounded(.down)))%", attributes: [.font: Theme.numeral(14.5), .foregroundColor: Theme.quiet])
            percent.draw(at: NSPoint(x: bounds.width - inset - percent.size().width, y: 16))
        }
        write(setup.detail, at: NSPoint(x: inset, y: 37), font: .systemFont(ofSize: 12), color: Theme.quiet)
        drawBar(NSRect(x: inset, y: 62, width: width, height: 8), time: time)
        // One line per model under the bar: a symbol for its state, its name, and its own count on the right.
        for (index, part) in setup.parts.enumerated() {
            // Three lines sit a little closer so the card keeps its height and the screen its layout.
            let y = setup.parts.count > 2 ? 78 + CGFloat(index) * 16.5 : 84 + CGFloat(index) * 21
            let (symbol, color): (String, NSColor) = {
                switch part.phase {
                case .ready: return ("checkmark.circle.fill", Theme.good)
                case .fetching: return ("arrow.down.circle.fill", .controlAccentColor)
                case .loading, .preparing: return ("circle.dotted", .controlAccentColor)
                case .waiting: return ("circle", Theme.faint)
                }
            }()
            // Filled symbols carry a white mark (the tick, the arrow) on the coloured disc.
            let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold).applying(.init(paletteColors: symbol.hasSuffix(".fill") ? [.white, color] : [color]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = image.size
                NSGraphicsContext.saveGraphicsState()
                // A turning ring while a model is being read into memory; the glyph is symmetric, so turning it is enough.
                if part.phase == .loading || part.phase == .preparing, !Motion.reduced {
                    let spin = NSAffineTransform(); spin.translateX(by: inset + 7, yBy: y + 7.5); spin.rotate(byRadians: CGFloat(time) * 2.4); spin.translateX(by: -(inset + 7), yBy: -(y + 7.5)); spin.concat()
                }
                image.draw(in: NSRect(x: inset + 7 - size.width / 2, y: y + 7.5 - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            write(part.name, at: NSPoint(x: inset + 22, y: y), font: .systemFont(ofSize: 12.5, weight: .medium), color: part.phase == .waiting ? Theme.quiet : Theme.ink)
            let count = NSAttributedString(string: setup.state(of: part), attributes: [.font: Theme.numeral(12, .regular), .foregroundColor: Theme.quiet])
            count.draw(at: NSPoint(x: bounds.width - inset - count.size().width, y: y))
        }
    }
    private func drawCompact(_ time: TimeInterval) {
        let text = setup.downloading ? "Downloading the speech models · \(Int((shownWhole * 100).rounded(.down)))%" : "Loading the speech models"
        let line = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Theme.quiet])
        line.draw(at: NSPoint(x: (bounds.width - line.size().width) / 2, y: 0))
        drawBar(NSRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4), time: time)
    }
    private func write(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }
    // Each model gets a share of the bar matching its size, with a small gap between. The share being fetched
    // carries a soft band of light that sweeps along its filled part.
    private func drawBar(_ rect: NSRect, time: TimeInterval) {
        let parts = setup.parts
        guard !parts.isEmpty else { return }
        let gap: CGFloat = parts.count > 1 ? 4 : 0, radius = rect.height / 2
        let sizes = parts.map { CGFloat(max($0.size ?? 0, 1)) }, sum = sizes.reduce(0, +)
        let usable = rect.width - gap * CGFloat(parts.count - 1)
        var x = rect.minX
        for (index, part) in parts.enumerated() {
            let width = max(rect.height, usable * sizes[index] / sum)
            let slot = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
            x += width + gap
            let track = NSBezierPath(roundedRect: slot, xRadius: radius, yRadius: radius)
            Theme.track.setFill(); track.fill()
            let share = index < shown.count ? CGFloat(min(1, max(0, shown[index]))) : 0
            guard share > 0 else {
                // A model being read from disk has no bytes to show, so its whole slot breathes instead.
                if part.phase == .loading, !Motion.reduced {
                    NSColor.controlAccentColor.withAlphaComponent(0.12 + 0.12 * CGFloat(sin(time * 3) * 0.5 + 0.5)).setFill(); track.fill()
                }
                continue
            }
            let filled = NSRect(x: slot.minX, y: slot.minY, width: max(rect.height, slot.width * share), height: slot.height)
            let fill = NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius)
            (part.phase == .ready ? Theme.good : NSColor.controlAccentColor).setFill(); fill.fill()
            guard part.phase == .fetching || part.phase == .preparing, !Motion.reduced else { continue }
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            let band: CGFloat = 70, travel = filled.width + band
            let position = filled.minX - band + travel * CGFloat((time / 1.6).truncatingRemainder(dividingBy: 1))
            NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0)])?
                .draw(in: NSRect(x: position, y: filled.minY, width: band, height: filled.height), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
