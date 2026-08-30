import Foundation
import AppKit
import SwiftUI

/// The app shortcuts a user may rebind. Fixed chords (⌘1–9 agent selection,
/// hold-⌘ badges, ⌘, Settings, ⏎/⎋ in sheets) are deliberately not here:
/// they are structural conventions, not preferences.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case newAgent, newAgentOptions, newSpace, renameAgent, newShell
    /// The digit row 1–9 selects shells with this chord's modifiers (the
    /// recorded digit is representative; all nine follow). ⌘1–9 stays fixed
    /// for agents, so shell digits use a different modifier combination.
    case shellDigits
    case commandPalette, nextAgent, previousAgent
    case splitVertical, splitHorizontal, closePane, deleteAgent
    case focusNextPane, focusPreviousPane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newAgent: return "New Agent in Current Checkout"
        case .newAgentOptions: return "New Agent with Options…"
        case .newSpace: return "New Space…"
        case .renameAgent: return "Rename Agent…"
        case .newShell: return "New Shell"
        case .shellDigits: return "Select Shell 1–9"
        case .commandPalette: return "Command Palette"
        case .nextAgent: return "Next Agent"
        case .previousAgent: return "Previous Agent"
        case .splitVertical: return "Split Vertically"
        case .splitHorizontal: return "Split Horizontally"
        case .closePane: return "Close Pane"
        case .deleteAgent: return "Delete Agent"
        case .focusNextPane: return "Focus Next Pane"
        case .focusPreviousPane: return "Focus Previous Pane"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .newAgent: return KeyChord(key: "n", command: true)
        case .newAgentOptions: return KeyChord(key: "t", command: true, shift: true)
        case .newSpace: return KeyChord(key: "n", command: true, shift: true)
        case .renameAgent: return KeyChord(key: "r", command: true)
        case .newShell: return KeyChord(key: "t", command: true)
        case .shellDigits: return KeyChord(key: "1", control: true)
        case .commandPalette: return KeyChord(key: "k", command: true)
        case .nextAgent: return KeyChord(key: "down", command: true)
        case .previousAgent: return KeyChord(key: "up", command: true)
        case .splitVertical: return KeyChord(key: "d", command: true)
        case .splitHorizontal: return KeyChord(key: "d", command: true, shift: true)
        case .closePane: return KeyChord(key: "w", command: true)
        case .deleteAgent: return KeyChord(key: "w", command: true, shift: true)
        case .focusNextPane: return KeyChord(key: "right", command: true, option: true)
        case .focusPreviousPane: return KeyChord(key: "left", command: true, option: true)
        }
    }
}

/// One key plus modifiers, in every representation the app needs: SwiftUI
/// `KeyboardShortcut` (menus), display string (hints and keycaps), and
/// ghostty keybind syntax (per-surface unbinds so the terminal lets the
/// chord through). `key` is a canonical token: a single lowercase character,
/// or `left`/`right`/`up`/`down`.
struct KeyChord: Codable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    // MARK: Display (⌃⌥⇧⌘ in Apple's canonical order)

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + Self.displayKey(key)
    }

    static func displayKey(_ key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    // MARK: SwiftUI

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default: return KeyEquivalent(key.first ?? " ")
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    // MARK: Ghostty

    var ghosttyChord: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(Self.ghosttyKey(key))
        return parts.joined(separator: "+")
    }

    static func ghosttyKey(_ key: String) -> String {
        switch key {
        case "[": return "left_bracket"
        case "]": return "right_bracket"
        case ",": return "comma"
        case ".": return "period"
        case "/": return "slash"
        case ";": return "semicolon"
        case "'": return "apostrophe"
        case "\\": return "backslash"
        case "-": return "minus"
        case "=": return "equal"
        case "`": return "grave_accent"
        default: return key // letters and left/right/up/down pass through
        }
    }

    // MARK: Capture

    /// Chord from a recorder key event; nil for keys the app does not accept
    /// (space, function keys, tab…).
    init?(event: NSEvent) {
        guard let token = Self.token(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            return nil
        }
        let flags = event.modifierFlags
        self.init(
            key: token,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    /// The four app-relevant modifiers as NSEvent flags. Shared by badge
    /// reveal and the navigation keyDown fast path so the two can never
    /// disagree about what a chord's modifiers mean.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    /// Digit-row value for a key code, layout-independent — the digit
    /// families (⌘1–9, shell digits, ⌃⇧1–9) must match by physical key
    /// because `charactersIgnoringModifiers` does not ignore shift (⇧1
    /// reads "!"), mirroring ghostty's `physical:` unbind spellings.
    static func digit(keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// Pure token mapping, separated from NSEvent for testability.
    static func token(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: break
        }
        guard let ch = characters?.lowercased().first,
              "abcdefghijklmnopqrstuvwxyz0123456789[],./;'\\-=`".contains(ch) else {
            return nil
        }
        return String(ch)
    }
}

/// User keybindings: defaults from `ShortcutAction`, overrides persisted in
/// UserDefaults. Menus, hints, and per-surface ghostty unbinds all read from
/// here, so a custom chord is wired everywhere or nowhere.
@MainActor
final class KeybindingsStore: ObservableObject {
    static let shared = KeybindingsStore()
    static let defaultsKey = "shepherd.keybindings"

    @Published private(set) var overrides: [ShortcutAction: KeyChord]

    /// True while the Settings shortcut recorder is capturing. The view
    /// model's navigation keyDown fast path checks this and stands down so
    /// the recorder can capture chords that would otherwise be consumed.
    var isRecording = false

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        if let data = store.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data) {
            overrides = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, chord in
                ShortcutAction(rawValue: key).map { ($0, chord) }
            })
        } else {
            overrides = [:]
        }
    }

    func chord(for action: ShortcutAction) -> KeyChord {
        overrides[action] ?? action.defaultChord
    }

    func display(_ action: ShortcutAction) -> String {
        // The recorded digit stands for the whole row.
        if action == .shellDigits {
            var chord = chord(for: action)
            chord.key = "1–9"
            return chord.display
        }
        return chord(for: action).display
    }

    /// Modifiers applied to the digit row for shell selection.
    var shellDigitModifiers: EventModifiers { chord(for: .shellDigits).eventModifiers }
    func shortcut(_ action: ShortcutAction) -> KeyboardShortcut { chord(for: action).shortcut }
    func isDefault(_ action: ShortcutAction) -> Bool { overrides[action] == nil }

    // MARK: Assignment

    enum AssignmentError: Error, Equatable, CustomStringConvertible {
        /// Without ⌘ a chord would be a plain terminal keystroke; every
        /// unbound chord must stay out of the typing alphabet.
        case missingCommand
        /// ⌘1–9 (agent selection), ⌘, (Settings), and the plain-⌘ system and
        /// terminal chords (quit/hide, copy/paste/undo/select-all).
        case reservedChord
        case conflict(ShortcutAction)

        var description: String {
            switch self {
            case .missingCommand: return "shortcuts must include ⌘ — plain keys belong to the terminal"
            case .reservedChord: return "that chord is reserved (⌘1–9, ⌘, and system/terminal chords like ⌘Q ⌘C ⌘V)"
            case .conflict(let other): return "already used by “\(other.title)”"
            }
        }
    }

    /// Plain-⌘ chords that must never be taken from the system or ghostty.
    private static let reservedPlainCommandKeys: Set<String> = [
        "q", "h", "m", ",", "c", "v", "x", "a", "z",
    ]

    func validate(_ chord: KeyChord, for action: ShortcutAction) -> AssignmentError? {
        if action == .shellDigits {
            // Any modified digit works except plain ⌘digits (agents) and
            // ⌃⇧digits (machine jumps). A bare digit remains terminal input.
            guard let first = chord.key.first, first.isNumber,
                  chord.shift || chord.option || chord.control else { return .reservedChord }
            if chord.control && chord.shift && !chord.command && !chord.option {
                return .reservedChord
            }
            return nil
        }
        guard chord.command else { return .missingCommand }
        if let first = chord.key.first, first.isNumber { return .reservedChord }
        if !chord.shift && !chord.option && !chord.control,
           Self.reservedPlainCommandKeys.contains(chord.key) {
            return .reservedChord
        }
        for other in ShortcutAction.allCases where other != action {
            if self.chord(for: other) == chord { return .conflict(other) }
        }
        return nil
    }

    /// Applies `chord` to `action`; returns the rejection reason, or nil on
    /// success. Assigning an action its own default clears the override.
    @discardableResult
    func assign(_ chord: KeyChord, to action: ShortcutAction) -> AssignmentError? {
        if let error = validate(chord, for: action) { return error }
        if chord == action.defaultChord {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = chord
        }
        persist()
        return nil
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        persist()
    }

    func resetAll() {
        overrides = [:]
        store.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if raw.isEmpty {
            store.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(raw) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Ghostty `keybind = <chord>=unbind` entries for every custom chord, so
    /// a focused terminal lets the rebound shortcut reach the app. Default
    /// chords are already in TerminalSurfaceKit's own unbind list.
    var customGhosttyUnbinds: [String] {
        var chords = overrides.map { action, chord -> [String] in
            guard action == .shellDigits else { return [chord.ghosttyChord] }
            // The recorded digit stands for the whole row: unbind all nine
            // (both unicode and physical spellings, like the built-ins).
            let names = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            var mods: [String] = []
            if chord.control { mods.append("ctrl") }
            if chord.option { mods.append("alt") }
            if chord.shift { mods.append("shift") }
            if chord.command { mods.append("cmd") }
            let prefix = mods.joined(separator: "+")
            return names.flatMap { ["\(prefix)+\($0)", "\(prefix)+physical:\($0)"] }
        }.flatMap { $0 }
        chords.sort()
        return chords
    }
}
