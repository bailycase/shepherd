import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// What ↩ means in a multi-line field whose Return sends, saves or chooses (the composers, the
/// queue's editor, inline comments): ⇧↩ and ⌥↩ add a line, anything else is the surface's own.
///
/// A SwiftUI `TextField(axis: .vertical)` on the Mac is a field editor, and a field editor
/// answers ↩ and ⇧↩ (`insertNewline:`, which AppKit's key bindings give both) by ending the
/// edit, never by adding a line; only ⌥↩ (`insertNewlineIgnoringFieldEditor:`) does. So a handler
/// that returns `.ignored` for ⇧↩ leaves the system nothing that inserts a newline. The handler
/// adds the line itself (`lineBreak(for:)`), in the field editor, so the caret, the selection and
/// undo behave as the system's own insertion does.
public enum NWReturnKey {
    public enum Action: Equatable, Sendable {
        /// ⇧↩ or ⌥↩: a line break at the caret, replacing any selection. Never a send or a save.
        case lineBreak
        /// ↩, or a chord the surface reads itself (⌘↩, ⌃↩): the surface's own action.
        case submit
        /// Not the surface's to take: an input method is composing (↩ commits its text), or ⇧ or
        /// ⌥ is held with ⌘ or ⌃, a chord that belongs to someone else.
        case system
    }

    /// What a Return press with `modifiers` does. `composing` is whether the field has marked
    /// text (an input method is mid-composition).
    public static func action(modifiers: EventModifiers, composing: Bool = false) -> Action {
        if composing { return .system }
        let adds = !modifiers.isDisjoint(with: [.shift, .option])
        let owned = !modifiers.isDisjoint(with: [.command, .control])
        if !adds { return .submit }
        return owned ? .system : .lineBreak
    }

    /// For the `.onKeyPress(.return)` of a field that submits on ↩: nil when the press is the
    /// field's to submit; `.handled` once the line break is in; `.ignored` when the press is the
    /// system's, or the break cannot be made here (iOS, where the system adds the line itself).
    @MainActor
    public static func lineBreak(for press: KeyPress) -> KeyPress.Result? {
        #if canImport(AppKit)
        switch action(modifiers: press.modifiers, composing: isComposing) {
        case .submit: return nil
        case .system: return .ignored
        case .lineBreak: return insertLineBreak() ? .handled : .ignored
        }
        #else
        action(modifiers: press.modifiers) == .submit ? nil : .ignored
        #endif
    }
}

#if canImport(AppKit)
extension NWReturnKey {
    /// The text view holding the keyboard in the key window: the field editor of the field a key
    /// press reached.
    @MainActor
    public static var keyEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    /// An input method has marked text in the field being typed in.
    @MainActor
    public static var isComposing: Bool { keyEditor?.hasMarkedText() ?? false }

    /// Adds a line break to the field being typed in; false when there is none to add it to.
    @MainActor
    @discardableResult
    public static func insertLineBreak() -> Bool {
        keyEditor.map(insertLineBreak(in:)) ?? false
    }

    /// Adds a line break to `editor` at its caret, in place of a selection, through its own text
    /// system (so its delegate, the bound text, the caret and undo all follow). False, with
    /// nothing added, while the editor is read-only or an input method has marked text in it.
    @MainActor
    @discardableResult
    public static func insertLineBreak(in editor: NSTextView) -> Bool {
        guard editor.isEditable, !editor.hasMarkedText() else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
}
#endif
