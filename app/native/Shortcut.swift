import AppKit

// Modifier-only shortcut logic, kept free of event plumbing so the self-test can drive it.
enum ChordInput { case exact, more, less, otherKey, timer }
enum ChordAction { case arm, begin, finish, cancelQuietly, beginHandsFree }
struct ChordTracker {
    enum State: Equatable { case idle, arming(since: TimeInterval), holding, blocked, handsFree(armed: Bool) }
    // The chord also starts other shortcuts, so recording waits until it has been held alone.
    static let armDelay = 0.2, doubleTapWindow = 0.5
    private(set) var state = State.idle
    private var lastTap: TimeInterval?
    mutating func handle(_ input: ChordInput, at time: TimeInterval) -> ChordAction? {
        switch (state, input) {
        case (.idle, .exact):
            if let tap = lastTap, time - tap <= Self.doubleTapWindow { lastTap = nil; state = .handsFree(armed: false); return .beginHandsFree }
            lastTap = nil; state = .arming(since: time); return .arm
        case (.idle, .more): state = .blocked
        case (.arming(let since), .timer): if time - since >= Self.armDelay - 0.01 { state = .holding; return .begin }
        case (.arming, .less): state = .idle; lastTap = time
        case (.arming, .more), (.arming, .otherKey): state = .blocked
        case (.holding, .less): state = .idle; return .finish
        case (.holding, .more), (.holding, .otherKey): state = .blocked; return .cancelQuietly
        case (.blocked, .less): state = .idle
        case (.handsFree(armed: false), .less): state = .handsFree(armed: true)
        // The second tap turned into a longer shortcut before it was released.
        case (.handsFree(armed: false), .more), (.handsFree(armed: false), .otherKey): state = .blocked; return .cancelQuietly
        case (.handsFree(armed: true), .exact): state = .blocked; return .finish
        default: break
        }
        return nil
    }
    // Recording was latched from a button, so the next press of the chord finishes it.
    mutating func latchedElsewhere() { if state == .idle { state = .handsFree(armed: true) } }
    // The dictation ended some other way: Escape, a button, the time limit or a refusal.
    mutating func sessionEnded(chordDown: Bool) {
        switch state {
        case .holding, .handsFree: state = chordDown ? .blocked : .idle
        default: break
        }
    }
}
func parseChord(_ value: String?) -> (flags: NSEvent.ModifierFlags, words: String, symbols: String, keycaps: [String]) {
    let known: [(name: String, flag: NSEvent.ModifierFlags, word: String, symbol: String)] = [("control", .control, "Control", "⌃"), ("option", .option, "Option", "⌥"), ("shift", .shift, "Shift", "⇧"), ("command", .command, "Command", "⌘")]
    let wanted = Set((value ?? "").lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
    let picked = known.filter { wanted.contains($0.name) }
    guard picked.count == 2 && wanted.count == 2 else { return (.function, "Fn", "fn", ["fn"]) }
    return (picked.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }, picked.map(\.word).joined(separator: " + "), picked.map(\.symbol).joined(), picked.map(\.symbol))
}
