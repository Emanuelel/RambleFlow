import AppKit

// The moving picture on each setup screen. Everything is drawn here, frame by frame, from one clock:
// no image files, no video, and a single still frame when Reduce Motion is on.
final class HeroView: NSView {
    enum Scene { case microphone, accessibility, keys, done }
    var scene = Scene.microphone { didSet { if scene != oldValue { began = Self.now(); needsDisplay = true } } }
    var keys = ["fn"]
    var appName = "This app"
    // While a practice recording runs, the keys stay down and the bars follow the real microphone.
    var recording = false
    var level: CGFloat = 0
    // A fixed moment to draw, for rendering stills of the animation off screen.
    var frozen: CGFloat? { didSet { needsDisplay = true } }
    private var began = HeroView.now()
    private var timer: Timer?
    private var shown: CGFloat = 0
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var accent: NSColor { .controlAccentColor }
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var intrinsicContentSize: NSSize { NSSize(width: 380, height: 220) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil, !still else { return }
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.needsDisplay = true
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    deinit { timer?.invalidate() }

    // The library's smooth-out curve, cubic-bezier(0.22, 1, 0.36, 1): a quick start and a long, soft landing.
    private func ease(_ x: CGFloat) -> CGFloat { Motion.smoothOut(x) }
    private func span(_ t: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat { min(1, max(0, (t - from) / (to - from))) }
    private func disc(_ centre: NSPoint, _ radius: CGFloat, _ color: NSColor) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
    private func ring(_ centre: NSPoint, _ radius: CGFloat, _ color: NSColor, width: CGFloat = 2) {
        let path = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        color.setStroke(); path.lineWidth = width; path.stroke()
    }
    private func symbol(_ name: String, size: CGFloat, color: NSColor, at centre: NSPoint, scale: CGFloat = 1) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let width = image.size.width * scale, height = image.size.height * scale
        image.draw(in: NSRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let time = frozen ?? (still ? 1.7 : CGFloat(Self.now() - began))
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        switch scene {
        case .microphone: drawMicrophone(time, centre)
        case .accessibility: drawSwitch(time, centre)
        case .keys: drawKeys(time, centre)
        case .done: drawDone(time, centre)
        }
    }

    // Sound leaving the microphone: rings that grow and fade, one after another.
    private func drawMicrophone(_ time: CGFloat, _ centre: NSPoint) {
        for index in 0..<3 {
            let progress = (time / 2.6 + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            let radius = 46 + ease(progress) * 62
            disc(centre, radius, accent.withAlphaComponent(0.10 * (1 - progress)))
            ring(centre, radius, accent.withAlphaComponent(0.42 * (1 - progress)), width: 1.5)
        }
        let breath = 1 + 0.035 * sin(time * 2.4)
        disc(centre, 46 * breath, accent.withAlphaComponent(0.2))
        symbol("mic.fill", size: 44, color: accent, at: centre, scale: breath)
    }

    // The one thing to do in System Settings, acted out: find this app in the list and switch it on.
    private func drawSwitch(_ time: CGFloat, _ centre: NSPoint) {
        let loop = time.truncatingRemainder(dividingBy: 4.2)
        let on = ease(span(loop, 1.5, 1.95)) * (1 - ease(span(loop, 3.8, 4.2)))
        let card = NSRect(x: centre.x - 170, y: centre.y - 62, width: 340, height: 124)
        let panel = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        Theme.card.setFill(); panel.fill()
        Theme.hairline.setStroke(); panel.lineWidth = 1; panel.stroke()
        let caption = NSAttributedString(string: "ACCESSIBILITY", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: Theme.quiet, .kern: 1.0])
        caption.draw(at: NSPoint(x: card.minX + 18, y: card.maxY - 28))
        // Two other apps in the list, greyed, so the row that matters stands out.
        for (index, y) in [card.maxY - 52].enumerated() where index == 0 {
            Theme.track.setFill()
            NSBezierPath(roundedRect: NSRect(x: card.minX + 18, y: y, width: 22, height: 14), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: card.minX + 50, y: y + 3, width: 96, height: 8), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: card.maxX - 52, y: y, width: 34, height: 14), xRadius: 7, yRadius: 7).fill()
        }
        let row = NSRect(x: card.minX + 10, y: card.minY + 12, width: card.width - 20, height: 44)
        accent.withAlphaComponent(0.10 + 0.08 * on).setFill()
        NSBezierPath(roundedRect: row, xRadius: 10, yRadius: 10).fill()
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: row.minX + 10, y: row.midY - 12, width: 24, height: 24), xRadius: 6, yRadius: 6).fill()
        symbol("mic.fill", size: 11, color: .white, at: NSPoint(x: row.minX + 22, y: row.midY))
        let name = NSAttributedString(string: appName, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Theme.ink])
        name.draw(at: NSPoint(x: row.minX + 44, y: row.midY - name.size().height / 2))
        // The switch itself.
        let track = NSRect(x: row.maxX - 58, y: row.midY - 13, width: 46, height: 26)
        let shape = NSBezierPath(roundedRect: track, xRadius: 13, yRadius: 13)
        Theme.track.setFill(); shape.fill()
        Theme.good.withAlphaComponent(on).setFill(); shape.fill()
        let knob = NSPoint(x: track.minX + 13 + on * 20, y: track.midY)
        disc(knob, 10.5, .white)
        // A pointer travels to the switch and presses it.
        let travel = ease(span(loop, 0.5, 1.4)), leaving = ease(span(loop, 2.4, 3.2))
        let from = NSPoint(x: card.maxX + 26, y: card.minY - 34), target = NSPoint(x: track.midX + 4, y: track.midY - 6)
        let pointer = NSPoint(x: from.x + (target.x - from.x) * travel + 40 * leaving, y: from.y + (target.y - from.y) * travel - 30 * leaving)
        let press = span(loop, 1.4, 1.9)
        if press > 0 && press < 1 { ring(NSPoint(x: track.midX, y: track.midY), 14 + 18 * ease(press), accent.withAlphaComponent(0.5 * (1 - press)), width: 2) }
        let arrow = NSBezierPath()
        arrow.move(to: pointer); arrow.line(to: NSPoint(x: pointer.x, y: pointer.y - 19)); arrow.line(to: NSPoint(x: pointer.x + 5, y: pointer.y - 14.5))
        arrow.line(to: NSPoint(x: pointer.x + 8.5, y: pointer.y - 22)); arrow.line(to: NSPoint(x: pointer.x + 11.5, y: pointer.y - 20.5))
        arrow.line(to: NSPoint(x: pointer.x + 8, y: pointer.y - 13.5)); arrow.line(to: NSPoint(x: pointer.x + 14, y: pointer.y - 13.5)); arrow.close()
        let fade = 1 - ease(span(loop, 3.0, 3.4))
        NSColor.black.withAlphaComponent(fade).setFill(); arrow.fill()
        NSColor.white.withAlphaComponent(fade).setStroke(); arrow.lineWidth = 1.4; arrow.lineJoinStyle = .round; arrow.stroke()
    }

    // Press the shortcut, show the voice, then release.
    private func drawKeys(_ time: CGFloat, _ centre: NSPoint) {
        let loop = time.truncatingRemainder(dividingBy: 3.6)
        let pressed = recording ? 1 : ease(span(loop, 0.35, 0.6)) * (1 - ease(span(loop, 2.6, 2.85)))
        // The live level eases toward the microphone so the bars do not jitter.
        shown += ((recording ? level : 0) - shown) * 0.25
        let size: CGFloat = 78, gap: CGFloat = 16, total = CGFloat(keys.count) * size + CGFloat(keys.count - 1) * gap
        let base = NSPoint(x: centre.x - total / 2, y: centre.y - 62)
        for (index, key) in keys.enumerated() {
            let lag = recording ? pressed : ease(span(loop, 0.35 + CGFloat(index) * 0.08, 0.6 + CGFloat(index) * 0.08)) * (1 - ease(span(loop, 2.6, 2.85)))
            let x = base.x + CGFloat(index) * (size + gap)
            // The base the key sits on, then the cap, which sinks when pressed.
            Theme.track.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: base.y - 6, width: size, height: size), xRadius: 17, yRadius: 17).fill()
            let cap = NSRect(x: x, y: base.y - 6 * lag, width: size, height: size)
            let shape = NSBezierPath(roundedRect: cap, xRadius: 17, yRadius: 17)
            Theme.card.setFill(); shape.fill()
            accent.withAlphaComponent(0.22 * lag).setFill(); shape.fill()
            (lag > 0.02 ? accent.withAlphaComponent(0.35 + 0.65 * lag) : Theme.hairline).setStroke(); shape.lineWidth = 1.5 + lag; shape.stroke()
            let glyph = NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: Theme.ink])
            glyph.draw(at: NSPoint(x: cap.midX - glyph.size().width / 2, y: cap.midY - glyph.size().height / 2))
        }
        // The voice: bars above the keys, alive only while the keys are down.
        let bars = 15, width: CGFloat = 5, step: CGFloat = 11, left = centre.x - CGFloat(bars - 1) * step / 2, line = centre.y + 62
        for index in 0..<bars {
            let shape = 1 - abs(CGFloat(index) - CGFloat(bars - 1) / 2) / CGFloat(bars) * 1.3
            let wave = 0.5 + 0.5 * sin(time * 7.5 + CGFloat(index) * 1.25) * sin(time * 3.1 + CGFloat(index) * 0.6)
            let voice = recording ? max(0.12, shown) * (0.55 + 0.45 * wave) : pressed * (0.25 + 0.75 * wave) * ease(span(loop, 0.6, 0.9))
            let height = 5 + 44 * voice * shape
            accent.withAlphaComponent(0.3 + 0.7 * max(pressed, 0.0)).setFill()
            NSBezierPath(roundedRect: NSRect(x: left + CGFloat(index) * step - width / 2, y: line - height / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    // The library's "success check": four half-second lanes run together. The mark fades in and turns from
    // 80 degrees to upright on the smooth-out curve, rises 40 points on the bounce curve, and its stroke
    // draws itself over half a second after an 80 ms delay. (The recipe's fourth lane is a blur clearing;
    // a picture drawn line by line has no blur to clear, so the fade carries that.)
    private func drawDone(_ time: CGFloat, _ centre: NSPoint) {
        let good = Theme.good
        let lane = span(time, 0, 0.5)
        let fade = Motion.smoothOut(lane), turn = (1 - Motion.smoothOut(lane)) * 80, rise = (1 - Motion.bounce(lane)) * 40
        for index in 0..<2 {
            let burst = span(time, 0.3 + CGFloat(index) * 0.18, 1.45 + CGFloat(index) * 0.18)
            if burst > 0 && burst < 1 { ring(centre, 52 + 50 * ease(burst), good.withAlphaComponent(0.45 * (1 - burst)), width: 2) }
        }
        let breath = 1 + 0.02 * sin(max(0, time - 1) * 2)
        NSGraphicsContext.saveGraphicsState()
        let move = NSAffineTransform()
        move.translateX(by: centre.x, yBy: centre.y - rise); move.rotate(byDegrees: turn); move.translateX(by: -centre.x, yBy: -centre.y)
        move.concat()
        disc(centre, 86 * breath, good.withAlphaComponent(0.09 * fade))
        disc(centre, 56 * breath, good.withAlphaComponent(0.2 * fade))
        // The tick is two strokes; draw as much of their length as the clock allows.
        let points = [NSPoint(x: centre.x - 20, y: centre.y), NSPoint(x: centre.x - 6, y: centre.y - 14), NSPoint(x: centre.x + 22, y: centre.y + 16)]
        let first = hypot(points[1].x - points[0].x, points[1].y - points[0].y), second = hypot(points[2].x - points[1].x, points[2].y - points[1].y)
        var remaining = Motion.smoothOut(span(time, 0.08, 0.58)) * (first + second)
        if remaining > 0.5 {
            let path = NSBezierPath(); path.lineWidth = 7; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: points[0])
            for (start, end, length) in [(points[0], points[1], first), (points[1], points[2], second)] {
                let part = min(1, remaining / length)
                path.line(to: NSPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
                remaining -= length
                if remaining <= 0 { break }
            }
            good.withAlphaComponent(fade).setStroke(); path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
