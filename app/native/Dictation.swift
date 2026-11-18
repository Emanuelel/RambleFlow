import AppKit
import AVFoundation
import CoreAudio
import ApplicationServices
import Carbon
import AudioToolbox

struct LaunchConfig {
    let projectRoot: String; let nodePath: String; let configPath: String
    // A self-contained build carries its own Node and worker under Resources/runtime and keeps the user's
    // settings, statistics and downloaded models in Application Support, so nothing depends on a project folder.
    static func bundled(resources: URL, support: URL, fastRuntime: Bool = false) throws -> LaunchConfig {
        let runtime = resources.appendingPathComponent("runtime")
        let config = support.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: config.path) {
            // With no model override, the worker uses the signed bundle's refiner.
            var first: [String: Any] = ["version": 1, "cacheDirectory": support.appendingPathComponent("models").path, "vocabulary": [String](), "autoInsert": true]
            if fastRuntime {
                let timed = support.appendingPathComponent("timed-runtime")
                let python = timed.appendingPathComponent("python/bin/python").path
                let server = timed.appendingPathComponent("Phonon.app/Contents/Resources/sidecar/asr_server.py").path
                // The installer brings the recognizer; its speech model downloads on first launch, into the
                // models folder so an upgrade that replaces the runtime keeps it. The worker uses the same folder name.
                let model = support.appendingPathComponent("models/parakeet-tdt-0.6b-v2-mlx-8ae1553").path
                guard FileManager.default.isExecutableFile(atPath: python),
                      FileManager.default.isReadableFile(atPath: server) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: timed.path, NSLocalizedDescriptionKey: "The timed speech runtime is missing. Reinstall RambleFlow with Homebrew."])
                }
                first["timedAsr"] = ["python": python, "server": server, "model": model, "formattingReuse": true] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: first, options: [.prettyPrinted, .sortedKeys]).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        return LaunchConfig(projectRoot: runtime.path, nodePath: runtime.appendingPathComponent("node").path, configPath: config.path)
    }
    // Reads Resources/launch.json: either the three paths of a development build, or {"bundled": true}.
    static func load(resources: URL) throws -> LaunchConfig {
        let data = try Data(contentsOf: resources.appendingPathComponent("launch.json"))
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        if values["bundled"] as? Bool == true {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RambleFlow")
            return try bundled(resources: resources, support: support, fastRuntime: values["fastRuntime"] as? Bool == true)
        }
        guard let root = values["projectRoot"] as? String, let node = values["nodePath"] as? String, let config = values["configPath"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        return LaunchConfig(projectRoot: root, nodePath: node, configPath: config)
    }
}
struct FocusTarget {
    let pid: pid_t
    let bundle: String
    let element: AXUIElement
    let value: String?
    let selection: CFTypeRef?
}
func replayTargetAllowed(expectedBundle: String?, directTargetBundle: String?) -> Bool {
    guard let expectedBundle else { return true }
    return !expectedBundle.isEmpty && directTargetBundle == expectedBundle
}
func unchangedFocus(originalPID: pid_t, currentPID: pid_t?, sameElement: Bool, secure: Bool, sameValue: Bool, sameSelection: Bool) -> Bool {
    currentPID == originalPID && sameElement && !secure && sameValue && sameSelection
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func focusedElement(_ pid: pid_t) -> AXUIElement? {
    guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func isSecure(_ element: AXUIElement) -> Bool {
    (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
}
func captureTarget() -> FocusTarget? {
    guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
          let element = focusedElement(app.processIdentifier), !isSecure(element) else { return nil }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
    return FocusTarget(pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "", element: element,
                       value: attribute(element, kAXValueAttribute) as? String,
                       selection: attribute(element, kAXSelectedTextRangeAttribute))
}
func targetMismatch(_ target: FocusTarget) -> String? {
    guard AXIsProcessTrusted() else { return "accessibility unavailable" }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return "frontmost app changed" }
    guard let element = focusedElement(target.pid) else { return "focused field unavailable" }
    guard CFEqual(element, target.element) else { return "focused field changed" }
    guard !isSecure(element) else { return "secure field" }
    if let value = target.value, (attribute(element, kAXValueAttribute) as? String) != value {
        return "field text changed"
    }
    if let selection = target.selection {
        guard let current = attribute(element, kAXSelectedTextRangeAttribute), CFEqual(selection, current) else {
            return "selection changed"
        }
    }
    return nil
}
// Chromium and WebKit mark the elements of a web page with these attributes; native fields have neither.
func isWebContent(_ element: AXUIElement) -> Bool {
    attribute(element, "AXDOMClassList") != nil || attribute(element, "AXDOMIdentifier") != nil
}
func selectionLocation(_ selection: CFTypeRef?) -> Int? {
    guard let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue(unsafeBitCast(selection, to: AXValue.self), .cfRange, &range) ? range.location : nil
}
func isTerminal(_ bundle: String) -> Bool {
    ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "rio"].contains(where: bundle.lowercased().contains)
}
// Apps with a built-in terminal that expose no text field. A pasted line break can run a command there.
func isCodeEditor(_ bundle: String) -> Bool {
    ["vscode", "vscodium", "cursor", "todesktop", "windsurf", "jetbrains", "zed", "emacs", "sublime", "xcode", "nova", "termius", "tabby"].contains(where: bundle.lowercased().contains)
}
func writingMode(_ bundle: String) -> String {
    let id = bundle.lowercased()
    if ["terminal", "iterm", "warp", "code", "codex", "chatgpt", "claude", "gemini", "xcode", "cursor"].contains(where: id.contains) { return "prompt" }
    if ["mail", "outlook", "superhuman", "slack", "teams", "googlechat"].contains(where: id.contains) { return "formal" }
    if ["messages", "ichat", "whatsapp", "telegram", "discord", "twitter"].contains(where: id.contains) { return "casual" }
    return "minimal"
}

// Audio captured before the recording session exists. It is held, then sent first, so speech that
// starts with the key press is kept. Pure logic, so the self-test can drive it.
struct EarlyAudio {
    // About 10 seconds of 16 kHz mono 16-bit audio. Far more than a session takes to start.
    static let limit = 320_000
    private(set) var held: [Data] = [], heldBytes = 0
    private(set) var forwarding = false
    // Returns what should be sent now: nothing while holding.
    mutating func add(_ chunk: Data) -> [Data] {
        if forwarding { return [chunk] }
        held.append(chunk); heldBytes += chunk.count
        while heldBytes > Self.limit, let first = held.first { held.removeFirst(); heldBytes -= first.count }
        return []
    }
    // Starts sending, beginning with everything held so far.
    mutating func forward() -> [Data] {
        forwarding = true
        defer { held = []; heldBytes = 0 }
        return held
    }
}

// The input macOS has selected, as Core Audio names it.
func defaultInputDevice() -> AudioDeviceID? {
    var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr ? device : nil
}

final class Microphone {
    // One engine is kept between recordings, because building a new one for every recording is slow.
    // It is replaced when the audio setup changes, for example when another microphone is selected.
    private var engine: AVAudioEngine?, builtFor: AudioDeviceID?
    private var running = false
    private let queue = DispatchQueue(label: "qvac.dictation.audio")
    // Touched only on the audio queue.
    private var early = EarlyAudio(), deliver: ((Data) -> Void)?, accepting = false
    // Each open counts up, so audio still in flight from an earlier press cannot join this one.
    private var generation = 0
    private var changed: NSObjectProtocol?
    var onLevel: ((Float) -> Void)?
    private(set) var route = ""
    var isOpen: Bool { running }
    deinit { if let changed { NotificationCenter.default.removeObserver(changed) } }
    // Always the input macOS has selected. The app does not choose a microphone for the user.
    // Audio is held until `forward` says where it goes.
    func open(requireLoopback: Bool = false) throws {
        guard !running else { return }
        // A kept engine stays bound to the microphone it was built for, so a newly selected one needs a new engine.
        let device = defaultInputDevice()
        if device != builtFor { self.engine = nil }
        let engine = self.engine ?? makeEngine()
        builtFor = device
        let input = engine.inputNode
        if requireLoopback {
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout.size(ofValue: name))
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard let loopbackDevice = device,
                  loopbackDevice != kAudioObjectUnknown,
                  AudioObjectGetPropertyData(loopbackDevice, &property, 0, nil, &nameSize, &name) == noErr,
                  name?.takeRetainedValue() as String? == "BlackHole 2ch" else {
                throw NSError(domain: "Microphone", code: 2, userInfo: [NSLocalizedDescriptionKey: "Benchmark PCM capture requires BlackHole 2ch."])
            }
            try input.auAudioUnit.setDeviceID(loopbackDevice)
        }
        let source = input.outputFormat(forBus: 0)
        route = "hardware \(Int(input.inputFormat(forBus: 0).sampleRate))Hz x\(input.inputFormat(forBus: 0).channelCount), node \(Int(source.sampleRate))Hz x\(source.channelCount)"
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            self.engine = nil
            throw NSError(domain: "Microphone", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input. Check Sound settings."])
        }
        let current: Int = queue.sync { early = EarlyAudio(); deliver = nil; accepting = true; generation += 1; return generation }
        // 100 ms chunks, the smallest the tap accepts, so the first audio arrives sooner.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(source.sampleRate / 10), format: source) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy before leaving the real-time callback. AVAudioEngine owns its buffer.
            guard let copy = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(from.count, to.count) {
                if let src = from[index].mData, let dst = to[index].mData { memcpy(dst, src, Int(from[index].mDataByteSize)) }
            }
            self.queue.async {
                guard self.accepting, self.generation == current else { return }
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / source.sampleRate)) + 32
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return copy
                }
                if error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                    let count = Int(output.frameLength)
                    let ready = self.early.add(Data(bytes: samples, count: count * 2))
                    if let deliver = self.deliver { ready.forEach(deliver) }
                    if let onLevel = self.onLevel {
                        var sum = 0.0
                        for index in 0..<count { let sample = Double(samples[index]) / 32768; sum += sample * sample }
                        let level = inputLevel(rms: (sum / Double(count)).squareRoot())
                        DispatchQueue.main.async { onLevel(level) }
                    }
                }
            }
        }
        engine.prepare()
        do { try engine.start(); self.engine = engine; running = true }
        catch { input.removeTap(onBus: 0); self.engine = nil; builtFor = nil; queue.sync { accepting = false }; throw error }
    }
    // Sends everything held so far, then the live audio as it arrives.
    func forward(_ deliver: @escaping (Data) -> Void) {
        queue.sync { self.deliver = deliver; self.early.forward().forEach(deliver) }
    }
    func stop() {
        if running { engine?.inputNode.removeTap(onBus: 0); engine?.stop() }
        running = false
        queue.sync { accepting = false; deliver = nil; early = EarlyAudio() }
    }
    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        if let changed { NotificationCenter.default.removeObserver(changed) }
        // The engine stops itself when the input changes. Drop it so the next recording builds a fresh one.
        changed = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            self.stop(); self.engine = nil; self.builtFor = nil
        }
        return engine
    }
}

final class Worker {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let writeQueue = DispatchQueue(label: "qvac.dictation.ipc")
    var received: (([String: Any]) -> Void)?
    var exited: ((String) -> Void)?
    func launch(_ launch: LaunchConfig) throws {
        let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: launch.nodePath)
        process.arguments = [launch.projectRoot + "/app/worker.mjs", launch.configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: launch.projectRoot)
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = errors
        // Native dependency diagnostics can contain user paths. Keep them in memory only.
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.buffer.append(data)
                if self.buffer.count > 1_000_000 { self.buffer.removeAll(); self.exited?("Worker sent an oversized response."); self.stop(); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: newline)
                    self.buffer.removeSubrange(...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.received?(message) }
                }
            }
        }
        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.exited?("Local model worker stopped (code \(proc.terminationStatus)). Reload after checking the model settings.") }
        }
        try process.run()
        self.process = process; input = stdinPipe.fileHandleForWriting
    }
    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        writeQueue.async { [weak self] in
            do { try self?.input?.write(contentsOf: data + Data([10])) }
            catch { DispatchQueue.main.async { self?.exited?("Connection to the local model worker closed.") } }
        }
    }
    // The SDK keeps the models in a helper process below the worker. Killing only the worker would
    // orphan that helper with the models still in memory, so its children go first.
    private static func killTree(_ pid: pid_t) {
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); children.arguments = ["-9", "-P", "\(pid)"]
        if (try? children.run()) != nil { children.waitUntilExit() }
        kill(pid, SIGKILL)
    }
    // For a worker whose state is already broken: asking it to shut down politely can hang.
    func abandon() {
        guard let owned = process, owned.isRunning else { return }
        Self.killTree(owned.processIdentifier)
    }
    func stop() {
        send(["type": "shutdown"])
        let owned = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if owned?.isRunning == true { owned?.terminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if let owned, owned.isRunning { Self.killTree(owned.processIdentifier) } }
    }
}

final class DictationApp: NSObject, NSApplicationDelegate {
    private let launch: LaunchConfig
    private let microphone = Microphone()
    private var worker = Worker()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var pill: Pill?
    private var pillItems: [NSMenuItem] = []
    private let status = NSTextField(labelWithString: "Loading local models")
    private let targetLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let vocabulary = VocabularyRows()
    private let modePicker = NSPopUpButton()
    private let insert = NSButton(title: "Insert", target: nil, action: nil)
    private let undo = NSButton(title: "Undo cleanup", target: nil, action: nil)
    private let autoInsertBox = Toggle()
    private let cleanupBox = Toggle()
    private let soundBox = Toggle(), pillBox = Toggle()
    private static let pageNames = [("Welcome back", "chart.bar.xaxis"), ("Review", "text.bubble"), ("Vocabulary", "character.book.closed"), ("Settings", "gearshape")]
    private let tabs = SideBar(pageNames.map { (title: $0.0, symbol: $0.1) })
    private let pageTitle = Theme.text("Welcome back", 22, .semibold)
    private static let windowWidth: CGFloat = 948
    private var pages: [NSView] = []
    private let chip = StatusChip()
    private let insights = InsightsView()
    private var sessionMode = "minimal"
    private var sessionApp: String?
    private let microphoneState = Theme.text("", 11.5, .regular, Theme.quiet), accessibilityState = Theme.text("", 11.5, .regular, Theme.quiet)
    private let keys = NSStackView()
    private var pageHeight: NSLayoutConstraint?
    // First-run setup, shown over the window until it has been completed once.
    private var onboarding: OnboardingView?
    private var wasTrusted = AXIsProcessTrusted()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    // Set when the models could not load or the worker stopped, until a reload begins.
    private var failed = false
    // Sizes and byte counts while the models are fetched or read, for the progress shown during setup.
    private var models = ModelSetup()
    private var shownDay = ""
    private let viewToggle = NSSegmentedControl(labels: ["Cleaned", "Raw"], trackingMode: .selectOne, target: nil, action: nil)
    private var autoInsertItem: NSMenuItem?, cleanupItem: NSMenuItem?
    // The app in front when no text field could be identified; text is pasted at its cursor.
    private var frontApp: (pid: pid_t, bundle: String, window: AXUIElement?)?
    private var showingRaw = false
    // One snapshot of the user's clipboard is kept until it has been put back, however many pastes happen meanwhile.
    private var clipboardSnapshot: [NSPasteboardItem]?
    private var clipboardRestore: DispatchWorkItem?
    private var raw = ""
    private var cleanupOn = UserDefaults.standard.object(forKey: "cleanup") as? Bool ?? true
    private var lastInsertion: (element: AXUIElement, location: Int, inserted: String, raw: String)?
    private let record = NSButton(title: "Try in scratchpad", target: nil, action: nil)
    private var pasteHotKey: EventHotKeyRef?, escapeHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var chord = parseChord(nil)
    private var tracker = ChordTracker()
    private var flagMonitors: [Any] = [], keyMonitors: [Any] = []
    private var armTimer: Timer?
    // When the shortcut went down and when the microphone opened, for the debug log.
    private var pressedAt: TimeInterval?, openedAt: TimeInterval?
    // Closes a microphone opened for a session the worker never acknowledged.
    private var microphoneGuard: Timer?
    private var ready = false, held = false, latched = false, recording = false, processing = false
    private var pendingStop = false
    // A cancelled session stays active in the worker until it acknowledges.
    private var pendingCancel: String?
    private var lastText = ""
    // Counts for the home screen, kept beside the private settings. Never any text.
    private lazy var statsPath = (launch.configPath as NSString).deletingLastPathComponent + "/stats.json"
    private(set) lazy var stats = Stats.load(from: statsPath)
    private var recordingStarted: Date?, recordedSeconds = 0.0
    // Opt-in event trace for diagnosing shortcuts. It records states and messages, never dictated text.
    private lazy var debugLog: FileHandle? = {
        guard CommandLine.arguments.contains("--debug") else { return nil }
        let path = (launch.configPath as NSString).deletingLastPathComponent + "/debug.log"
        // Appended, not replaced: a restart must not erase the evidence of what just went wrong.
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()
    private var debugSeen = ""
    private func debug(_ text: @autoclosure () -> String) {
        guard let debugLog else { return }
        debugLog.write(Data(String(format: "%.3f %@\n", Date().timeIntervalSince1970, text()).utf8))
    }
    private var id: String?
    private var target: FocusTarget?
    private var result = ""
    private var timeout: Timer?
    private var captureTimer: Timer?
    private var autoInsert = true
    private var scratch = false
    private var config: [String: Any] = [:]
    init(_ launch: LaunchConfig) { self.launch = launch }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makePanel(); makeMenu(); loadSettings(); registerShortcuts(); makePill(); startWorker()
        if !UserDefaults.standard.bool(forKey: "onboarded") && !CommandLine.arguments.contains("--ui-smoke") { makeOnboarding() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshChrome() }
        if debugLog != nil {
            debug("launched trusted=\(AXIsProcessTrusted()) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) chord=\(chord.words)")
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                let shown = "status=\(self.status.stringValue) | target=\(self.targetLabel.stringValue) | menu=\(self.statusItem.button?.toolTip ?? "")"
                if shown != self.debugSeen { self.debugSeen = shown; self.debug(shown) }
            }
        }
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--ui-smoke") {
            Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { _ in fputs("UI smoke timed out.\n", stderr); NSApp.terminate(nil) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
        return false
    }

    private func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: DictationApp.windowWidth, height: 640), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "RambleFlow"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.center()
        // Non-activating, so the field being dictated into keeps the keyboard while this window is used.
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = BackgroundView(); panel.contentView = root
        // Navigation down the left edge: the pages, then the shortcut as a standing reminder.
        let side = SidePanelView(); side.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side)
        let hint = Theme.text("Hold to dictate.\nDouble-tap for hands-free.", 11.5, .regular, Theme.quiet, wraps: true)
        keys.orientation = .horizontal; keys.spacing = 6; keys.alignment = .centerY
        let name = NSStackView()
        name.orientation = .horizontal; name.alignment = .centerY; name.spacing = 7
        if let url = Bundle.main.url(forResource: "RambleFlowWaveform", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            let logo = NSImageView(image: image)
            logo.imageScaling = .scaleProportionallyUpOrDown
            logo.contentTintColor = .labelColor
            logo.setAccessibilityElement(false)
            logo.widthAnchor.constraint(equalToConstant: 26).isActive = true
            logo.heightAnchor.constraint(equalToConstant: 16).isActive = true
            name.addArrangedSubview(logo)
        }
        name.addArrangedSubview(Theme.text("RambleFlow", 17, .semibold))
        for view in [name, tabs, keys, hint] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; side.addSubview(view) }
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor), side.bottomAnchor.constraint(equalTo: root.bottomAnchor), side.widthAnchor.constraint(equalToConstant: 188),
            name.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 24), name.topAnchor.constraint(equalTo: side.topAnchor, constant: 46),
            tabs.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 12), tabs.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -12), tabs.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 24), hint.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -16), hint.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -22),
            keys.leadingAnchor.constraint(equalTo: hint.leadingAnchor), keys.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            keys.topAnchor.constraint(greaterThanOrEqualTo: tabs.bottomAnchor, constant: 24)])
        let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: root.topAnchor, constant: 40), column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)])
        func fill(_ view: NSView) { column.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing; return row
        }
        func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view }
        func field(_ text: NSTextView, height: CGFloat, size: CGFloat) -> NSView {
            text.isRichText = false; text.font = .systemFont(ofSize: size); text.drawsBackground = false; text.textContainerInset = NSSize(width: 6, height: 8)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.documentView = text
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10; scroll.layer?.masksToBounds = true
            let box = NSBox(); box.boxType = .custom; box.borderWidth = 0; box.cornerRadius = 10; box.fillColor = Theme.track; box.contentViewMargins = .zero
            box.contentView = scroll
            box.heightAnchor.constraint(equalToConstant: height).isActive = true
            return box
        }

        fill(row([pageTitle, spacer(), chip]))
        status.font = .systemFont(ofSize: 12.5); status.textColor = Theme.quiet; status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2
        // Room for two lines is always reserved, so a longer message never moves what is below it.
        status.heightAnchor.constraint(equalToConstant: 34).isActive = true
        // A long message must wrap inside the window, never widen it.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fill(status)

        // Home: the numbers.
        let dashboard = NSStackView(); dashboard.orientation = .vertical; dashboard.alignment = .leading; dashboard.spacing = 14
        dashboard.addArrangedSubview(insights); insights.widthAnchor.constraint(equalTo: dashboard.widthAnchor).isActive = true

        // Review: the last dictation, for reading, correcting and inserting by hand.
        let home = NSStackView(); home.orientation = .vertical; home.alignment = .leading; home.spacing = 14
        let last = CardView()
        viewToggle.target = self; viewToggle.action = #selector(switchView); viewToggle.selectedSegment = 0; viewToggle.controlSize = .small
        last.add(row([Theme.text("Last dictation", 13, .semibold), spacer(), viewToggle]))
        last.add(field(preview, height: 150, size: 14.5))
        targetLabel.font = .systemFont(ofSize: 11.5); targetLabel.textColor = Theme.quiet; targetLabel.maximumNumberOfLines = 2; targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        last.add(targetLabel)
        insert.target = self; insert.action = #selector(insertResult); insert.isEnabled = false; insert.bezelColor = .controlAccentColor
        undo.target = self; undo.action = #selector(undoCleanup); undo.isEnabled = false
        undo.toolTip = "Replaces the text just inserted with what was actually recognized."
        record.target = self; record.action = #selector(toggleScratch)
        record.toolTip = "Records into this window only. Nothing is inserted anywhere else."
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.isEnabled = false
        last.add(row([insert, NSButton(title: "Copy", target: self, action: #selector(copyResult)), undo, spacer(), cancelButton, record]))
        home.addArrangedSubview(last); last.widthAnchor.constraint(equalTo: home.widthAnchor).isActive = true

        // Vocabulary
        let words = NSStackView(); words.orientation = .vertical; words.alignment = .leading; words.spacing = 14
        let terms = CardView()
        terms.add(Theme.text("Names and terms", 13, .semibold))
        terms.add(Theme.text("Add up to 80 names and terms. The cleanup step uses them to spell names, products and jargon the way you do. Saved only on this Mac.", 12, .regular, Theme.quiet, wraps: true))
        terms.add(vocabulary)
        terms.add(row([NSButton(title: "Add entry", target: self, action: #selector(addVocabularyEntry)), NSButton(title: "Save", target: self, action: #selector(saveVocabulary)), spacer()]))
        words.addArrangedSubview(terms); terms.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true

        // Settings
        let settings = NSStackView(); settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 14
        autoInsertBox.target = self; autoInsertBox.action = #selector(toggleAutoInsert)
        cleanupBox.target = self; cleanupBox.action = #selector(toggleCleanup); cleanupBox.state = cleanupOn ? .on : .off
        soundBox.target = self; soundBox.action = #selector(toggleSound); soundBox.state = UserDefaults.standard.object(forKey: "startSound") as? Bool ?? true ? .on : .off
        pillBox.target = self; pillBox.action = #selector(togglePill); pillBox.state = UserDefaults.standard.object(forKey: "pillVisible") as? Bool ?? true ? .on : .off
        modePicker.addItems(withTitles: ["Automatic", "minimal", "casual", "formal", "prompt"])
        let behaviour = CardView(spacing: 12)
        for (index, line) in [
            settingRow("Insert automatically", "Text goes in as soon as it is ready. Off shows it on Review first.", control: autoInsertBox),
            settingRow("Clean up text", "Removes fillers and fixes punctuation with the local model. Off gives your exact words.", control: cleanupBox),
            settingRow("Start sound", "A short sound when recording actually begins.", control: soundBox),
            settingRow("Floating pill", "The small indicator at the bottom of the screen. It still appears while recording.", control: pillBox),
            settingRow("Writing style", "Automatic picks a style from the app you are in.", control: modePicker),
        ].enumerated() {
            if index > 0 { behaviour.add(hairline()) }
            behaviour.add(line)
        }
        settings.addArrangedSubview(behaviour); behaviour.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        let access = CardView(spacing: 12)
        func accessRow(_ title: String, _ state: NSTextField, _ button: NSButton) -> NSView {
            let titles = NSStackView(views: [Theme.text(title, 13, .medium), state]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
            button.controlSize = .small
            return row([titles, spacer(), button])
        }
        access.add(accessRow("Microphone", microphoneState, NSButton(title: "Allow", target: self, action: #selector(requestMicrophone))))
        access.add(hairline())
        access.add(accessRow("Accessibility", accessibilityState, NSButton(title: "Open settings", target: self, action: #selector(requestAccessibility))))
        access.add(hairline())
        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reload)); reloadButton.controlSize = .small
        let fileButton = NSButton(title: "Settings file", target: self, action: #selector(openSettings)); fileButton.controlSize = .small
        let models = NSStackView(views: [Theme.text("Speech models", 13, .medium), Theme.text("Both run on this Mac. Nothing you say leaves it.", 11.5, .regular, Theme.quiet)]); models.orientation = .vertical; models.alignment = .leading; models.spacing = 2
        access.add(row([models, spacer(), fileButton, reloadButton]))
        settings.addArrangedSubview(access); access.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        let note = Theme.text("During normal dictation, audio and text stay in memory. The app saves usage counts for Home, including words, time, and which apps you dictated into. Escape cancels a recording. Control + Command + V pastes the last result. A recording stops after 90 seconds.", 11, .regular, Theme.faint, wraps: true)
        settings.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true

        // The pages share one space; only the chosen one is shown.
        let holder = NSView()
        pages = [dashboard, home, words, settings]
        for (index, page) in pages.enumerated() {
            page.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(page)
            NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: holder.leadingAnchor), page.trailingAnchor.constraint(equalTo: holder.trailingAnchor), page.topAnchor.constraint(equalTo: holder.topAnchor), page.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor)])
            page.isHidden = index != 0
        }
        fill(holder)
        pageHeight = holder.heightAnchor.constraint(equalToConstant: 0); pageHeight?.isActive = true
        tabs.chosen = { [weak self] index in self?.showPage(index) }
        refreshKeys(); refreshStats(animated: false); refreshChrome()
        fitWindow()
    }
    private func makeOnboarding() {
        guard let root = panel.contentView else { return }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
        let setup = OnboardingView(keycaps: chord.keycaps, words: chord.words, appName: name)
        setup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(setup)
        NSLayoutConstraint.activate([setup.leadingAnchor.constraint(equalTo: root.leadingAnchor), setup.trailingAnchor.constraint(equalTo: root.trailingAnchor), setup.topAnchor.constraint(equalTo: root.topAnchor), setup.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        setup.allowMicrophone = { [weak self] in
            // macOS asks only once. After a refusal the switch lives in System Settings.
            if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            else { self?.requestMicrophone() }
        }
        setup.recordPractice = { [weak self] in self?.toggleScratch() }
        setup.openAccessibility = { [weak self] in
            // The system prompt appears only once; opening the list directly always works.
            // This window normally floats above other apps: step aside so it cannot cover the list.
            self?.panel.level = .normal
            self?.requestAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        setup.reloadModels = { [weak self] in self?.reload() }
        setup.cancelPractice = { [weak self] in self?.cancel() }
        // Nothing under the setup is reachable, by pointer, keyboard or VoiceOver, until it is done.
        let covered = root.subviews.filter { $0 !== setup }
        covered.forEach { $0.isHidden = true }
        setup.finished = { [weak self, weak setup] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            covered.forEach { $0.isHidden = false }
            self?.onboarding = nil
            self?.panel.level = .floating
            guard let setup else { return }
            // "Modal close": quicker than an opening, 150 ms.
            NSAnimationContext.runAnimationGroup({ context in context.duration = Theme.quick; context.timingFunction = Theme.smoothOut; setup.animator().alphaValue = 0 }, completionHandler: { setup.removeFromSuperview() })
        }
        setup.showModels(models)
        onboarding = setup
        refreshChrome()
    }
    private func showPage(_ index: Int) {
        // The page area changes with the library's text swap; the title changes with it.
        guard let holder = pages[index].superview else { return }
        Motion.swap(holder) { [weak self] in
            guard let self else { return }
            for (position, page) in self.pages.enumerated() { page.isHidden = position != self.tabs.selected; page.alphaValue = 1 }
            self.pageTitle.stringValue = Self.pageNames[self.tabs.selected].0
        }
    }
    // One size for every page, set once: the tallest page decides it, so choosing a page never moves the window.
    private func fitWindow() {
        guard let root = panel.contentView else { return }
        root.layoutSubtreeIfNeeded()
        pageHeight?.constant = pages.map(\.fittingSize.height).max() ?? 0
        let top = panel.frame.maxY
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.windowWidth, height: root.fittingSize.height)))
        frame.origin = NSPoint(x: panel.frame.minX, y: top - frame.height)
        panel.setFrame(frame, display: true)
    }
    private func refreshKeys() {
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for label in chord.keycaps { keys.addArrangedSubview(Keycap(label)) }
    }
    private func refreshStats(animated: Bool = true) {
        insights.show(stats)
    }
    // Small things that follow state the rest of the code already keeps: the chip and the permission lines.
    private func refreshChrome() {
        if recording { chip.show("Recording", Theme.live) }
        else if processing { chip.show("Working", Theme.busy) }
        else if id != nil { chip.show("Starting", Theme.busy) }
        else if ready { chip.show("Ready", Theme.good) }
        else if failed { chip.show("Stopped", Theme.live) }
        else { chip.show(models.downloading ? "Downloading" : "Loading", Theme.busy) }
        cancelButton.isEnabled = id != nil
        // A shortcut monitor installed before Accessibility was granted may never deliver, so start a fresh one.
        let trusted = AXIsProcessTrusted()
        if trusted && !wasTrusted { installFlagMonitors() }
        wasTrusted = trusted
        if let onboarding {
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            onboarding.update(microphone: microphone == .authorized, microphoneAsked: microphone != .notDetermined, accessibility: AXIsProcessTrusted(), modelsReady: ready, modelsFailed: failed)
        }
        // The rest only matters while the window can be seen.
        guard panel?.isVisible == true else { return }
        let today = Stats.dayKey(Date())
        if today != shownDay { shownDay = today; refreshStats(animated: false) }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneState.stringValue = microphone == .authorized ? "Allowed" : microphone == .notDetermined ? "Not asked yet" : "Blocked in System Settings"
        accessibilityState.stringValue = AXIsProcessTrusted() ? "Allowed" : "Needed for the shortcut and for typing into other apps"
    }
    @objc private func toggleSound() {
        UserDefaults.standard.set(soundBox.state == .on, forKey: "startSound")
    }
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "RambleFlow"
        statusItem.button?.setAccessibilityLabel("RambleFlow")
        if let url = Bundle.main.url(forResource: "RambleFlowMenu", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 12)
            icon.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "RambleFlow"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Dictation", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "").target = self
        autoInsertItem = menu.addItem(withTitle: "Insert automatically", action: #selector(toggleAutoInsert), keyEquivalent: ""); autoInsertItem?.target = self
        cleanupItem = menu.addItem(withTitle: "Clean up text", action: #selector(toggleCleanup), keyEquivalent: ""); cleanupItem?.target = self
        cleanupItem?.state = cleanupOn ? .on : .off
        pillItems.append(menu.addItem(withTitle: "Show floating pill", action: #selector(togglePill), keyEquivalent: ""))
        menu.addItem(withTitle: "Open model settings", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }
    private func makePill() {
        let pill = Pill(defaults: .standard, hint: "Hold \(chord.symbols) to dictate")
        pill.view.clicked = { [weak self] zone in
            guard let self else { return }
            switch pill.state {
            // A result still awaiting review must not be wiped by a stray click.
            case .idle: if self.insert.isEnabled { self.showReview() } else if self.begin(scratch: false, latched: true) { self.tracker.latchedElsewhere() }
            case .recording: if zone == .cancel { self.cancel() } else if zone == .stop { self.end() }
            case .notice: self.showReview()
            case .processing: if zone == .cancel { self.cancel() }
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Dictation", action: #selector(show), keyEquivalent: "").target = self
        pillItems.append(menu.addItem(withTitle: "Show floating pill", action: #selector(togglePill), keyEquivalent: ""))
        menu.addItem(withTitle: "Move pill back to bottom centre", action: #selector(resetPill), keyEquivalent: "").target = self
        pill.setMenu(menu); self.pill = pill
        for item in pillItems { item.target = self; item.state = pill.showsWhenIdle ? .on : .off }
    }
    @objc private func resetPill() { pill?.resetPosition() }
    @objc private func togglePill() {
        guard let pill else { return }
        pill.showsWhenIdle.toggle()
        for item in pillItems { item.state = pill.showsWhenIdle ? .on : .off }
        pillBox.state = pill.showsWhenIdle ? .on : .off
    }
    private func registerShortcuts() {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<DictationApp>.fromOpaque(context).takeUnretainedValue()
            if key.id == 2 { app.pasteLast() } else if key.id == 3 { app.cancel() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let code = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | controlKey), EventHotKeyID(signature: 0x51564143, id: 2), GetApplicationEventTarget(), 0, &pasteHotKey)
        if code != noErr { status.stringValue = "Control + Command + V is already in use. Use the menu to paste the last transcript." }
        // Carbon hot keys need a non-modifier key, so the chord is observed as modifier changes.
        // The global monitor only delivers once Accessibility is enabled.
        installFlagMonitors()
    }
    private func installFlagMonitors() {
        flagMonitors.forEach(NSEvent.removeMonitor); flagMonitors = []
        let changed: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.debug("flags raw=\(event.modifierFlags.rawValue) key=\(event.keyCode)")
            self.chordEvent(self.chordInput(event.modifierFlags))
        }
        flagMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: changed),
                        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { changed($0); return $0 }].compactMap { $0 }
    }
    private func chordInput(_ flags: NSEvent.ModifierFlags) -> ChordInput {
        let pressed = flags.intersection([.control, .option, .shift, .command, .function])
        return pressed == chord.flags ? .exact : pressed.isSuperset(of: chord.flags) ? .more : .less
    }
    private func chordEvent(_ input: ChordInput) {
        let action = tracker.handle(input, at: ProcessInfo.processInfo.systemUptime)
        debug("chord \(input) -> \(action.map { "\($0)" } ?? "none") state=\(tracker.state) trusted=\(AXIsProcessTrusted())")
        switch action {
        case .arm:
            pressedAt = ProcessInfo.processInfo.systemUptime
            // The microphone opens with the key press, so the first word is kept. What it hears is held,
            // and thrown away if the keys turn out to be another shortcut.
            if ready && id == nil && pendingCancel == nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { openMicrophone() }
            armTimer?.invalidate()
            armTimer = Timer.scheduledTimer(withTimeInterval: ChordTracker.armDelay, repeats: false) { [weak self] _ in self?.chordEvent(.timer) }
        case .begin:
            held = true
            // During the practice step of setup the dictation stays in the window.
            if !begin(scratch: onboarding?.practising == true) { held = false; tracker.sessionEnded(chordDown: true) }
        case .beginHandsFree:
            pressedAt = ProcessInfo.processInfo.systemUptime
            if !begin(scratch: onboarding?.practising == true, latched: true) { tracker.sessionEnded(chordDown: true) }
        case .finish: held = false; end()
        // Another key joined the chord, so this was a different shortcut.
        case .cancelQuietly: if id != nil { cancel(); pill?.set(.idle) }
        case nil: break
        }
        // Released early, or part of a longer shortcut: no recording, so nothing heard is kept.
        if id == nil, microphone.isOpen { switch tracker.state { case .arming, .holding: break; default: microphone.stop(); debug("microphone closed, no recording") } }
        syncKeyMonitors()
    }
    // Other keys and clicks are observed only while the chord is down, to tell it apart from longer shortcuts.
    private func syncKeyMonitors() {
        let needed: Bool
        switch tracker.state { case .arming, .holding, .handsFree(armed: false): needed = true; default: needed = false }
        if needed && keyMonitors.isEmpty {
            let joined: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            // Deferred so a monitor is never removed from inside its own handler.
            let other = { [weak self] in DispatchQueue.main.async { self?.chordEvent(.otherKey) } }
            keyMonitors = [NSEvent.addGlobalMonitorForEvents(matching: joined) { _ in other() },
                           NSEvent.addLocalMonitorForEvents(matching: joined) { other(); return $0 }].compactMap { $0 }
        } else if !needed && !keyMonitors.isEmpty {
            keyMonitors.forEach(NSEvent.removeMonitor); keyMonitors = []
        }
    }
    private func setEscape(_ active: Bool) {
        if active && escapeHotKey == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x51564143, id: 3), GetApplicationEventTarget(), 0, &escapeHotKey)
        } else if !active, let key = escapeHotKey { UnregisterEventHotKey(key); escapeHotKey = nil }
    }
    private func loadSettings() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: launch.configPath)), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        config = value; vocabulary.load(value["vocabulary"] as? [String] ?? [])
        autoInsert = value["autoInsert"] as? Bool ?? true
        autoInsertBox.state = autoInsert ? .on : .off; autoInsertItem?.state = autoInsert ? .on : .off
        chord = parseChord(value["shortcut"] as? String)
        refreshKeys()
        pill?.view.hint = "Hold \(chord.symbols) to dictate"
        targetLabel.stringValue = "Hold \(chord.words) to dictate. Double-tap for hands-free."
    }
    private func startWorker() {
        ready = false; failed = false; models = ModelSetup(); onboarding?.showModels(models); statusItem.button?.toolTip = "RambleFlow · loading"
        pill?.rest(.notice("Loading models"))
        worker.received = { [weak self] in self?.receive($0) }
        worker.exited = { [weak self] message in
            guard let self else { return }; self.microphone.stop(); self.ready = false; self.failed = true; self.reset(); self.status.stringValue = message; self.statusItem.button?.toolTip = "RambleFlow · error"
            self.pill?.rest(.notice("Models stopped. Open the app to reload"))
        }
        do { try worker.launch(launch) } catch { failed = true; status.stringValue = "Cannot start local model worker: \(error.localizedDescription)"; pill?.rest(.notice("Models could not start. Open the app")) }
    }
    private func restartWorker(_ reason: String) {
        debug("restarting worker: \(reason)")
        pendingCancel = nil
        worker.received = nil; worker.exited = nil; worker.abandon(); worker = Worker(); startWorker()
        status.stringValue = reason
    }
    private func receive(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        if type != "partial" && type != "progress" { debug("worker \(type) id=\((message["id"] as? String ?? "").prefix(8)) current=\((id ?? "").prefix(8)) note=\(message["message"] as? String ?? message["warning"] as? String ?? "")") }
        if ["models", "loading", "progress", "loaded"].contains(type) { modelUpdate(type, message); return }
        if type == "ready" {
            ready = true; pill?.rest(.idle); status.stringValue = AXIsProcessTrusted() ? "Ready. Hold \(chord.words)." : "Ready, but Accessibility is off, so the shortcut and insertion cannot work. Switch it on in Settings."; statusItem.button?.toolTip = "RambleFlow"
            if CommandLine.arguments.contains("--ui-smoke") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let view = self.panel.contentView!
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let path = self.launch.projectRoot + "/.local/evidence/app-ui.png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    print("UI_READY: native panel rendered and both real QVAC models loaded. No microphone opened.")
                    self.worker.send(["type": "shutdown"])
                }
            }
            return
        }
        if type == "closed" && CommandLine.arguments.contains("--ui-smoke") { print("UI_CLOSED: models unloaded cleanly."); NSApp.terminate(nil); return }
        if type == "warning" { status.stringValue = message["message"] as? String ?? ""; pill?.notice("Using backup speech recognition", problem: true); return }
        if type == "fatal" { ready = false; failed = true; status.stringValue = message["message"] as? String ?? "Model loading failed."; pill?.rest(.notice("Models failed to load. Open the app")); return }
        if let pendingCancel, message["id"] as? String == pendingCancel {
            if type == "error" { self.pendingCancel = nil; restartWorker("The cancelled recording failed to shut down, so the models are restarting.") }
            if type == "cancelled" {
                self.pendingCancel = nil
                // The recognizer did not close the cancelled stream. Its state is unknown, and forcing it
                // closed breaks the speech model, so start over with a fresh worker.
                if message["stuck"] as? Bool == true { restartWorker("The speech recognizer did not stop cleanly, so the models are restarting.") }
            }
            return
        }
        guard let messageID = message["id"] as? String, messageID == id else { return }
        switch type {
        case "recording":
            recording = true; microphoneGuard?.invalidate()
            if pendingStop || (!held && !latched) {
                // A short press: what was heard since the key went down still goes to the worker.
                if microphone.isOpen { microphone.forward { [weak self] data in self?.worker.send(["type": "audio", "id": messageID, "data": data.base64EncodedString()]) } }
                end(); return
            }
            do {
                microphone.onLevel = { [weak self] level in self?.pill?.push(level: level); self?.onboarding?.push(level: level) }
                if !microphone.isOpen { try microphone.open(requireLoopback: requiresReplayLoopback); openedAt = ProcessInfo.processInfo.systemUptime }
                // Audio heard since the key press goes first, then the live audio.
                microphone.forward { [weak self] data in self?.worker.send(["type": "audio", "id": messageID, "data": data.base64EncodedString()]) }
                // The cue says the recording is under way. Speech before it is already kept.
                let cue = UserDefaults.standard.object(forKey: "startSound") as? Bool ?? true ? NSSound(named: "Pop")?.play() : nil
                let now = ProcessInfo.processInfo.systemUptime, ms = { (time: TimeInterval?) in time.map { "\(Int((now - $0) * 1000))" } ?? "?" }
                debug("microphone cuePlayed=\(cue.map { "\($0)" } ?? "off") route=\(microphone.route) keysToOpen=\(pressedAt.flatMap { pressed in openedAt.map { "\(Int(($0 - pressed) * 1000))" } } ?? "?")ms keysToSession=\(ms(pressedAt))ms")
                recordingStarted = Date()
                recording = true; status.stringValue = held ? "Recording. Release the shortcut to finish." : "Recording. Tap \(chord.words) or use Stop to finish."; statusItem.button?.toolTip = "RambleFlow · REC"
                captureTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in self?.end() }
            } catch { cancel(); status.stringValue = error.localizedDescription }
        case "partial":
            preview.string = message["text"] as? String ?? ""
            if onboarding?.practising == true { onboarding?.showPractice(preview.string, final: false) }
        case "processing": status.stringValue = cleanupOn ? "Cleaning up locally" : "Finishing"; statusItem.button?.toolTip = "RambleFlow · processing"
        case "result":
            debug("latency result id=\(messageID.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
            if let audio = message["audio"] as? [String: Any] { debug("audio \(audio.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))") }
            let wasScratch = scratch
            var milestone: String?
            result = message["text"] as? String ?? ""; raw = (message["raw"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            viewToggle.selectedSegment = 0; showingRaw = false; preview.string = result
            let warning = message["warning"] as? String
            reset(keepTarget: true)
            // A practice sentence is not something to paste later.
            if !result.isEmpty && !(wasScratch && onboarding != nil) { lastText = result }
            if !result.isEmpty && !wasScratch {
                // Counts only: how many words came out, how many the cleanup dropped, and the kind of writing.
                let kept = wordCount(result)
                let wordsBefore = stats.words, bestBefore = stats.streaks().longest
                stats.record(words: kept, seconds: recordedSeconds, tidied: warning == nil ? wordCount(raw) - kept : 0, kind: sessionMode, app: sessionApp)
                stats.save(to: statsPath); refreshStats()
                // A round number of words, or a longer run of days than ever before, gets a moment.
                let grouping = NumberFormatter(); grouping.numberStyle = .decimal
                if let reached = Stats.milestone(from: wordsBefore, to: stats.words) { milestone = "\(grouping.string(from: NSNumber(value: reached)) ?? "\(reached)") words dictated" }
                else if let days = Stats.streakMilestone(from: bestBefore, to: stats.streaks().longest) { milestone = "\(days) days in a row" }
            }
            let canInsert = !result.isEmpty && !wasScratch && (target != nil || frontApp != nil)
            status.stringValue = warning ?? (wasScratch ? "Scratchpad result ready." : canInsert ? "Ready to insert. Review the preview." : "There was no app to insert into. Press Control + Command + V in a text field to paste, or use Copy.")
            insert.isEnabled = canInsert
            pill?.notice(result.isEmpty ? (warning ?? "Nothing heard") : warning != nil ? "Raw text kept. Check the preview" : wasScratch ? "Scratchpad ready" : canInsert ? "Review to insert" : "Saved. ⌃⌘V pastes it", problem: result.isEmpty)
            // An automatic insertion keeps the window out of the way; anything needing attention shows it.
            // Text with a line break is never pasted unreviewed into an app whose focused control is unknown:
            // it could be a terminal, where each line would run.
            let unreviewedRisk = target == nil && result.contains(where: \.isNewline)
            // Said after the result's own notice has had its turn, so neither hides the other.
            // Not when this result needs attention, and not if another dictation has begun by then.
            if let milestone, warning == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if let self, self.id == nil { self.pill?.celebrate(milestone) } } }
            if wasScratch, onboarding?.practising == true { onboarding?.showPractice(result, final: true, problem: warning) }
            else if autoInsert && warning == nil && canInsert && !unreviewedRisk {
                debug("latency insertion begin id=\(messageID.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
                insertResult()
                debug("latency insertion end id=\(messageID.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
            }
            else if !CommandLine.arguments.contains("--ui-smoke") { showReview() }
        case "cancelled": reset(); status.stringValue = "Cancelled. Nothing was inserted."
        case "error":
            // After a failed session the worker may refuse or fail every later one, so it is replaced.
            microphone.stop(); reset()
            restartWorker("Something went wrong (\(message["message"] as? String ?? "local inference failed")). The models are restarting.")
            pill?.notice("Something went wrong. Restarting", problem: true)
        default: break
        }
    }
    private func modelUpdate(_ type: String, _ message: [String: Any]) {
        let key = message["model"] as? String ?? "", wasDownloading = models.downloading
        let number = { (name: String) in (message[name] as? NSNumber)?.int64Value }
        switch type {
        case "models": models.plan((message["models"] as? [[String: Any]] ?? []).map { ($0["key"] as? String ?? "", ($0["bytes"] as? NSNumber)?.int64Value, $0["name"] as? String) })
        case "loading": models.started(key)
        case "progress": if let fetched = number("downloaded"), let total = number("total") { models.progress(key, fetched: fetched, total: total, at: ProcessInfo.processInfo.systemUptime) }
        default: models.loaded(key)
        }
        onboarding?.showModels(models)
        guard !ready && !failed else { return }
        status.stringValue = models.downloading ? "\(models.headline): \(models.detail)\(models.detail.hasSuffix(".") ? "" : ".")" : "Loading the speech models."
        statusItem.button?.toolTip = models.downloading ? "RambleFlow · \(Int(models.fraction * 100))%" : "RambleFlow · loading"
        if models.downloading && !wasDownloading { pill?.rest(.notice("Downloading models")) }
    }
    @discardableResult
    private func begin(scratch requested: Bool, latched: Bool = false) -> Bool {
        // On the practice screen of setup every dictation stays in the window, however it was started.
        let scratch = requested || onboarding?.practising == true
        guard ready else { status.stringValue = "Models are still loading. Try again when the app is ready."; return false }
        guard id == nil else { return false }
        guard pendingCancel == nil else { status.stringValue = "Still cancelling the last recording. Try again in a moment."; pill?.notice("One moment"); return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { status.stringValue = "Enable microphone access before recording."; pill?.notice("Microphone access needed", problem: true); show(); return false }
        let terms = vocabulary.terms
        if terms.count > 80 || terms.contains(where: { $0.count > 100 }) { status.stringValue = "Use up to 80 vocabulary terms, each up to 100 characters."; return false }
        // Without a usable field the result is kept for Copy or paste-last.
        target = scratch ? nil : captureTarget()
        frontApp = nil
        let replayReceiver = ProcessInfo.processInfo.environment["QVAC_REPLAY_RECEIVER"]
        if !scratch && !replayTargetAllowed(expectedBundle: replayReceiver,
                                              directTargetBundle: target?.bundle) {
            target = nil
            status.stringValue = "Benchmark receiver is not focused."
            return false
        }
        // Many apps, browser-based ones especially, do not expose their text box. Remember the app instead.
        if !scratch, target == nil, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let window = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
            frontApp = (app.processIdentifier, app.bundleIdentifier ?? "", window.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil })
        }
        lastInsertion = nil; undo.isEnabled = false
        self.scratch = scratch; self.latched = latched || scratch
        let bundle = scratch ? "" : target?.bundle ?? frontApp?.bundle ?? ""
        let mode = modePicker.indexOfSelectedItem == 0 ? writingMode(bundle) : modePicker.titleOfSelectedItem!
        sessionMode = mode; sessionApp = scratch ? nil : bundle
        id = UUID().uuidString; result = ""; raw = ""; viewToggle.selectedSegment = 0; showingRaw = false; preview.string = ""; insert.isEnabled = false
        pendingStop = false
        status.stringValue = "Starting microphone"; targetLabel.stringValue = scratch ? "Scratchpad only. No external insertion." : target.map { "Target: \($0.bundle), mode: \(mode)" } ?? frontApp.map { "Target: \($0.bundle), pasted at its cursor, mode: \(mode)" } ?? "No app in front. The result will be kept for Copy or paste."
        record.title = scratch ? "Stop" : "Try in scratchpad"
        // Opened here when the key press did not open it already: hands-free, a button, or the menu.
        // It starts while the worker prepares the session, not after.
        if !microphone.isOpen { openMicrophone() }
        microphoneGuard?.invalidate()
        microphoneGuard = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.recording, self.microphone.isOpen else { return }
            self.microphone.stop(); self.debug("microphone closed, session not acknowledged in 5 s")
        }
        worker.send(["type": "start", "id": id!, "mode": mode, "vocabulary": terms, "cleanup": cleanupOn,
                     "replayEligible": !scratch && replayReceiver != nil && target?.bundle == replayReceiver])
        timeout = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in self?.cancel(); self?.status.stringValue = "Operation timed out. Nothing was inserted. Reload models if needed." }
        setEscape(true)
        pill?.set(.recording)
        if scratch { onboarding?.practiceStarted() }
        return true
    }
    private var requiresReplayLoopback: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["QVAC_REPLAY_PCM"] == "1" && env["QVAC_REPLAY_RECEIVER"] != nil
    }
    private func openMicrophone() {
        do { try microphone.open(requireLoopback: requiresReplayLoopback); openedAt = ProcessInfo.processInfo.systemUptime }
        // Tried again when the session is ready, where a failure is reported.
        catch { openedAt = nil; debug("microphone early open failed: \(error.localizedDescription)") }
    }
    private func end() {
        guard let id, !processing else { return }
        // A quick key release can precede the worker's session acknowledgement.
        // The recording acknowledgement will call end after the session exists.
        guard recording else { held = false; pendingStop = true; return }
        debug("latency stop begin id=\(id.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
        microphone.stop()
        debug("latency microphone stopped id=\(id.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
        recording = false; processing = true; captureTimer?.invalidate()
        recordedSeconds = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0; recordingStarted = nil
        pill?.set(.processing)
        debug("latency stop dispatch id=\(id.prefix(8)) uptime=\(ProcessInfo.processInfo.systemUptime)")
        worker.send(["type": "stop", "id": id])
    }
    private func reset(keepTarget: Bool = false) {
        timeout?.invalidate(); captureTimer?.invalidate(); recording = false; processing = false; scratch = false; id = nil; held = false; latched = false
        pendingStop = false; pressedAt = nil; openedAt = nil
        // Whatever ended the session, the microphone is off afterwards.
        microphoneGuard?.invalidate(); microphone.stop()
        onboarding?.practiceEnded()
        microphone.onLevel = nil
        if pill?.state == .recording || pill?.state == .processing { pill?.set(.idle) }
        setEscape(false)
        tracker.sessionEnded(chordDown: chordInput(NSEvent.modifierFlags) != .less); syncKeyMonitors()
        record.title = "Try in scratchpad"; statusItem.button?.toolTip = ready ? "RambleFlow" : "RambleFlow · error"
        if !keepTarget { target = nil; frontApp = nil; insert.isEnabled = false }
    }
    // `direct` is true when the text went in through Accessibility, which is the only case that can be undone precisely.
    private typealias Placement = (done: Bool, message: String, direct: Bool)
    private func place(_ text: String, in target: FocusTarget) -> Placement {
        guard replayTargetAllowed(expectedBundle: ProcessInfo.processInfo.environment["QVAC_REPLAY_RECEIVER"],
                                  directTargetBundle: target.bundle) else {
            return (false, "Benchmark receiver is not focused. Preview retained.", false)
        }
        if let reason = targetMismatch(target) {
            debug("insertion refused: \(reason)")
            return (false, "Target or cursor changed. Nothing inserted. Copy the preview if needed.", false)
        }
        // Terminals can execute a pasted newline. Always require a manual paste there.
        if isTerminal(target.bundle) { return (false, "Terminal text is ready. Use Copy and paste it yourself after review.", false) }
        if isCodeEditor(target.bundle) && text.contains(where: \.isNewline) { return (false, "This app has a built-in terminal, so text with line breaks is not inserted for you. Use Copy and paste it yourself.", false) }
        // A terminal embedded in a web page announces itself in the focused element's classes.
        if (attribute(target.element, "AXDOMClassList") as? [String])?.contains(where: { $0.lowercased().contains("xterm") }) == true { return (false, "Terminal text is ready. Use Copy and paste it yourself after review.", false) }
        var settable = DarwinBoolean(false)
        // Text boxes inside web content (Claude, Codex, pages in a browser) accept a direct write and report
        // success without the text ever appearing, so those are pasted at the cursor instead.
        if !isWebContent(target.element), AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return (true, "Inserted into the captured field.", true)
        }
        if let reason = targetMismatch(target) {
            debug("paste refused: \(reason)")
            return (false, "Target changed. Nothing inserted. Copy the preview if needed.", false)
        }
        return clipboardPaste(text, pid: target.pid)
    }
    // For apps that expose no text field: paste at the cursor of the app that was in front when recording began.
    private func pasteIntoFrontApp(_ text: String, pid: pid_t, bundle: String, window: AXUIElement? = nil) -> Placement {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return (false, "The app in front changed. Nothing inserted. Copy the preview if needed.", false) }
        // The window that was focused when recording began must still be the focused one.
        if let window {
            let now = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
            guard let now, CFEqual(now, window) else { return (false, "The window in front changed. Nothing inserted. Copy the preview if needed.", false) }
        }
        if isTerminal(bundle) { return (false, "Terminal text is ready. Use Copy and paste it yourself after review.", false) }
        if isCodeEditor(bundle) && text.contains(where: \.isNewline) { return (false, "This app has a built-in terminal, so text with line breaks is not pasted for you. Use Copy and paste it yourself.", false) }
        // macOS sets this while a password field has the keyboard, even in apps that hide their fields.
        if IsSecureEventInputEnabled() { return (false, "A password field is active. Nothing inserted.", false) }
        return clipboardPaste(text, pid: pid)
    }
    private func clipboardPaste(_ text: String, pid: pid_t) -> Placement {
        guard ProcessInfo.processInfo.environment["QVAC_REPLAY_RECEIVER"] == nil else {
            return (false, "Benchmark receiver requires direct insertion. Preview retained.", false)
        }
        let pasteboard = NSPasteboard.general
        // If an earlier paste has not been undone yet, the clipboard holds dictated text, not the user's.
        clipboardRestore?.cancel()
        let snapshot = clipboardSnapshot ?? (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        }
        clipboardSnapshot = snapshot
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return (false, "Cannot create paste event. Preview retained.", false) }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let ownChange = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        let restore = DispatchWorkItem { [weak self] in
            // Left alone if the user copied something else in the meantime.
            if pasteboard.changeCount == ownChange { pasteboard.clearContents(); pasteboard.writeObjects(snapshot) }
            self?.clipboardSnapshot = nil; self?.clipboardRestore = nil
        }
        clipboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: restore)
        return (true, "Paste sent to the app in front. Check the result.", false)
    }
    @objc private func insertResult() {
        let text = preview.string
        let outcome: Placement
        if text.isEmpty { outcome = (false, "Nothing to insert.", false) }
        else if let target { outcome = place(text, in: target) }
        else if let frontApp { outcome = pasteIntoFrontApp(text, pid: frontApp.pid, bundle: frontApp.bundle, window: frontApp.window) }
        else { outcome = (false, "Target or cursor changed. Nothing inserted. Copy the preview if needed.", false) }
        status.stringValue = outcome.message
        pill?.notice(outcome.done ? "Inserted" : "Not inserted. Open the app", problem: !outcome.done)
        guard outcome.done else { if !CommandLine.arguments.contains("--ui-smoke") { showReview() }; return }
        lastInsertion = nil
        if outcome.direct, let target, let location = selectionLocation(target.selection), !raw.isEmpty, raw != text {
            lastInsertion = (target.element, location, text, raw)
        }
        undo.isEnabled = lastInsertion != nil
        insert.isEnabled = false; self.target = nil; frontApp = nil
    }
    @objc private func pasteLast() {
        guard id == nil else { status.stringValue = "Finish or cancel dictation before pasting."; return }
        guard !lastText.isEmpty else { status.stringValue = "Nothing to paste yet."; pill?.notice("Nothing to paste yet"); return }
        lastInsertion = nil; undo.isEnabled = false
        let outcome: Placement
        if let fresh = captureTarget() { outcome = place(lastText, in: fresh) }
        else if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            outcome = pasteIntoFrontApp(lastText, pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "")
        } else { outcome = (false, "Click into the app you want to paste into, then paste again.", false) }
        status.stringValue = outcome.message; pill?.notice(outcome.done ? "Pasted" : "Not pasted. Open the app", problem: !outcome.done)
    }
    // Swaps the inserted text for what was actually recognized, only while it is still exactly where it was put.
    @objc private func undoCleanup() {
        guard let last = lastInsertion else { return }
        lastInsertion = nil; undo.isEnabled = false
        var range = CFRange(location: last.location, length: (last.inserted as NSString).length)
        var current: CFTypeRef?
        if !isSecure(last.element), let value = AXValueCreate(.cfRange, &range),
           AXUIElementCopyParameterizedAttributeValue(last.element, kAXStringForRangeParameterizedAttribute as CFString, value, &current) == .success,
           (current as? String) == last.inserted,
           AXUIElementSetAttributeValue(last.element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
           AXUIElementSetAttributeValue(last.element, kAXSelectedTextAttribute as CFString, last.raw as CFString) == .success {
            status.stringValue = "Replaced with the recognized text."; pill?.notice("Cleanup undone"); return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(last.raw, forType: .string)
        status.stringValue = "The text has changed since it was inserted, so the recognized text was copied instead."; pill?.notice("Raw text copied")
    }
    @objc private func switchView() {
        let wantsRaw = viewToggle.selectedSegment == 1
        guard wantsRaw != showingRaw else { return }
        // Keep edits made to the cleaned text when looking at the raw one.
        if wantsRaw { result = preview.string; preview.string = raw } else { preview.string = result }
        showingRaw = wantsRaw
    }
    @objc private func toggleCleanup() {
        cleanupOn.toggle(); UserDefaults.standard.set(cleanupOn, forKey: "cleanup")
        cleanupBox.state = cleanupOn ? .on : .off; cleanupItem?.state = cleanupOn ? .on : .off
        status.stringValue = cleanupOn ? "Cleanup on: fillers removed and punctuation fixed locally." : "Cleanup off: you get the recognizer's exact text."
    }
    @objc private func toggleAutoInsert() {
        let wanted = !autoInsert
        do {
            try updateConfig { $0["autoInsert"] = wanted }
            autoInsert = wanted
            status.stringValue = wanted ? "Text will be inserted as soon as it is ready." : "Text will wait for review before it is inserted."
        } catch { status.stringValue = "Could not save the setting: \(error.localizedDescription)" }
        autoInsertBox.state = autoInsert ? .on : .off; autoInsertItem?.state = autoInsert ? .on : .off
    }
    private func updateConfig(_ change: (inout [String: Any]) -> Void) throws {
        // Re-read to preserve model settings edited outside the app.
        guard var latest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.configPath))) as? [String: Any] else {
            throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model settings must be a JSON object."])
        }
        change(&latest)
        try JSONSerialization.data(withJSONObject: latest, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: launch.configPath), options: .atomic)
    }
    @objc private func copyResult() { copyPreview(to: .general) }
    private func copyPreview(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(preview.string, forType: .string)
        status.stringValue = "Copied preview."
    }
    @objc private func toggleScratch() { if id == nil { if begin(scratch: true) { tracker.latchedElsewhere() } } else { end() } }
    @objc private func cancel() { microphone.stop(); if let id { worker.send(["type": "cancel", "id": id]); awaitCancel(id) }; reset(); pill?.notice("Cancelled"); status.stringValue = "Cancelled. Nothing was inserted." }
    private func awaitCancel(_ id: String) {
        pendingCancel = id
        // The worker sends no acknowledgement for a session it already finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.pendingCancel == id { self?.pendingCancel = nil } }
    }
    @objc private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { self.status.stringValue = granted ? "Microphone enabled." : "Microphone denied. Enable RambleFlow in System Settings > Privacy & Security > Microphone." } }
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        status.stringValue = AXIsProcessTrustedWithOptions(options) ? "Accessibility enabled." : "Enable RambleFlow in System Settings > Privacy & Security > Accessibility."
    }
    @objc private func addVocabularyEntry() {
        if !vocabulary.addEntry() { status.stringValue = "Use up to 80 vocabulary terms." }
    }
    @objc private func saveVocabulary() {
        let terms = vocabulary.terms
        guard terms.count <= 80, terms.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else { status.stringValue = "Use up to 80 vocabulary terms, each up to 100 characters."; return }
        do {
            try updateConfig { $0["vocabulary"] = terms }
            status.stringValue = "Vocabulary saved locally."
        } catch { status.stringValue = "Could not save vocabulary: \(error.localizedDescription)" }
    }
    @objc private func show() { if panel.isMiniaturized { panel.deminiaturize(nil) }; panel.orderFrontRegardless() }
    // Anything about the last dictation that needs the user (a result to check, a failed insertion) lives on Review.
    private func showReview() {
        // A real dictation made before setup was finished: its result must not sit hidden underneath.
        if let onboarding, !onboarding.practising { onboarding.finished?() }
        tabs.select(1); show()
    }
    @objc private func openSettings() { NSWorkspace.shared.open(URL(fileURLWithPath: launch.configPath)) }
    @objc private func reload() {
        guard id == nil else { status.stringValue = "Finish or cancel dictation before reloading."; return }
        worker.received = nil; worker.exited = nil; worker.stop(); worker = Worker(); loadSettings(); startWorker()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        microphone.stop(); worker.stop(); pill?.close()
        if let pasteHotKey { UnregisterEventHotKey(pasteHotKey) }
        setEscape(false)
        (flagMonitors + keyMonitors).forEach(NSEvent.removeMonitor)
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    // Renders each page of the window, light and dark, with sample numbers. No worker, models or microphone.
    func renderPreview(to directory: URL) {
        makePanel(); makeMenu()
        ready = true
        var sample = Stats()
        // Fifteen weeks of invented use: busier on weekdays, a few idle days, four kinds of writing.
        for offset in 0..<105 where offset % 11 != 7 && !(offset > 9 && offset % 7 == 5) {
            let amount = 90 + (offset * 137) % 760
            sample.record(words: amount, seconds: Double(amount) / 2.4, tidied: amount / 9, kind: ["prompt", "prompt", "formal", "prompt", "minimal", "casual"][offset % 6], app: ["com.apple.Notes", "com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.TextEdit", "com.apple.MobileSMS", "com.apple.Safari", "com.apple.dt.Xcode"][offset % 8], on: Date().addingTimeInterval(-86400 * Double(offset)))
        }
        stats = sample
        status.stringValue = "Ready. Hold \(chord.words)."
        targetLabel.stringValue = "Target: com.apple.Notes, mode: minimal"
        preview.string = "Let's move the review to Thursday at three, and send Nora the updated budget before then."
        vocabulary.load(["QVAC", "Parakeet", "Nora Lindqvist", "React Query"])
        insert.isEnabled = true; autoInsertBox.state = .on
        refreshStats(animated: false); refreshChrome()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            for (index, page) in ["home", "review", "vocabulary", "settings"].enumerated() {
                tabs.select(index, animated: false); pages.enumerated().forEach { $1.isHidden = $0 != index; $1.alphaValue = 1 }
                pageTitle.stringValue = Self.pageNames[index].0
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded(); view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window-\(page)-\(name).png"))
            }
        }
        // The four setup screens, light and dark.
        makeOnboarding()
        // First run: a permission screen with the slim progress line, then the practice screen with the full card,
        // the speech model done and the cleanup model part way.
        ready = false
        models.plan([("speech", 398_734_976), ("cleanup", 1_056_782_912)])
        models.started("speech")
        for (second, bytes) in [(0.0, 40_000_000), (1.0, 130_000_000), (2.0, 220_000_000)] as [(Double, Int64)] { models.progress("speech", fetched: bytes, total: 398_734_976, at: second) }
        let early = models
        // A later start with nothing to fetch: the speech model is being read from disk.
        var disk = ModelSetup(); disk.plan([("speech", 859_541_333), ("cleanup", 1_056_782_912)]); disk.started("speech"); disk.progress("speech", fetched: 859_541_333, total: 859_541_333, at: 0)
        models.progress("speech", fetched: 398_734_976, total: 398_734_976, at: 4); models.loaded("speech"); models.started("cleanup")
        for (second, bytes) in [(5.0, 100_000_000), (6.0, 190_000_000), (7.0, 412_000_000)] as [(Double, Int64)] { models.progress("cleanup", fetched: bytes, total: 1_056_782_912, at: second) }
        // The release build: the timed recognizer's model downloads too, so the card has a third line.
        var release = ModelSetup()
        release.plan([("timed", 2_471_863_880, "Speech recognition"), ("speech", 398_734_976, "Backup speech recognition"), ("cleanup", 1_056_782_912, "Text cleanup")])
        release.started("cleanup")
        for (second, bytes) in [(0.0, 300_000_000), (1.0, 700_000_000), (2.0, 1_056_782_912)] as [(Double, Int64)] { release.progress("cleanup", fetched: bytes, total: 1_056_782_912, at: second) }
        release.started("timed")
        for (second, bytes) in [(3.0, 200_000_000), (4.0, 600_000_000), (5.0, 1_000_000_000)] as [(Double, Int64)] { release.progress("timed", fetched: bytes, total: 2_471_863_880, at: second) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            for (step, state, label) in [(0, early, "1-downloading"), (OnboardingView.practiceStep, models, "3-downloading"), (OnboardingView.practiceStep, disk, "3-loading"), (OnboardingView.practiceStep, release, "3-release")] {
                onboarding?.update(microphone: step > 0, microphoneAsked: step > 0, accessibility: step > 1, modelsReady: false)
                onboarding?.showModels(state); onboarding?.show(step, animated: false); onboarding?.freezeProgress(at: 0.55)
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded(); view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("setup-\(label)-\(name).png"))
            }
        }
        ready = true; models.loaded("cleanup"); onboarding?.showModels(models)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            for step in 0..<OnboardingView.steps {
                // Permissions are reported as still missing on their own screens, so those screens stay put.
                onboarding?.update(microphone: step > 0, microphoneAsked: step > 0, accessibility: step > 1)
                onboarding?.show(step, animated: false)
                if step == OnboardingView.practiceStep { onboarding?.showPractice("Let's move the review to Thursday at three.", final: true) }
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded(); view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("setup-\(step + 1)-\(name).png"))
            }
        }
        panel.close(); NSStatusBar.system.removeStatusItem(statusItem)
    }
    func testRefusedInsertionCopy() {
        let receiver = NSTextView()
        receiver.string = "Original receiver text"
        let completed = "Completed test dictation."
        preview.string = completed
        let staleTarget = FocusTarget(pid: 0, bundle: "benchmark.receiver",
                                      element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                                      value: receiver.string, selection: nil)
        let outcome = place(preview.string, in: staleTarget)
        precondition(!outcome.done && receiver.string == "Original receiver text")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        copyPreview(to: pasteboard)
        precondition(pasteboard.string(forType: .string) == completed)
    }

    func testPendingStopRace() {
        // An owned UI fixture with no worker or microphone. Deliver the delayed
        // acknowledgement after Stop through the actual controller methods.
        makePanel(); makeMenu()
        ready = true; scratch = true; latched = true; held = false; id = "delayed-start-test"
        end()
        precondition(pendingStop && !recording && !processing)
        receive(["type": "recording", "id": "delayed-start-test"])
        precondition(processing && !recording)
        reset(); panel.close(); NSStatusBar.system.removeStatusItem(statusItem)
    }
}
