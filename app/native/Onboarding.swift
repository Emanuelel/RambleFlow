import AppKit

// The one large action on a setup screen. Drawn here so it stays in the accent colour: system buttons
// turn grey in a window that never becomes the key window.
final class BigButton: NSView {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var enabled = true { didSet { needsDisplay = true } }
    var pressedAction: (() -> Void)?
    private var down = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 50) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13)
        (enabled ? NSColor.controlAccentColor.withAlphaComponent(down ? 0.8 : 1) : Theme.track).setFill(); shape.fill()
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 15.5, weight: .semibold), .foregroundColor: enabled ? NSColor.white : Theme.faint])
        text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
    }
    override func mouseDown(with event: NSEvent) { down = enabled }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        if enabled && inside { pressedAction?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; pressedAction?(); return true }
}

// First-run setup, laid over the whole window. One picture, a few words and one large button per screen:
// microphone, Accessibility, one practice dictation, done.
final class OnboardingView: NSView {
    var allowMicrophone: (() -> Void)?
    var openAccessibility: (() -> Void)?
    var recordPractice: (() -> Void)?
    var reloadModels: (() -> Void)?
    var cancelPractice: (() -> Void)?
    var finished: (() -> Void)?
    static let steps = 4, practiceStep = 2
    private(set) var step = 0
    // True while the practice screen is showing, so a dictation stays inside this window.
    // A closed or minimised window is not practising: dictation must go back to working normally.
    var practising: Bool { step == Self.practiceStep && !isHidden && window?.isVisible == true && window?.isMiniaturized == false }

    private let hero = HeroView()
    private let headline = Theme.text("", 30, .semibold)
    private let line = Theme.text("", 15, .regular, Theme.quiet)
    private let heard = Theme.text("", 17, .medium, Theme.ink, wraps: true)
    private let button = BigButton()
    private let second = NSButton(title: "", target: nil, action: nil)
    private let tips = NSStackView()
    private let dots = DotsView()
    // First-run download progress: the full card on the practice screen, a slim line under the permission screens.
    private let download = DownloadView(), strip = DownloadView(compact: true)
    private let shortcut: String
    private var microphone = false, microphoneAsked = false, accessibility = false, practised = false, recording = false
    private var modelsReady = false, modelsFailed = false

    private final class DotsView: NSView {
        var current = 0 { didSet { needsDisplay = true } }
        override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(OnboardingView.steps) * 14 - 6, height: 8) }
        override func draw(_ dirtyRect: NSRect) {
            for index in 0..<OnboardingView.steps {
                (index == current ? NSColor.controlAccentColor : Theme.track).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 14, y: 0, width: 8, height: 8)).fill()
            }
        }
    }

    private let appName: String
    private var opened = false
    init(keycaps: [String], words: String, appName: String) {
        shortcut = words; self.appName = appName
        super.init(frame: .zero)
        hero.keys = keycaps; hero.appName = appName
        headline.alignment = .center; line.alignment = .center; heard.alignment = .center
        heard.maximumNumberOfLines = 3
        second.isBordered = false; second.target = self; second.action = #selector(tapSecond)
        button.pressedAction = { [weak self] in self?.tapPrimary() }
        // Three things worth knowing, as pictures with a couple of words each.
        tips.orientation = .horizontal; tips.spacing = 34; tips.alignment = .top
        for (symbol, label) in [("hand.tap", "Double-tap \(words)\nfor hands-free"), ("escape", "Esc\ncancels"), ("doc.on.clipboard", "⌃⌘V pastes\nthe last one")] {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
            icon.contentTintColor = .controlAccentColor
            let text = Theme.text(label, 12.5, .medium, Theme.quiet, wraps: true); text.alignment = .center
            let item = NSStackView(views: [icon, text]); item.orientation = .vertical; item.spacing = 8; item.alignment = .centerX
            tips.addArrangedSubview(item)
        }
        let column = NSStackView(views: [hero, headline, line, heard, download, tips, button, second])
        self.column = column
        column.orientation = .vertical; column.alignment = .centerX; column.spacing = 14
        column.setCustomSpacing(8, after: headline); column.setCustomSpacing(26, after: line); column.setCustomSpacing(26, after: heard); column.setCustomSpacing(26, after: download); column.setCustomSpacing(28, after: tips)
        for view in [column, dots, strip] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor), column.topAnchor.constraint(equalTo: topAnchor, constant: 64),
            column.widthAnchor.constraint(equalToConstant: 560), heard.widthAnchor.constraint(equalToConstant: 520), line.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            dots.centerXAnchor.constraint(equalTo: centerXAnchor), dots.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34),
            strip.centerXAnchor.constraint(equalTo: centerXAnchor), strip.bottomAnchor.constraint(equalTo: dots.topAnchor, constant: -22)])
        show(0, animated: false)
    }
    private var column: NSView!
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }
    // The setup covers the window: clicks must not reach the pages underneath.
    override func mouseDown(with event: NSEvent) {}

    func show(_ index: Int, animated: Bool = true) {
        step = max(0, min(Self.steps - 1, index))
        dots.current = step
        guard animated else { render(); return }
        Motion.swap(column) { [weak self] in self?.render() }
        // Finishing setup is the one moment here that earns confetti: it is fired across the window and some settles on the button.
        if step == Self.steps - 1 && !celebrated {
            celebrated = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.step == Self.steps - 1, self.window?.isVisible == true else { return }
                self.layoutSubtreeIfNeeded()
                let action = self.convert(self.button.bounds, from: self.button)
                ConfettiView.celebrate(over: self, ledge: (action.maxY, action.minX, action.maxX))
            }
        }
    }
    private var celebrated = false
    private func link(_ title: String) {
        second.isHidden = title.isEmpty
        second.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.quiet])
    }
    private func render() {
        hero.recording = recording
        heard.isHidden = true; tips.isHidden = true; button.enabled = true
        let fetching = !modelsReady && !modelsFailed && !download.setup.parts.isEmpty
        download.isHidden = !(step == Self.practiceStep && fetching && !practised && !recording)
        strip.isHidden = !(step < Self.practiceStep && fetching)
        switch step {
        case 0:
            hero.scene = .microphone; headline.stringValue = "Let it hear you"
            let blocked = microphoneAsked && !microphone
            line.stringValue = blocked ? "The microphone is blocked. Allow it in System Settings." : "Audio never leaves this Mac."
            button.title = blocked ? "Open System Settings" : "Allow microphone"; link("")
        case 1:
            hero.scene = .accessibility; headline.stringValue = "Let it type for you"
            // The button opens that exact list; the picture above shows the one switch to flip.
            line.stringValue = opened ? "Find \(appName) in the list and switch it on." : "One switch, in System Settings."
            button.title = "Open Accessibility settings"; link("Later")
        case 2:
            hero.scene = .keys; headline.stringValue = "Hold, speak, release"
            heard.isHidden = heard.stringValue.isEmpty
            // One button that always does the next useful thing, and a Skip that is never taken away.
            if recording { line.stringValue = "Listening…"; button.title = "Stop" }
            else if practised { line.stringValue = "That is all there is to it."; button.title = "Continue" }
            else if modelsFailed { line.stringValue = "The speech models did not load."; button.title = "Try again" }
            else if !modelsReady {
                line.stringValue = download.setup.downloading ? "This happens once. Then everything runs offline." : "Getting the speech models ready…"
                button.title = "One moment"; button.enabled = false
            }
            else {
                // Without Accessibility the shortcut cannot be seen yet, so the button is the way in.
                line.stringValue = accessibility ? "Hold \(shortcut) to speak. Double-tap \(shortcut) for hands-free." : "Click the button and say a sentence."
                button.title = "Record with a click"
            }
            link(practised ? "" : "Skip")
        default:
            hero.scene = .done; headline.stringValue = "You are ready"
            line.stringValue = "Dictate anywhere you can type."
            tips.isHidden = false; button.title = "Start dictating"; link("")
        }
    }
    func update(microphone: Bool, microphoneAsked: Bool, accessibility: Bool, modelsReady: Bool = true, modelsFailed: Bool = false) {
        let changed = microphone != self.microphone || microphoneAsked != self.microphoneAsked || accessibility != self.accessibility || modelsReady != self.modelsReady || modelsFailed != self.modelsFailed
        self.microphone = microphone; self.microphoneAsked = microphoneAsked; self.accessibility = accessibility
        self.modelsReady = modelsReady; self.modelsFailed = modelsFailed
        // A permission that has been given moves the setup on by itself.
        if step == 0 && microphone { show(accessibility ? 2 : 1) }
        else if step == 1 && accessibility { show(2) }
        else if changed { render() }
    }
    func showModels(_ setup: ModelSetup) {
        let shown = !download.setup.parts.isEmpty, downloading = download.setup.downloading
        download.setup = setup; strip.setup = setup
        // Text and visibility only change when the kind of wait changes, not on every byte count.
        if shown != !setup.parts.isEmpty || downloading != setup.downloading { render() }
    }
    // For previews: stop the shine at one moment and show every value as arrived.
    func freezeProgress(at time: TimeInterval) { download.frozen = time; strip.frozen = time }
    // Text heard so far, or the final result. `problem` explains an empty or failed attempt.
    func showPractice(_ text: String, final: Bool, problem: String? = nil) {
        recording = !final
        if !text.isEmpty { heard.stringValue = "“\(text)”"; heard.textColor = Theme.ink }
        if final {
            practised = practised || !text.isEmpty
            if text.isEmpty { heard.stringValue = problem ?? "Nothing was heard. Hold \(shortcut) a moment before speaking."; heard.textColor = Theme.busy }
        }
        if step == Self.practiceStep { render() }
    }
    // The live microphone level, for the bars on the practice screen.
    func push(level: Float) { hero.level = CGFloat(level) }
    func practiceStarted() { recording = true; if step == Self.practiceStep { render() } }
    // Called whenever a session ends for any reason, so a cancel or an error cannot leave the screen "listening".
    func practiceEnded() { guard recording else { return }; recording = false; if step == Self.practiceStep { render() } }
    private func tapPrimary() {
        // A press while the screen is still changing belongs to the screen that is leaving.
        guard !Motion.swapping(column) else { return }
        switch step {
        case 0: allowMicrophone?()
        case 1: opened = true; openAccessibility?(); render()
        case 2:
            if recording { recordPractice?() }
            else if practised { show(3) }
            else if modelsFailed { reloadModels?() }
            else { recordPractice?() }
        default: finished?()
        }
    }
    @objc private func tapSecond() {
        guard !Motion.swapping(column) else { return }
        switch step {
        case 1: show(2)
        // Skipping must not leave a practice recording running behind the next screen.
        case 2: if recording { cancelPractice?() }; show(3)
        default: break
        }
    }
}
