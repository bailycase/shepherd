import SwiftUI

/// The iOS client's shortcuts. macOS keeps its rebindable defaults in KeybindingsStore.
public enum MobileShortcut: CaseIterable, Sendable {
    case search, newThread, newWindow, stop, rename, previousThread, nextThread
    case toggleSidebar, toggleSidePane, chooseModel, toggleTerminal
    case saveFile, alternateSend

    public var shortcut: KeyboardShortcut {
        switch self {
        case .search: KeyboardShortcut("k")
        case .newThread: KeyboardShortcut("n")
        case .newWindow: KeyboardShortcut("n", modifiers: [.command, .option])
        // iPadOS uses ⌘. to cancel and ⌘↑/↓ to move the insertion point.
        case .stop: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .rename: KeyboardShortcut("r")
        case .previousThread: KeyboardShortcut(.upArrow, modifiers: [.command, .control])
        case .nextThread: KeyboardShortcut(.downArrow, modifiers: [.command, .control])
        case .toggleSidebar: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .toggleSidePane: KeyboardShortcut("b", modifiers: [.command, .shift])
        case .chooseModel: KeyboardShortcut("m", modifiers: [.command, .shift])
        case .toggleTerminal: KeyboardShortcut("j")
        case .saveFile: KeyboardShortcut("s")
        case .alternateSend: KeyboardShortcut(.return)
        }
    }

    /// A letter shortcut as the Mac shows it ("⌘N", "⇧⌘S"): the sidebar's New thread row names its chord this way.
    public var display: String {
        let chord = shortcut
        let modifiers = [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { chord.modifiers.contains($0.0) }.map(\.1).joined()
        return modifiers + String(chord.key.character).uppercased()
    }
}
