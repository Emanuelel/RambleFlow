import AppKit

// Shared look and motion. Timings and curves follow the transitions.dev scale the owner works from:
// one "smooth out" curve for anything that opens, moves or resizes, and closes that are quicker than opens.
enum Theme {
    static let smoothOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let quick = 0.15, fast = 0.25, medium = 0.35
    static let radius: CGFloat = 14
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static let background = dynamic(light: NSColor(srgbRed: 0.965, green: 0.961, blue: 0.949, alpha: 1), dark: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1))
    static let card = dynamic(light: NSColor(white: 1, alpha: 0.92), dark: NSColor(white: 1, alpha: 0.055))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    static let track = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07))
    static let thumb = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.16))
    static let ink = NSColor.labelColor
    static let quiet = NSColor.secondaryLabelColor
    static let faint = NSColor.tertiaryLabelColor
    static let good = NSColor.systemGreen, live = NSColor.systemRed, busy = NSColor.systemOrange

    // Rounded numerals with fixed-width digits, so a changing number does not shuffle sideways.
    static func numeral(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    static func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = ink, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    static func animate(_ duration: Double, _ body: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { body(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration; context.timingFunction = smoothOut; context.allowsImplicitAnimation = true
            body()
        }
    }
}

// The transitions.dev curves, evaluated exactly, for motion that is drawn frame by frame and so cannot
// hand a timing function to Core Animation.
enum Motion {
    // y for a given x on cubic-bezier(x1, y1, x2, y2), as CSS defines it.
    static func bezier(_ x: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGFloat {
        let x = min(1, max(0, x))
        func along(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var low: CGFloat = 0, high: CGFloat = 1, t = x
        for _ in 0..<24 {
            let guess = along(t, x1, x2)
            if abs(guess - x) < 0.0005 { break }
            if guess < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return along(t, y1, y2)
    }
    // "smooth-out": the default for anything that opens, moves or resizes.
    static func smoothOut(_ x: CGFloat) -> CGFloat { bezier(x, 0.22, 1, 0.36, 1) }
    // "bounce": a small overshoot, for entrances only.
    static func bounce(_ x: CGFloat) -> CGFloat { bezier(x, 0.34, 1.36, 0.64, 1) }
    // The symmetric curve the library uses for swapping one text or icon for another.
    static func inOut(_ x: CGFloat) -> CGFloat { bezier(x, 0.42, 0, 0.58, 1) }
    static let bounceTiming = CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
    static let inOutTiming = CAMediaTimingFunction(name: .easeInEaseOut)
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // "Text states swap", for any content replaced in place: the old content leaves over 150 ms, moving
    // 4 points, fading and softening by a 2-point blur; `change` runs; the new content arrives the same way.
    static func swap(_ view: NSView, change: @escaping () -> Void) {
        guard view.window?.isVisible == true, !reduced else { change(); return }
        view.wantsLayer = true; view.layerUsesCoreImageFilters = true
        guard let layer = view.layer else { change(); return }
        if layer.filters?.isEmpty != false, let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 0]) { blur.name = "soften"; layer.filters = [blur] }
        func move(_ from: (CGFloat, CGFloat, CGFloat), _ to: (CGFloat, CGFloat, CGFloat), then: @escaping () -> Void) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.quick); CATransaction.setAnimationTimingFunction(inOutTiming)
            CATransaction.setCompletionBlock(then)
            for (key, start, end) in [("opacity", from.0, to.0), ("transform.translation.y", from.1, to.1), ("filters.soften.inputRadius", from.2, to.2)] {
                let animation = CABasicAnimation(keyPath: key); animation.fromValue = start; animation.toValue = end
                animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: key)
            }
            CATransaction.commit()
        }
        // Only the newest swap on a view finishes its animation and cleans up; an older one that is
        // overtaken still applies its change, then leaves the layer to the newer one.
        let key = ObjectIdentifier(view), mine = (flights[key] ?? 0) + 1
        flights[key] = mine
        move((1, 0, 0), (0, 4, 2)) { [weak view] in
            change()
            guard flights[key] == mine else { return }
            move((0, -4, 2), (1, 0, 0)) {
                guard flights[key] == mine else { return }
                flights[key] = nil
                // Leave nothing behind: no animation, no filter, and ordinary rendering for the views inside.
                layer.removeAllAnimations(); layer.filters = nil; view?.layerUsesCoreImageFilters = false
            }
        }
    }
    private static var flights: [ObjectIdentifier: Int] = [:]
    static func swapping(_ view: NSView) -> Bool { flights[ObjectIdentifier(view)] != nil }
    // "Error state shake": 280 ms in four legs, out 6 points, back past centre, a smaller return, home.
    static func shake(_ window: NSWindow, done: (() -> Void)? = nil) {
        guard window.isVisible, !reduced else { done?(); return }
        let home = window.frame.origin
        var delay = 0.0
        for (offset, duration) in [(6.0, 0.08), (-6.0, 0.06), (4.0, 0.08), (0.0, 0.06)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration; context.timingFunction = Theme.smoothOut
                    window.animator().setFrameOrigin(NSPoint(x: home.x + offset, y: home.y))
                }
            }
            delay += duration
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.02) { done?() }
    }
}

final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }
}

// A rounded surface that holds one vertical stack of content.
final class CardView: NSView {
    let stack = NSStackView()
    init(spacing: CGFloat = 12, inset: CGFloat = 16) {
        super.init(frame: .zero)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)])
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.radius, yRadius: Theme.radius)
        Theme.card.setFill(); path.fill()
        Theme.hairline.setStroke(); path.lineWidth = 1; path.stroke()
    }
    func add(_ view: NSView, fill: Bool = true) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}

// The navigation column: one row per page, with a highlight that slides to the chosen one.
final class SideBar: NSView {
    private let thumb = ThumbView()
    private var icons: [NSImageView] = [], labels: [NSTextField] = []
    private(set) var selected = 0
    var chosen: ((Int) -> Void)?
    static let rowHeight: CGFloat = 34, gap: CGFloat = 4
    private final class ThumbView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            Theme.thumb.setFill(); path.fill()
            Theme.hairline.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
    init(_ items: [(title: String, symbol: String)]) {
        super.init(frame: .zero)
        addSubview(thumb)
        for item in items {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            let label = Theme.text(item.title, 13.5, .medium, Theme.quiet)
            icons.append(icon); labels.append(label); addSubview(icon); addSubview(label)
        }
        heightAnchor.constraint(equalToConstant: CGFloat(items.count) * (Self.rowHeight + Self.gap) - Self.gap).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    // A press on a row chooses it; it must not also start dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }
    // Icons and labels sit above the bar; a press on either belongs to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    private func slot(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * (Self.rowHeight + Self.gap), width: bounds.width, height: Self.rowHeight)
    }
    private func tint() {
        for index in labels.indices {
            let color = index == selected ? Theme.ink : Theme.quiet
            labels[index].textColor = color; icons[index].contentTintColor = color
        }
    }
    override func layout() {
        super.layout()
        // The first position is set with no animation, so the highlight does not fly in from a corner.
        thumb.frame = slot(selected)
        for index in labels.indices {
            let row = slot(index), height = labels[index].intrinsicContentSize.height
            icons[index].frame = NSRect(x: 12, y: row.midY - 10, width: 20, height: 20)
            labels[index].frame = NSRect(x: 40, y: row.midY - height / 2, width: row.width - 48, height: height)
        }
        tint()
    }
    func select(_ index: Int, animated: Bool = true) {
        guard index != selected, labels.indices.contains(index) else { return }
        selected = index; tint()
        if animated && bounds.width > 0 { Theme.animate(Theme.fast) { thumb.animator().frame = slot(index) } } else { needsLayout = true }
        chosen?(index)
    }
    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        select(min(labels.count - 1, max(0, Int(y / (Self.rowHeight + Self.gap)))))
    }
}

// The strip the navigation sits on: a shade apart from the content, with a hairline between them.
final class SidePanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.track.setFill(); bounds.fill()
        Theme.hairline.setFill(); NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

// A key as printed on the keyboard, for showing the shortcut.
final class Keycap: NSView {
    private let symbol: String
    init(_ symbol: String) { self.symbol = symbol; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.card.setFill(); path.fill()
        Theme.hairline.setStroke(); path.lineWidth = 1; path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Theme.ink]
        let size = (symbol as NSString).size(withAttributes: attributes)
        (symbol as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

// The app's state in one or two words, with a coloured dot.
final class StatusChip: NSView {
    private var text = "", color = Theme.faint
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    func show(_ text: String, _ color: NSColor) {
        guard text != self.text || color != self.color else { return }
        self.text = text; self.color = color
        // The words change with the library's text swap; the chip may also change width.
        Motion.swap(self) { [weak self] in self?.invalidateIntrinsicContentSize(); self?.needsDisplay = true }
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 34, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Theme.quiet]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: 23, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

// An on/off switch drawn here, because the system one turns grey whenever its window is not the key
// window, and this window deliberately never takes the keyboard from the app being dictated into.
final class Toggle: NSView {
    var state: NSControl.StateValue = .off { didSet { if state != oldValue { slide() } } }
    weak var target: AnyObject?
    var action: Selector?
    private var position: CGFloat = 0
    private var timer: Timer?
    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 24) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }
    private func press() {
        state = state == .on ? .off : .on
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
    // What the system switch gave VoiceOver for free: it is announced as a switch with a value and can be pressed.
    var name = "" { didSet { setAccessibilityLabel(name) } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { press(); return true }
    private func slide() {
        let goal: CGFloat = state == .on ? 1 : 0
        timer?.invalidate(); timer = nil
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { position = goal; needsDisplay = true; return }
        let from = position, began = ProcessInfo.processInfo.systemUptime
        let step = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // The library's toggle: 350 ms on the bounce curve, so the knob overshoots a touch and settles.
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.35)
            self.position = from + (goal - from) * Motion.bounce(CGFloat(progress)); self.needsDisplay = true
            if progress >= 1 { timer.invalidate(); self.timer = nil }
        }
        RunLoop.main.add(step, forMode: .common); timer = step
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.track.setFill(); track.fill()
        NSColor.controlAccentColor.withAlphaComponent(min(1, max(0, position))).setFill(); track.fill()
        if position < 0.5 { Theme.hairline.setStroke(); track.lineWidth = 1; track.stroke() }
        let size = bounds.height - 4
        // The colour follows the clamped position; the knob itself may travel a point past either end.
        let knob = NSRect(x: 2 + position * (bounds.width - size - 4), y: 2, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.25); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// One settings line: a title, a quieter explanation, and a control at the right edge.
func settingRow(_ title: String, _ note: String, control: NSView) -> NSView {
    (control as? Toggle)?.name = title
    let titles = NSStackView(views: [Theme.text(title, 13, .medium), Theme.text(note, 11.5, .regular, Theme.quiet, wraps: true)])
    titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
    // The spacer takes the slack, so every control sits on the same right edge.
    let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [titles, spacer, control])
    row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
    titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    return row
}
func hairline() -> NSView {
    let line = NSBox(); line.boxType = .custom; line.borderWidth = 0; line.fillColor = Theme.hairline
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}
