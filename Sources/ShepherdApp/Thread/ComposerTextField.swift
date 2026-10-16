import AppKit
import SwiftUI
import ShepherdUI

/// The three image-capable composers own their field editor. SwiftUI's plain field editor
/// consumes native Paste before `onPasteCommand` can receive an image. Keep AppKit's editing,
/// undo and text paste; only image/file paste and the composer's explicit keys are different.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    var selection: Binding<TextSelection?> = .constant(nil)
    let placeholder: String
    let label: String
    let focus: Binding<Bool>
    let attach: ([NSItemProvider]) -> Void
    var lineSpacing: CGFloat = 0
    private var keys: [KeyEquivalent: (Press) -> KeyPress.Result] = [:]
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var appearance

    @MainActor struct Press {
        let modifiers: EventModifiers
        let editor: NSTextView
        var composing: Bool { editor.hasMarkedText() }
        func lineBreak() -> KeyPress.Result? {
            switch NWReturnKey.action(modifiers: modifiers, composing: composing) {
            case .submit: nil
            case .system: .ignored
            case .lineBreak: NWReturnKey.insertLineBreak(in: editor) ? .handled : .ignored
            }
        }
    }

    init(text: Binding<String>, selection: Binding<TextSelection?> = .constant(nil), placeholder: String,
         label: String, focus: Binding<Bool>, attach: @escaping ([NSItemProvider]) -> Void,
         lineSpacing: CGFloat = 0) {
        _text = text
        self.selection = selection
        self.placeholder = placeholder
        self.label = label
        self.focus = focus
        self.attach = attach
        self.lineSpacing = lineSpacing
    }

    func onComposerKey(_ key: KeyEquivalent, perform: @escaping (Press) -> KeyPress.Result) -> Self {
        var copy = self
        copy.keys[key] = perform
        return copy
    }

    func onComposerKey(_ key: KeyEquivalent, perform: @escaping () -> KeyPress.Result) -> Self {
        onComposerKey(key) { _ in perform() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.cell = Cell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = NWComposerMetrics.fieldMaxLines
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.usesSingleLineMode = false
        field.cell?.allowsUndo = true
        field.editor.allowsUndo = true
        field.editor.observeUndo()
        field.editor.isFieldEditor = true
        field.editor.isRichText = false
        field.editor.importsGraphics = false
        field.editor.isAutomaticSpellingCorrectionEnabled = false
        field.editor.isAutomaticQuoteSubstitutionEnabled = false
        field.editor.isAutomaticDashSubstitutionEnabled = false
        field.editor.changedText = { [weak field, weak coordinator = context.coordinator] in
            guard let field, !field.updating else { return }
            coordinator?.readText(field)
        }
        field.editor.changedFocus = { [weak field, weak coordinator = context.coordinator] focused in
            guard let field, !field.updating, let coordinator else { return }
            // Native focus is not a new request: do not replay it on the next SwiftUI update.
            field.wantsFocus = focused
            if coordinator.parent.focus.wrappedValue != focused { coordinator.parent.focus.wrappedValue = focused }
        }
        field.editor.changedSelection = { [weak field, weak coordinator = context.coordinator] in
            guard let field, !field.updating else { return }
            coordinator?.readSelection(field)
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.updating = true
        field.editor.trace?("update begin incomingText=\(String(reflecting: text)), focus=\(focus.wrappedValue)")
        defer { field.updating = false; field.editor.trace?("update end") }
        // NSControl's getter validates pending editor text into the cell. Do this before
        // style setters can refresh the editor from a stale cell value (macOS 26).
        field.editor.trace?("update before existing stringValue read")
        let replaced = field.stringValue != text
        field.editor.trace?("update after existing stringValue read, replaced=\(replaced)")
        let _ = appearance
        NWFonts.register()
        field.editor.trace?("update before font")
        field.font = NSFont(name: "\(NWFonts.sansFamily)-Regular", size: NWTextStyle.body.size * ThemeStore.shared.textScale)
            ?? .systemFont(ofSize: NWTextStyle.body.size * ThemeStore.shared.textScale)
        field.editor.trace?("update after font")
        field.editor.trace?("update before text color")
        field.textColor = NSColor(Color.nw.textPrimary)
        field.editor.trace?("update after text color")
        field.editor.trace?("update before placeholder")
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: field.font!, .foregroundColor: NSColor(Color.nw.textTertiary)
        ])
        field.editor.trace?("update after placeholder")
        field.editor.trace?("update before enabled")
        field.isEnabled = enabled
        field.editor.trace?("update after enabled")
        field.editor.trace?("update before accessibility label")
        field.setAccessibilityLabel(label)
        field.editor.trace?("update after accessibility label")
        field.editor.trace?("update before caret color")
        field.editor.insertionPointColor = NSColor(Color.nw.lantern)
        field.editor.trace?("update after caret color")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        field.editor.trace?("update before paragraph")
        field.editor.defaultParagraphStyle = paragraph
        field.editor.trace?("update after paragraph")
        field.editor.attach = attach
        field.editor.keys = keys
        if replaced {
            field.editor.trace?("update before stringValue assignment")
            field.stringValue = text
            field.editor.trace?("update after stringValue assignment")
            field.invalidateIntrinsicContentSize()
            field.editor.trace?("update after invalidation")
            if field.currentEditor() != nil {
                field.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                context.coordinator.readSelection(field)
            }
        }
        if !replaced, let range = selection.wrappedValue, case .selection(let indices) = range.indices,
           indices.upperBound <= text.endIndex {
            let native = NSRange(indices, in: text)
            if field.currentEditor() != nil, field.editor.selectedRange() != native { field.editor.setSelectedRange(native) }
        }
        if field.wantsFocus != focus.wrappedValue {
            field.wantsFocus = focus.wrappedValue
            field.applyFocus()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        field.editor.trace?("measure before width")
        field.preferredMaxLayoutWidth = width
        field.editor.trace?("measure after width")
        let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = field.cell?.cellSize(forBounds: bounds).height ?? field.intrinsicContentSize.height
        field.editor.trace?("measure after cellSize")
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }
        func readText(_ field: Field) {
            // Commit pending editor text to the cell before publishing or invalidating layout:
            // native measurement can run before updateNSView and otherwise use the old cell.
            field.editor.trace?("readText before validation")
            field.validateEditing()
            field.editor.trace?("readText after validation")
            parent.text = field.editor.string
            field.editor.trace?("readText after binding publication")
            field.invalidateIntrinsicContentSize()
            field.editor.trace?("readText after invalidation")
            readSelection(field)
            field.editor.trace?("readText after selection")
        }
        func readSelection(_ field: Field) {
            guard let range = Range(field.editor.selectedRange(), in: parent.text) else { return }
            parent.selection.wrappedValue = TextSelection(range: range)
        }
    }

    final class Field: NSTextField {
        let editor = Editor()
        var updating = false
        var wantsFocus = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyFocus() }
        func applyFocus() {
            guard let window else { return }
            if wantsFocus, currentEditor() == nil { window.makeFirstResponder(self) }
            else if !wantsFocus, window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
    }

    final class Cell: NSTextFieldCell {
        override func fieldEditor(for controlView: NSView) -> NSTextView? { (controlView as? Field)?.editor }
    }

    final class Editor: NSTextView {
        private let edits = UndoManager()
        override var undoManager: UndoManager? { edits }
        func observeUndo() {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoChanged), name: name, object: edits)
            }
        }
        @objc private func undoChanged() { didChangeText() }
        deinit { NotificationCenter.default.removeObserver(self) }
        /// Temporary test-installed, passive lifecycle tracing; nil outside the regression test.
        var trace: ((String) -> Void)?
        var attach: (([NSItemProvider]) -> Void)?
        /// Tests supply a named pasteboard; native Paste otherwise uses the system clipboard.
        var pasteboard: () -> NSPasteboard = { .general }
        var keys: [KeyEquivalent: (Press) -> KeyPress.Result] = [:]
        var changedSelection: (() -> Void)?
        var changedText: (() -> Void)?
        var changedFocus: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { changedFocus?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { changedFocus?(false) }
            return accepted
        }
        override func didChangeText() {
            trace?("didChangeText before super")
            super.didChangeText()
            trace?("didChangeText after super, before callback")
            changedText?()
            trace?("didChangeText after callback")
        }
        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            changedSelection?()
        }
        override func keyDown(with event: NSEvent) {
            let key: KeyEquivalent? = switch event.keyCode {
            case 53: .escape
            case 51: .delete
            default: KeyChord(event: event)?.keyEquivalent
            }
            let flags = event.modifierFlags
            var modifiers: EventModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if !hasMarkedText(), let key, let handler = keys[key],
               handler(Press(modifiers: modifiers, editor: self)) == .handled { return }
            super.keyDown(with: event)
        }
        override func paste(_ sender: Any?) {
            trace?("paste entry")
            guard isEditable else { return }
            let board = pasteboard()
            let providers = AppImageDrop.providers(from: board)
            if !providers.isEmpty, let attach { attach(providers); return }
            guard let type = preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil) else {
                NSSound.beep()
                return
            }
            trace?("paste before first breakUndoCoalescing")
            breakUndoCoalescing()
            trace?("paste after first breakUndoCoalescing, before typed reader")
            // The untyped reader is the Services entry point, not the selected-text paste path.
            let accepted = super.readSelection(from: board, type: type)
            trace?("paste after typed reader accepted=\(accepted), before final breakUndoCoalescing")
            if !accepted { NSSound.beep() }
            breakUndoCoalescing()
            trace?("paste after final breakUndoCoalescing")
        }
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)) {
                return isEditable && pasteboard().availableType(from: readablePasteboardTypes) != nil
            }
            return super.validateUserInterfaceItem(item)
        }
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            super.readablePasteboardTypes + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
        }
    }
}
