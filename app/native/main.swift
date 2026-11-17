import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio

if CommandLine.arguments.contains("--self-test") {
    precondition(writingMode("com.apple.mail") == "formal")
    precondition(writingMode("com.microsoft.VSCode") == "prompt")
    precondition(writingMode("com.apple.iChat") == "casual")
    precondition(writingMode("com.apple.Notes") == "minimal")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    precondition(format.streamDescription.pointee.mBytesPerFrame == 2)
    precondition(replayTargetAllowed(expectedBundle: nil, directTargetBundle: nil))
    precondition(replayTargetAllowed(expectedBundle: "benchmark.receiver", directTargetBundle: "benchmark.receiver"))
    precondition(!replayTargetAllowed(expectedBundle: "benchmark.receiver", directTargetBundle: "other.app"))
    precondition(!replayTargetAllowed(expectedBundle: "benchmark.receiver", directTargetBundle: nil))
    precondition(unchangedFocus(originalPID: 10, currentPID: 10, sameElement: true, secure: false, sameValue: true, sameSelection: true))
    precondition(!unchangedFocus(originalPID: 10, currentPID: 11, sameElement: true, secure: false, sameValue: true, sameSelection: true))
    precondition(!unchangedFocus(originalPID: 10, currentPID: 10, sameElement: false, secure: false, sameValue: true, sameSelection: true))
    precondition(!unchangedFocus(originalPID: 10, currentPID: 10, sameElement: true, secure: true, sameValue: true, sameSelection: true))
    precondition(!unchangedFocus(originalPID: 10, currentPID: 10, sameElement: true, secure: false, sameValue: false, sameSelection: true))
    precondition(!unchangedFocus(originalPID: 10, currentPID: 10, sameElement: true, secure: false, sameValue: true, sameSelection: false))
    // Deliberate own scratchpad only. Exercise replacement while retaining surrounding text.
    let scratchpad = NSTextView()
    scratchpad.string = "Before placeholder after"
    scratchpad.setSelectedRange(NSRange(location: 7, length: 11))
    scratchpad.insertText("dictation", replacementRange: scratchpad.selectedRange())
    precondition(scratchpad.string == "Before dictation after")
    _ = NSApplication.shared
    let ownedFixture = DictationApp(LaunchConfig(projectRoot: "/unused", nodePath: "/unused", configPath: "/unused"))
    ownedFixture.testRefusedInsertionCopy()
    ownedFixture.testPendingStopRace()
    // Hold: nothing starts until the chord has been down alone for the arming delay.
    var hold = ChordTracker()
    precondition(hold.handle(.exact, at: 0) == .arm && hold.handle(.timer, at: 0.1) == nil)
    precondition(hold.handle(.timer, at: 0.2) == .begin && hold.handle(.less, at: 3) == .finish && hold.state == .idle)
    // Double-tap latches hands-free; the next press finishes it.
    var tap = ChordTracker()
    precondition(tap.handle(.exact, at: 0) == .arm && tap.handle(.less, at: 0.1) == nil)
    precondition(tap.handle(.exact, at: 0.4) == .beginHandsFree && tap.handle(.timer, at: 0.45) == nil && tap.handle(.less, at: 0.5) == nil)
    precondition(tap.handle(.otherKey, at: 2) == nil && tap.handle(.exact, at: 9) == .finish && tap.handle(.less, at: 9.1) == nil && tap.state == .idle)
    // A second tap that grows into a longer shortcut does not leave the microphone on.
    var grown = ChordTracker()
    _ = grown.handle(.exact, at: 0); _ = grown.handle(.less, at: 0.1)
    precondition(grown.handle(.exact, at: 0.3) == .beginHandsFree && grown.handle(.otherKey, at: 0.35) == .cancelQuietly && grown.state == .blocked)
    var caret = CFRange(location: 7, length: 0)
    precondition(selectionLocation(AXValueCreate(.cfRange, &caret)) == 7 && selectionLocation(nil) == nil && selectionLocation("text" as CFString) == nil)
    // Each of these has a built-in terminal and must never receive pasted line breaks unreviewed.
    for editor in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.jetbrains.intellij", "dev.zed.Zed", "org.gnu.Emacs", "com.termius-dmg.mac"] {
        precondition(isCodeEditor(editor), editor)
    }
    precondition(!isCodeEditor("com.apple.Notes") && !isCodeEditor("com.google.Chrome"))
    // The motion curves: exact ends, a straight line when the handles say so, a landing with no overshoot
    // for smooth-out, and a small overshoot for bounce.
    let samples = stride(from: CGFloat(0), through: 1, by: 0.05).map { $0 }
    precondition(abs(Motion.smoothOut(0)) < 0.001 && abs(Motion.smoothOut(1) - 1) < 0.001 && abs(Motion.bounce(1) - 1) < 0.001)
    precondition(samples.allSatisfy { abs(Motion.bezier($0, 1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3) - $0) < 0.002 })
    precondition(zip(samples, samples.dropFirst()).allSatisfy { Motion.smoothOut($1) >= Motion.smoothOut($0) - 0.001 } && samples.allSatisfy { Motion.smoothOut($0) <= 1.001 })
    precondition(Motion.smoothOut(0.25) > 0.7 && (samples.map(Motion.bounce).max() ?? 0) > 1.02 && (samples.map(Motion.bounce).max() ?? 9) < 1.12)
    // Stats: counts, pace and streaks, on a fixed calendar so the check does not depend on today's date.
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let day = { (offset: Int) in Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 86400) }
    precondition(wordCount("  send 85 euros\nto Nora ") == 5 && wordCount("") == 0)
    var counts = Stats()
    precondition(counts.wordsPerMinute == nil && counts.streaks(today: day(0), calendar: utc) == (0, 0))
    counts.record(words: 0, seconds: 5, on: day(-9), calendar: utc)
    precondition(counts == Stats())
    for offset in [-9, -8, -7, -3, -2, -1] { counts.record(words: 30, seconds: 15, on: day(offset), calendar: utc) }
    // Nothing yet today: yesterday's streak is still alive, and the older three-day run is the longest equal.
    precondition(counts.streaks(today: day(0), calendar: utc) == (3, 3) && counts.wordsToday(day(0), calendar: utc) == 0)
    counts.record(words: 12, seconds: 6, on: day(0), calendar: utc)
    precondition(counts.streaks(today: day(0), calendar: utc) == (4, 4) && counts.wordsToday(day(0), calendar: utc) == 12)
    // Two days later with no use, the streak is gone but the record stays.
    precondition(counts.streaks(today: day(2), calendar: utc) == (0, 4))
    precondition(counts.words == 192 && counts.dictations == 7 && counts.wordsPerMinute == 120)
    // Kinds of writing, words dropped by cleanup, shading bands, month trend and the calendar grid.
    var rich = Stats()
    rich.record(words: 300, seconds: 120, tidied: 40, kind: "prompt", app: "com.apple.Notes", on: day(-40), calendar: utc)
    rich.record(words: 450, seconds: 180, tidied: -5, kind: "formal", app: "com.apple.mail", on: day(-3), calendar: utc)
    rich.record(words: 150, seconds: 60, kind: "prompt", app: "", on: day(0), calendar: utc)
    precondition(rich.tidied == 40 && rich.kinds == ["prompt": 450, "formal": 450] && rich.apps == ["com.apple.Notes": 300, "com.apple.mail": 450])
    precondition(UsageCard.describe("com.example.NotInstalled.Scribble").name == "Scribble")
    precondition([0, 1, 249, 250, 499, 500, 749, 750].map(Stats.band) == [0, 1, 1, 2, 2, 3, 3, 4])
    // A milestone is announced once, when a total passes it; a jump over several names the highest.
    precondition(Stats.milestone(from: 90, to: 99) == nil && Stats.milestone(from: 99, to: 100) == 100 && Stats.milestone(from: 100, to: 140) == nil)
    precondition(Stats.milestone(from: 80, to: 1_200) == 1_000 && Stats.milestone(from: 1_000_000, to: 2_000_000) == nil)
    // A self-contained build finds its own runtime and writes a first config with no model path.
    do {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rambleflow-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let launch = try LaunchConfig.bundled(resources: URL(fileURLWithPath: "/Apps/R.app/Contents/Resources"), support: scratch)
        precondition(launch.nodePath == "/Apps/R.app/Contents/Resources/runtime/node" && launch.projectRoot.hasSuffix("/Resources/runtime"))
        let made = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.configPath))) as! [String: Any]
        precondition(made["modelPath"] == nil && made["autoInsert"] as? Bool == true && made["version"] as? Int == 1 && (made["cacheDirectory"] as? String)?.hasSuffix("/models") == true)
        let resources = URL(fileURLWithPath: "/Apps/R.app/Contents/Resources")
        let fast = scratch.appendingPathComponent("fast")
        do {
            _ = try LaunchConfig.bundled(resources: resources, support: fast, fastRuntime: true)
            preconditionFailure("Missing fast runtime accepted")
        } catch CocoaError.fileNoSuchFile {}
        let timed = fast.appendingPathComponent("timed-runtime")
        let python = timed.appendingPathComponent("python/bin/python")
        let server = timed.appendingPathComponent("Phonon.app/Contents/Resources/sidecar/asr_server.py")
        for file in [python, server] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        try FileManager.default.createDirectory(at: timed.appendingPathComponent("asr-model"), withIntermediateDirectories: true)
        let configured = try LaunchConfig.bundled(resources: resources, support: fast, fastRuntime: true)
        let configURL = URL(fileURLWithPath: configured.configPath)
        let initial = try Data(contentsOf: configURL)
        let settings = try JSONSerialization.jsonObject(with: initial) as? [String: Any]
        let sidecar = settings?["timedAsr"] as? [String: Any]
        precondition(sidecar?["python"] as? String == python.path)
        precondition(sidecar?["formattingReuse"] as? Bool == true)
        let existing = Data("{}".utf8)
        try existing.write(to: configURL)
        _ = try LaunchConfig.bundled(resources: resources, support: fast, fastRuntime: true)
        let retained = try Data(contentsOf: configURL)
        precondition(retained == existing)

    } catch { fatalError("bundled launch settings failed: \(error)") }
    precondition(Stats.streakMilestone(from: 2, to: 3) == 3 && Stats.streakMilestone(from: 3, to: 4) == nil && Stats.streakMilestone(from: 6, to: 7) == 7 && Stats.streakMilestone(from: 7, to: 7) == nil)
    // 600 words in the last 30 days against 300 in the 30 before.
    precondition(rich.monthTrend(today: day(0), calendar: utc) == 100 && Stats().monthTrend(today: day(0), calendar: utc) == nil)
    let grid = rich.heatmap(weeks: 3, today: day(0), calendar: utc)
    precondition(grid.count == 3 && grid.allSatisfy { $0.count == 7 } && utc.component(.weekday, from: grid[0][0].date) == 1)
    // The test day is a Friday: today carries its count and the Saturday after it is still to come.
    precondition(utc.component(.weekday, from: day(0)) == 6 && grid[2][5].words == 150 && grid[2][6].words == nil)
    // A file written before the newer fields existed keeps its numbers and gains empty ones.
    let older = try? JSONDecoder().decode(Stats.self, from: Data(#"{"words":5,"seconds":2,"dictations":1,"days":{"2027-01-15":5}}"#.utf8))
    precondition(older?.words == 5 && older?.seconds == 2 && older?.dictations == 1 && older?.days == ["2027-01-15": 5] && older?.tidied == 0 && older?.apps == [:])
    let richFile = NSTemporaryDirectory() + "qvac-stats-rich-\(ProcessInfo.processInfo.processIdentifier).json"
    rich.save(to: richFile)
    precondition(Stats.load(from: richFile) == rich)
    try? FileManager.default.removeItem(atPath: richFile)
    let statsFile = NSTemporaryDirectory() + "qvac-stats-\(ProcessInfo.processInfo.processIdentifier).json"
    counts.save(to: statsFile)
    precondition(Stats.load(from: statsFile) == counts && Stats.load(from: statsFile + ".missing") == Stats())
    try? FileManager.default.removeItem(atPath: statsFile)
    precondition(isTerminal("com.mitchellh.ghostty") && isTerminal("com.apple.Terminal") && !isTerminal("com.apple.Notes"))
    // A slow second tap is an ordinary press.
    var slow = ChordTracker()
    _ = slow.handle(.exact, at: 0); _ = slow.handle(.less, at: 0.1)
    precondition(slow.handle(.exact, at: 1) == .arm)
    // A longer shortcut never starts recording, and cancels one that already began.
    var other = ChordTracker()
    precondition(other.handle(.exact, at: 0) == .arm && other.handle(.otherKey, at: 0.05) == nil && other.handle(.timer, at: 0.2) == nil)
    precondition(other.handle(.exact, at: 0.3) == nil && other.handle(.less, at: 0.4) == nil && other.state == .idle)
    precondition(other.handle(.exact, at: 5) == .arm && other.handle(.timer, at: 5.2) == .begin && other.handle(.otherKey, at: 6) == .cancelQuietly)
    precondition(other.handle(.less, at: 6.1) == nil && other.handle(.more, at: 7) == nil && other.handle(.exact, at: 7.1) == nil && other.handle(.less, at: 7.2) == nil)
    // Escape or the limit ends a session while the chord may still be down.
    var ended = ChordTracker()
    _ = ended.handle(.exact, at: 0); _ = ended.handle(.timer, at: 0.2); ended.sessionEnded(chordDown: true)
    precondition(ended.state == .blocked && ended.handle(.less, at: 1) == nil && ended.state == .idle)
    // A recording latched from a button is finished by the next press of the chord.
    var button = ChordTracker()
    button.latchedElsewhere()
    precondition(button.handle(.less, at: 1) == nil && button.handle(.exact, at: 1.1) == .finish)
    precondition(parseChord(nil).keycaps == ["fn"] && parseChord("control+option").symbols == "⌃⌥")
    precondition(inputLevel(rms: 0) == 0 && inputLevel(rms: 1) == 1 && inputLevel(rms: 0.001) == 0 && inputLevel(rms: 0.05) > 0.5)
    precondition(parseChord(nil).words == "Fn" && parseChord("control+option").words == "Control + Option")
    precondition(parseChord("control+option").flags == [.control, .option] && parseChord("fn").flags == .function && parseChord("command").flags == .function && parseChord("option+command").flags == [.option, .command])
    // First-run progress: shares by size, the time left from a steady 100 MB a second, and a model already on disk.
    var fetch = ModelSetup()
    fetch.plan([("speech", 400_000_000), ("cleanup", 1_000_000_000)])
    precondition(!fetch.downloading && fetch.fraction == 0 && fetch.headline == "Loading the speech models")
    fetch.started("speech"); fetch.progress("speech", fetched: 100_000_000, total: 400_000_000, at: 0)
    precondition(fetch.downloading && abs(fetch.fraction - 1.0 / 14) < 0.001 && fetch.remaining == nil && fetch.parts[0].phase == .fetching)
    fetch.progress("speech", fetched: 200_000_000, total: 400_000_000, at: 1); fetch.progress("speech", fetched: 300_000_000, total: 400_000_000, at: 2)
    precondition(fetch.remaining.map { abs($0 - 11) < 0.5 } == true && fetch.headline == "Downloading the speech models")
    fetch.progress("speech", fetched: 400_000_000, total: 400_000_000, at: 3)
    precondition(fetch.parts[0].phase == .preparing && fetch.state(of: fetch.parts[1]) == "Waiting")
    fetch.loaded("speech"); fetch.started("cleanup"); fetch.progress("cleanup", fetched: 5, total: 1_000_000_000, at: 4); fetch.progress("cleanup", fetched: 1_000_000_000, total: 1_000_000_000, at: 4)
    precondition(fetch.fraction == 0.99 && !fetch.ready && fetch.speed.map { abs($0 - 100_000_000) < 1 } == true)
    // After a pause the speed is measured afresh, never averaged over the idle seconds.
    fetch.progress("cleanup", fetched: 1_000_000_000, total: 1_000_000_000, at: 40)
    precondition(fetch.speed.map { abs($0 - 100_000_000) < 1 } == true)
    fetch.loaded("cleanup")
    precondition(fetch.ready && fetch.fraction == 1 && fetch.remaining == nil)
    var cached = ModelSetup()
    cached.plan([("speech", 10), ("cleanup", nil)]); cached.started("speech"); cached.progress("speech", fetched: 10, total: 10, at: 0)
    precondition(!cached.downloading && cached.parts[0].phase == .loading && cached.detail == "Reading them from this Mac.")
    cached.loaded("speech"); cached.started("cleanup"); cached.loaded("cleanup")
    precondition(cached.ready && cached.fraction == 1 && cached.state(of: cached.parts[1]) == "Ready")
    // Speech fetched, cleanup already stored: the stored model never counts as downloaded bytes.
    var mixed = ModelSetup()
    mixed.plan([("speech", 400), ("cleanup", 1_000)]); mixed.started("speech")
    mixed.progress("speech", fetched: 100, total: 400, at: 0); mixed.progress("speech", fetched: 400, total: 400, at: 1); mixed.loaded("speech")
    mixed.started("cleanup"); mixed.progress("cleanup", fetched: 1_000, total: 1_000, at: 2)
    precondition(mixed.downloading && mixed.parts[1].stored && mixed.total == 400 && mixed.done == 400 && mixed.fraction == 0.99 && mixed.remaining == nil)
    precondition(ModelSetup.timeLeft(30) == "less than a minute left" && ModelSetup.timeLeft(55) == "about a minute left" && ModelSetup.timeLeft(61) == "about 2 minutes left" && ModelSetup.timeLeft(7200) == "about 2 hours left")
    // Audio from the key press is held, sent first and in order, then live audio passes straight through.
    var early = EarlyAudio()
    precondition(early.add(Data([1])).isEmpty && early.add(Data([2])).isEmpty && early.heldBytes == 2)
    precondition(early.forward() == [Data([1]), Data([2])] && early.heldBytes == 0 && early.add(Data([3])) == [Data([3])])
    // A session that never starts cannot make it grow without limit: the oldest audio goes first.
    var stuck = EarlyAudio()
    for value in 0..<400 { _ = stuck.add(Data(repeating: UInt8(value % 256), count: 1_000)) }
    precondition(stuck.heldBytes <= EarlyAudio.limit && stuck.held.first == Data(repeating: UInt8(80), count: 1_000))
    print("Native mode, PCM, focus refusal, own scratchpad insertion, delayed-start Stop race, shortcut, early audio, stats and download progress checks passed.")
} else if CommandLine.arguments.contains("--mic-probe") {
    func inputStillRunning() -> String {
        guard let device = defaultInputDevice() else { return "unknown" }
        var running = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr ? (running != 0 ? "yes" : "no") : "unknown"
    }
    // Counts the audio the system's selected microphone delivers in 1.5 seconds, and how long each start takes
    // until the first audio arrives, and writes them beside the private settings. Three starts build a new engine
    // each time (the old way), three reuse one. Nothing is recorded or transcribed. Launch through `open` so the
    // app's own microphone permission applies.
    do {
        let launch = try LaunchConfig.load(resources: Bundle.main.resourceURL!)
        var lines = ["permission=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"]
        let reused = Microphone()
        // Repeated on purpose: a microphone that works once can fail on the next start.
        for (name, fresh) in [("new engine 1", true), ("new engine 2", true), ("new engine 3", true), ("reused engine 1", false), ("reused engine 2", false), ("reused engine 3", false)] {
            let microphone = fresh ? Microphone() : reused
            let lock = NSLock()
            var bytes = 0, chunks = 0, first: TimeInterval?
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try microphone.open()
                let opened = ProcessInfo.processInfo.systemUptime
                microphone.forward { data in lock.lock(); bytes += data.count; chunks += 1; if first == nil { first = ProcessInfo.processInfo.systemUptime }; lock.unlock() }
                Thread.sleep(forTimeInterval: 1.5); microphone.stop()
                // The kept engine must not keep the microphone on: ask Core Audio whether the input still runs.
                Thread.sleep(forTimeInterval: 0.3)
                lock.lock(); defer { lock.unlock() }
                lines.append("\(name): \(microphone.route), stillOnAfterStop=\(inputStillRunning()) open=\(Int((opened - began) * 1000))ms firstAudio=\(first.map { "\(Int(($0 - began) * 1000))" } ?? "none")ms chunks=\(chunks) bytes=\(bytes) (48000 expected)")
            } catch { lines.append("\(name): failed, \(error.localizedDescription)") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try lines.joined(separator: "\n").write(toFile: (launch.configPath as NSString).deletingLastPathComponent + "/mic-probe.log", atomically: true, encoding: .utf8)
    } catch { fputs("Microphone probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let flag = CommandLine.arguments.firstIndex(of: "--ui-preview"), CommandLine.arguments.count > flag + 1 {
    // Renders each pill state to a PNG without models, a worker or a microphone.
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let view = PillView(); view.hint = "Hold fn to dictate"
    let states: [(String, PillState, Bool)] = [("idle", .idle, false), ("hover", .idle, true), ("recording", .recording, false), ("processing", .processing, false), ("notice", .notice("Review to insert"), false)]
    // One sheet, one state per row, so a single image shows them at their relative sizes.
    let sheet = NSImage(size: NSSize(width: 300, height: 64 * states.count))
    sheet.lockFocus()
    NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.7, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
    for (index, (_, state, hovered)) in states.enumerated() {
        view.state = state; view.hovered = hovered; view.phase = 2
        if state == .recording { view.bars = (0..<PillView.barCount).map { 0.25 + 0.6 * abs(sin(CGFloat($0) * 1.1)) } }
        let size = view.preferredSize
        view.frame = NSRect(origin: .zero, size: size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            rep.draw(in: NSRect(x: (sheet.size.width - size.width) / 2, y: sheet.size.height - CGFloat(index + 1) * 64 + (64 - size.height) / 2, width: size.width, height: size.height))
        }
    }
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: directory.appendingPathComponent("pill-states.png"))
    }
    // Each setup animation as a strip of moments, dark, so its motion can be judged without running it.
    let hero = HeroView(); hero.appName = "Dictation"; hero.appearance = NSAppearance(named: .darkAqua)
    let size = hero.intrinsicContentSize
    hero.frame = NSRect(origin: .zero, size: size)
    let scenes: [(String, HeroView.Scene, [CGFloat])] = [("microphone", .microphone, [0.1, 0.7, 1.3, 1.9, 2.5]), ("accessibility", .accessibility, [0.2, 1.0, 1.5, 1.8, 2.6]), ("keys", .keys, [0.1, 0.5, 1.0, 1.8, 2.8]), ("done", .done, [0.05, 0.2, 0.35, 0.6, 1.2])]
    for (name, scene, moments) in scenes {
        let strip = NSImage(size: NSSize(width: size.width * CGFloat(moments.count), height: size.height))
        strip.lockFocus()
        NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1).setFill(); NSRect(origin: .zero, size: strip.size).fill()
        for (index, moment) in moments.enumerated() {
            hero.scene = scene; hero.frozen = moment
            if let rep = hero.bitmapImageRepForCachingDisplay(in: hero.bounds) {
                hero.cacheDisplay(in: hero.bounds, to: rep)
                rep.draw(in: NSRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height))
            }
        }
        strip.unlockFocus()
        if let tiff = strip.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("motion-\(name).png"))
        }
    }
    // Confetti at four moments, over a window-sized dark field with a ledge where the button would be.
    let field = NSSize(width: 948, height: 676)
    let paper = ConfettiView(frame: NSRect(origin: .zero, size: field))
    paper.fire(ledge: (y: 180, from: 314, to: 634)); paper.freeze()
    let film = NSImage(size: NSSize(width: field.width * 2, height: field.height * 2))
    film.lockFocus()
    var clock: CGFloat = 0
    for (index, moment) in ([0.18, 0.6, 1.5, 2.8] as [CGFloat]).enumerated() {
        while clock < moment { paper.advance(1.0 / 60); clock += 1.0 / 60 }
        let origin = NSPoint(x: CGFloat(index % 2) * field.width, y: CGFloat(1 - index / 2) * field.height)
        NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1).setFill(); NSRect(origin: origin, size: field).fill()
        NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: NSRect(x: origin.x + 314, y: origin.y + 130, width: 320, height: 50), xRadius: 13, yRadius: 13).fill()
        let shift = NSAffineTransform(); shift.translateX(by: origin.x, yBy: origin.y)
        NSGraphicsContext.saveGraphicsState(); shift.concat(); paper.draw(paper.bounds); NSGraphicsContext.restoreGraphicsState()
    }
    film.unlockFocus()
    if let tiff = film.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: directory.appendingPathComponent("motion-confetti.png"))
    }
    DictationApp(LaunchConfig(projectRoot: "/unused", nodePath: "/unused", configPath: "/unused/config.json")).renderPreview(to: directory)
    print("Pill and window previews written.")
} else {
    do {
        let launch = try LaunchConfig.load(resources: Bundle.main.resourceURL!)
        let delegate = DictationApp(launch)
        let app = NSApplication.shared; app.delegate = delegate; app.run()
    } catch {
        fputs("Cannot read launch settings: \(error.localizedDescription)\n", stderr); exit(1)
    }
}
