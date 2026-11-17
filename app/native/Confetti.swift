import AppKit

// Paper confetti. It is shot upward fast, the air stops it almost at once, and then it drifts down slowly,
// swaying and turning over so each piece shows a lit face and a shaded one. Given a ledge, pieces that reach
// it lie down on it. Inspired by the "confetti burst" in the owner's transitions library, whose own numbers
// are not published; the physics are this app's. Kept for moments that earn it: finishing setup, and milestones.
final class ConfettiView: NSView {
    private enum Shape { case card, ribbon, dot }
    private struct Piece {
        var position: NSPoint, velocity: NSPoint
        var spin: CGFloat, turn: CGFloat       // rotation in the plane of the screen, and its rate
        var flip: CGFloat, flipRate: CGFloat   // turning over in depth
        var sway: CGFloat, swayRate: CGFloat, swayReach: CGFloat
        let size: NSSize, color: NSColor, shape: Shape
        let depth: CGFloat                     // 0.6 far to 1 near: farther pieces are smaller, slower and fainter
        var rested = false
    }
    private var pieces: [Piece] = []
    private var timer: Timer?
    private var last = ProcessInfo.processInfo.systemUptime, age: TimeInterval = 0
    // A horizontal ledge, in this view's coordinates, that falling pieces settle on.
    private var ledge: (y: CGFloat, from: CGFloat, to: CGFloat)?
    var finished: (() -> Void)?
    // Seven saturated hues chosen to sit together, each bright enough to read on a dark or a light window.
    private static let colors: [NSColor] = {
        let hexes: [UInt32] = [0x4F8DFD, 0x2ED3B7, 0xFFC542, 0xFF7A59, 0xF45B93, 0x9B7BFF, 0x5FD46A]
        return hexes.map { hex in
            let red = CGFloat((hex >> 16) & 0xFF) / 255, green = CGFloat((hex >> 8) & 0xFF) / 255, blue = CGFloat(hex & 0xFF) / 255
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }()
    static let life: TimeInterval = 4.2

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { timer?.invalidate() }

    // Fires `count` pieces from `origin`. `aim` is the centre of the fan in radians (straight up is pi / 2)
    // and `spread` is half its width.
    func burst(from origin: NSPoint, count: Int, aim: CGFloat = .pi / 2, spread: CGFloat = 0.95, power: ClosedRange<CGFloat> = 900...1750, ledge: (y: CGFloat, from: CGFloat, to: CGFloat)? = nil) {
        if let ledge { self.ledge = ledge }
        var generator = SystemRandomNumberGenerator()
        func random(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &generator) }
        for _ in 0..<count {
            let depth = random(0.6...1)
            // Two random numbers averaged: most pieces near the middle of the fan, a few out wide.
            let angle = aim + (random(-1...1) + random(-1...1)) / 2 * spread
            let speed = random(power) * (0.7 + 0.3 * depth)
            let roll = Int.random(in: 0..<10, using: &generator)
            let shape: Shape = roll < 5 ? .card : roll < 8 ? .ribbon : .dot
            let size: NSSize
            switch shape {
            case .card: size = NSSize(width: random(7...11), height: random(9...14))
            case .ribbon: size = NSSize(width: random(3...4.5), height: random(16...26))
            case .dot: size = NSSize(width: random(5...8), height: random(5...8))
            }
            pieces.append(Piece(position: NSPoint(x: origin.x + random(-6...6), y: origin.y + random(-4...4)),
                                velocity: NSPoint(x: cos(angle) * speed, y: sin(angle) * speed),
                                spin: random(0...(2 * .pi)), turn: random(-5...5),
                                flip: random(0...(2 * .pi)), flipRate: random(5...11) * (Bool.random(using: &generator) ? 1 : -1),
                                sway: random(0...(2 * .pi)), swayRate: random(2.2...4.2), swayReach: random(18...46),
                                size: NSSize(width: size.width * depth, height: size.height * depth),
                                color: Self.colors.randomElement(using: &generator) ?? Self.colors[0], shape: shape, depth: depth))
        }
        age = 0; last = ProcessInfo.processInfo.systemUptime
        guard timer == nil else { return }
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.step()
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        advance(CGFloat(min(1.0 / 30, now - last))); last = now
        needsDisplay = true
        if age > Self.life { timer?.invalidate(); timer = nil; pieces = []; needsDisplay = true; finished?() }
    }
    // Moves every piece on by `delta` seconds. Separate from the clock so a still of any moment can be drawn.
    func advance(_ delta: CGFloat) {
        age += TimeInterval(delta)
        for index in pieces.indices where !pieces[index].rested {
            var piece = pieces[index]
            // Paper has almost no weight for its area: the launch dies away in a fraction of a second,
            // and from then on it sinks at a slow, steady rate while the air pushes it from side to side.
            let drag = exp(-3.6 * delta)
            piece.velocity.x *= drag; piece.velocity.y *= drag
            piece.velocity.y -= 620 * piece.depth * delta
            piece.sway += piece.swayRate * delta
            // A piece falls faster edge-on than face-on, which is what makes it flutter.
            let faceOn = abs(cos(piece.flip))
            let before = piece.position.y
            piece.position.x += (piece.velocity.x + cos(piece.sway) * piece.swayReach * piece.depth) * delta
            piece.position.y += piece.velocity.y * (1 - 0.35 * faceOn) * delta
            piece.spin += piece.turn * delta; piece.flip += piece.flipRate * delta
            if let ledge, piece.velocity.y < 0, before >= ledge.y, piece.position.y <= ledge.y, piece.position.x >= ledge.from + 6, piece.position.x <= ledge.to - 6 {
                // Lying on the ledge: flat, face up, still.
                piece.position.y = ledge.y; piece.rested = true
                piece.spin = (piece.spin / .pi).rounded() * .pi + .pi / 2; piece.flip = 0
            }
            pieces[index] = piece
        }
    }
    // Stops the clock, for drawing stills.
    func freeze() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        // Everything fades together over the last second.
        let fade = CGFloat(min(1, max(0, (Self.life - age) / 1.0)))
        for piece in pieces {
            let turnedOver = cos(piece.flip)
            // The face towards the viewer is the paper's colour; the back is the same colour in shade.
            let color = (turnedOver >= 0 ? piece.color : piece.color.blended(withFraction: 0.38, of: .black) ?? piece.color)
                .withAlphaComponent(fade * (0.55 + 0.45 * piece.depth))
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: piece.position.x, yBy: piece.position.y + (piece.rested ? piece.size.width / 2 : 0))
            transform.rotate(byRadians: piece.spin)
            // Turning over in depth shows as the piece narrowing to an edge and widening again.
            transform.scaleX(by: 1, yBy: piece.rested ? 1 : max(0.12, abs(turnedOver)))
            transform.concat()
            color.setFill()
            let box = NSRect(x: -piece.size.width / 2, y: -piece.size.height / 2, width: piece.size.width, height: piece.size.height)
            switch piece.shape {
            case .dot: NSBezierPath(ovalIn: box).fill()
            case .card: NSBezierPath(roundedRect: box, xRadius: 1.6, yRadius: 1.6).fill()
            case .ribbon:
                // A strip with a gentle S-bend, so it reads as a curl of paper, not a stick.
                let half = piece.size.height / 2, bend = piece.size.width * 1.4
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: -half))
                path.curve(to: NSPoint(x: 0, y: half), controlPoint1: NSPoint(x: bend, y: -half / 3), controlPoint2: NSPoint(x: -bend, y: half / 3))
                path.lineWidth = piece.size.width; path.lineCapStyle = .round
                color.setStroke(); path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // Two cannons at the bottom corners of `host` fire inward and upward across it, and the paper drifts
    // down over the whole view. `ledge` lets pieces come to rest on something, such as a button.
    static func celebrate(over host: NSView, ledge: (y: CGFloat, from: CGFloat, to: CGFloat)? = nil) {
        guard !Motion.reduced else { return }
        let view = ConfettiView(frame: host.bounds); view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        view.finished = { [weak view] in view?.removeFromSuperview() }
        view.fire(ledge: ledge)
    }
    func fire(ledge: (y: CGFloat, from: CGFloat, to: CGFloat)? = nil) {
        let view = self
        let width = bounds.width, height = bounds.height
        let power: ClosedRange<CGFloat> = (height * 2.0)...(height * 3.3)
        view.burst(from: NSPoint(x: width * 0.08, y: 0), count: 85, aim: 1.08, spread: 0.42, power: power, ledge: ledge)
        view.burst(from: NSPoint(x: width * 0.92, y: 0), count: 85, aim: .pi - 1.08, spread: 0.42, power: power)
    }
    // A fountain over the screen from `anchor`, for a celebration that happens while the window is closed.
    static func celebrate(onScreenAbove anchor: NSPoint) {
        guard !Motion.reduced else { return }
        let size = NSSize(width: 840, height: 560)
        let panel = NSPanel(contentRect: NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .statusBar; panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = ConfettiView(frame: NSRect(origin: .zero, size: size)); panel.contentView = view
        // Break the loop of panel, view and closure, or each celebration would keep its panel alive.
        view.finished = { [weak view] in panel.orderOut(nil); view?.finished = nil }
        panel.orderFrontRegardless()
        view.burst(from: NSPoint(x: size.width / 2, y: 4), count: 120, spread: 0.8, power: 1100...1900)
    }
}
