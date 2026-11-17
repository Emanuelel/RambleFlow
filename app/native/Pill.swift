import AppKit

enum PillState: Equatable { case idle, recording, processing, notice(String) }
enum PillZone { case cancel, stop, body }

// Maps an input RMS (0...1 of full scale) onto a 0...1 meter. Quiet rooms sit near 0, speech near 0.5 to 1.
func inputLevel(rms: Double) -> Float {
    guard rms > 0 else { return 0 }
    return Float(min(1, max(0, (20 * log10(rms) + 55) / 45)))
}

final class PillView: NSView {
    static let barCount = 11
    var state = PillState.idle { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }
    var hint = ""
    var bars = [CGFloat](repeating: 0.1, count: PillView.barCount) { didSet { needsDisplay = true } }
    var phase: CGFloat = 0 { didSet { needsDisplay = true } }
    var clicked: ((PillZone) -> Void)?
    var hoverChanged: (() -> Void)?
    var moved: (() -> Void)?
    private var dragStart: NSPoint?, windowStart: NSPoint?, downState: PillState?
    private(set) var dragging = false
    private var tracking: NSTrackingArea?
    private var hoverPoll: Timer?
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static func width(of text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    var preferredSize: NSSize {
        switch state {
        case .idle: return hovered ? NSSize(width: Self.width(of: hint) + 36, height: 32) : NSSize(width: 64, height: 20)
        case .recording: return NSSize(width: 204, height: 44)
        case .processing: return NSSize(width: 124, height: 44)
        case .notice(let text): return NSSize(width: min(460, Self.width(of: text) + 36), height: 34)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    // The pill resizes under a still pointer, which makes AppKit report false exits and re-entries.
    // Entering starts a short poll of the real pointer position, and only that poll ends the hover.
    override func mouseEntered(with event: NSEvent) {
        if !hovered { hovered = true; hoverChanged?() }
        guard hoverPoll == nil else { return }
        let poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, let frame = self.window?.frame else { timer.invalidate(); return }
            if frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { return }
            timer.invalidate(); self.hoverPoll = nil; self.hovered = false; self.hoverChanged?()
        }
        RunLoop.main.add(poll, forMode: .common); hoverPoll = poll
    }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; windowStart = window?.frame.origin; dragging = false; downState = state }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart else { return }
        let now = NSEvent.mouseLocation
        if !dragging && hypot(now.x - dragStart.x, now.y - dragStart.y) > 4 { dragging = true }
        if dragging { window?.setFrameOrigin(NSPoint(x: windowStart.x + now.x - dragStart.x, y: windowStart.y + now.y - dragStart.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragging = false }
        if dragging { moved?(); return }
        // A press that changed the pill underneath itself is not a click on what is shown now.
        guard state == downState else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if state == .recording { clicked?(x < 42 ? .cancel : x > bounds.width - 42 ? .stop : .body) }
        else if state == .processing { clicked?(x < 42 ? .cancel : .body) }
        else { clicked?(.body) }
    }
    private func drawCancel(_ middle: CGFloat) {
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: middle - 14, width: 28, height: 28)).fill()
        let cross = NSBezierPath(); cross.lineWidth = 1.6; cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: 17, y: middle - 5)); cross.line(to: NSPoint(x: 27, y: middle + 5))
        cross.move(to: NSPoint(x: 17, y: middle + 5)); cross.line(to: NSPoint(x: 27, y: middle - 5))
        NSColor(white: 1, alpha: 0.9).setStroke(); cross.stroke()
    }
    private func drawText(_ text: String, alpha: CGFloat = 0.94) {
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: style]
        let height = ceil(Self.font.ascender - Self.font.descender)
        (text as NSString).draw(in: NSRect(x: 12, y: (bounds.height - height) / 2, width: bounds.width - 24, height: height), withAttributes: attributes)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let resting = state == .idle && !hovered
        NSColor(white: 0.07, alpha: resting ? 0.8 : 0.92).setFill(); capsule.fill()
        NSColor(white: 1, alpha: 0.22).setStroke(); capsule.lineWidth = 1; capsule.stroke()
        let middle = bounds.midY
        switch state {
        case .idle:
            if hovered && bounds.height > 26 { drawText(hint) } else if !hovered {
                // A still, miniature meter says what the capsule is for.
                NSColor(white: 1, alpha: 0.78).setFill()
                for (index, height) in ([4, 8, 11, 8, 4] as [CGFloat]).enumerated() {
                    NSBezierPath(roundedRect: NSRect(x: bounds.midX - 11.25 + CGFloat(index) * 5, y: middle - height / 2, width: 2.5, height: height), xRadius: 1.25, yRadius: 1.25).fill()
                }
            }
        case .notice(let text): drawText(text)
        case .processing:
            drawCancel(middle)
            for index in 0..<3 {
                let pulse = 0.5 + 0.5 * sin(phase * 0.9 - CGFloat(index) * 1.1)
                NSColor(white: 1, alpha: 0.35 + 0.6 * pulse).setFill()
                let size = 5 + 1.5 * pulse
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + 16 + CGFloat(index - 1) * 14 - size / 2, y: middle - size / 2, width: size, height: size)).fill()
            }
        case .recording:
            // Cancel on the left, stop on the right, the meter between them.
            drawCancel(middle)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 36, y: middle - 14, width: 28, height: 28)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 27, y: middle - 5, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            let left: CGFloat = 50, right = bounds.width - 50, barWidth: CGFloat = 3.5
            let step = (right - left - barWidth) / CGFloat(bars.count - 1)
            NSColor(white: 1, alpha: 0.95).setFill()
            for (index, value) in bars.enumerated() {
                let height = max(4, min(1, value) * (bounds.height - 16))
                NSBezierPath(roundedRect: NSRect(x: left + CGFloat(index) * step, y: middle - height / 2, width: barWidth, height: height), xRadius: 1.75, yRadius: 1.75).fill()
            }
        }
    }
}

// The floating indicator. It never takes keyboard focus, so the field being dictated into keeps it.
final class Pill {
    let view = PillView()
    private let panel: NSPanel
    private let defaults: UserDefaults
    private var timer: Timer?, noticeTimer: Timer?
    private var level: CGFloat = 0
    // Until the user drags it somewhere, the pill lives on whichever display the pointer is on.
    private var home: NSScreen?
    private var follow: Timer?
    // What the pill returns to when nothing is happening: idle, or a standing message such as loading.
    private var resting = PillState.idle
    var showsWhenIdle: Bool { didSet { defaults.set(showsWhenIdle, forKey: "pillVisible"); layout(animated: false) } }
    var state: PillState { view.state }
    init(defaults: UserDefaults, hint: String) {
        self.defaults = defaults
        showsWhenIdle = defaults.object(forKey: "pillVisible") as? Bool ?? true
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 44, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.hint = hint
        panel.contentView = view
        view.hoverChanged = { [weak self] in self?.layout(animated: true) }
        view.moved = { [weak self] in
            guard let self else { return }
            defaults.set(Double(self.panel.frame.midX), forKey: "pillX"); defaults.set(Double(self.panel.frame.minY), forKey: "pillY")
        }
        followPointer()
        layout(animated: false)
        let follow = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.view.state != .recording, self.view.state != .processing, !self.view.hovered else { return }
            if self.followPointer() { self.layout(animated: false) }
        }
        RunLoop.main.add(follow, forMode: .common); self.follow = follow
    }
    @discardableResult
    private func followPointer() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }), screen != home else { return false }
        home = screen
        return defaults.object(forKey: "pillX") == nil
    }
    func resetPosition() {
        defaults.removeObject(forKey: "pillX"); defaults.removeObject(forKey: "pillY")
        home = nil; followPointer(); layout(animated: false)
    }
    func rest(_ state: PillState) {
        resting = state
        if view.state != .recording && view.state != .processing && noticeTimer == nil { set(.idle) }
    }
    func set(_ requested: PillState) {
        noticeTimer?.invalidate(); noticeTimer = nil
        let state = requested == .idle ? resting : requested
        // A recording appears on the display being worked on, then stays put until it ends.
        if state == .recording && view.state != .recording && view.state != .processing { followPointer() }
        view.state = state
        if case .notice = requested {
            noticeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in self?.set(.idle) }
        }
        let animated = state == .recording || state == .processing
        if animated && timer == nil {
            let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(tick, forMode: .common); timer = tick
        } else if !animated {
            timer?.invalidate(); timer = nil; level = 0
            view.bars = [CGFloat](repeating: 0.1, count: PillView.barCount)
        }
        layout(animated: true)
    }
    // A notice with paper thrown up from the pill, for a milestone.
    func celebrate(_ text: String) {
        // Never over a recording or cleanup in progress: that would take Stop and Cancel away.
        guard view.state != .recording, view.state != .processing else { return }
        set(.notice(text))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let self { ConfettiView.celebrate(onScreenAbove: NSPoint(x: self.panel.frame.midX, y: self.panel.frame.maxY)) }
        }
    }
    // `problem` marks a notice that reports a failure, which gets the library's error shake.
    func notice(_ text: String, problem: Bool = false) {
        set(.notice(text))
        guard problem else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Only if the pill still shows this notice and is not being dragged; then settle exactly back in place.
            guard let self, self.view.state == .notice(text), !self.view.dragging else { return }
            Motion.shake(self.panel) { [weak self] in if let self, !self.view.dragging { self.layout(animated: false) } }
        }
    }
    func push(level value: Float) { level = max(level, CGFloat(value)) }
    private func tick() {
        view.phase += 0.25
        guard view.state == .recording else { return }
        let middle = CGFloat(PillView.barCount - 1) / 2
        view.bars = view.bars.enumerated().map { index, current in
            let envelope = 1 - abs(CGFloat(index) - middle) / middle * 0.5
            let wobble = 0.55 + 0.45 * sin(view.phase * 1.3 + CGFloat(index) * 1.7)
            return current + (max(0.1, level * envelope * wobble) - current) * 0.4
        }
        // Buffers arrive about twelve times a second; decay between them so silence settles quickly.
        level *= 0.9
    }
    // The anchor is the pill's bottom centre, so it grows upward and sideways from where the user left it.
    private var anchor: NSPoint {
        let saved = NSPoint(x: defaults.double(forKey: "pillX"), y: defaults.double(forKey: "pillY"))
        if defaults.object(forKey: "pillX") != nil, NSScreen.screens.contains(where: { $0.frame.contains(saved) }) { return saved }
        let visible = (home ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX, y: visible.minY + 14)
    }
    private func layout(animated: Bool) {
        if view.state == .idle && !showsWhenIdle { panel.orderOut(nil); return }
        // Dragging owns the frame until the mouse is released.
        if view.dragging { return }
        let size = view.preferredSize, anchor = self.anchor
        var frame = NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded(), width: size.width, height: size.height)
        // Wider states must not push Stop or Cancel off the screen the pill sits on.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.frame {
            frame.origin.x = max(screen.minX + 4, min(frame.origin.x, screen.maxX - size.width - 4))
            frame.origin.y = max(screen.minY + 4, min(frame.origin.y, screen.maxY - size.height - 4))
        }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                // "Card resize": 300 ms on smooth-out for anything that changes size.
                context.duration = 0.3; context.timingFunction = Theme.smoothOut
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }
    func setMenu(_ menu: NSMenu) { view.menu = menu }
    func close() { timer?.invalidate(); noticeTimer?.invalidate(); follow?.invalidate(); panel.orderOut(nil) }
}
