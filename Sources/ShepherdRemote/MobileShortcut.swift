import SwiftUI

/// The iOS client's shortcuts. macOS keeps its rebindable defaults in KeybindingsStore.
public enum MobileShortcut: CaseIterable, Sendable {
    case search, newThread, stop, rename, previousThread, nextThread
    case toggleSidebar, toggleSidePane, chooseModel, toggleTerminal
    case saveFile, alternateSend

    public var shortcut: KeyboardShortcut {
        switch self {
        case .search: KeyboardShortcut("k")
        case .newThread: KeyboardShortcut("n")
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
}
