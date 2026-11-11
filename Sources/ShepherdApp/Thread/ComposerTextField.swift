import AppKit
import SwiftUI
import ShepherdRemote
import ShepherdUI

/// The three image-capable composers own their field editor. SwiftUI's plain field editor
/// consumes native Paste before `onPasteCommand` can receive an image. Keep AppKit's editing,
/// undo and text paste; only image/file paste and the composer's explicit keys are different.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    var caret: ComposerCaret?
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
            switch SHReturnKey.action(modifiers: modifiers, composing: composing) {
            case .submit: nil
            case .system: .ignored
            case .lineBreak: SHReturnKey.insertLineBreak(in: editor) ? .handled : .ignored
            }
        }
    }

    init(text: Binding<String>, caret: ComposerCaret? = nil, placeholder: String,
         label: String, focus: Binding<Bool>, attach: @escaping ([NSItemProvider]) -> Void,
         lineSpacing: CGFloat = 0) {
        _text = text
        self.caret = caret
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
        Self.configureLayout(field)
        field.focusRingType = .none
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

    /// What sets a field's size: the field and the one that measures it for the editing path are alike in it.
    /// The field's cell is set first.
    static func configureLayout(_ field: NSTextField) {
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = SHComposerMetrics.fieldMaxLines
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.usesSingleLineMode = false
    }

    func updateNSView(_ field: Field, context: Context) {
        // Observation can render synchronously from willSet, before the binding holds the
        // native edit. Do not write that old snapshot back into the editor publishing it.
        guard !field.publishingEdit else { return }
        context.coordinator.parent = self
        field.updating = true
        defer { field.updating = false }
        field.updateStyle(Style(appearance: appearance, scale: ThemeStore.shared.textScale,
                                text: Color.sh.textPrimary, placeholderColor: Color.sh.textTertiary,
                                caret: Color.sh.lantern, placeholder: placeholder, lineSpacing: lineSpacing))
        if field.isEnabled != enabled { field.isEnabled = enabled }
        if field.accessibilityLabel() != label { field.setAccessibilityLabel(label) }
        field.editor.attach = attach
        field.editor.keys = keys
        let replaced: Bool
        if field.trustsPublished {
            replaced = text != field.published
        } else {
            let shown = field.draftText
            replaced = shown != text
            if !replaced { field.publish(shown) }
        }
        if replaced {
            field.setDraft(text)
            field.invalidateSize()
            if field.currentEditor() != nil {
                field.editor.setSelectedRange(NSRange(location: field.editor.textStorage?.length ?? 0, length: 0))
                context.coordinator.readSelection(field)
            } else {
                // The offsets belong to the draft this one replaced.
                caret?.range = nil
            }
        } else if field.chipsStyle != field.styleVersion, text.contains(ComposerSkillToken.prefix) {
            // A new appearance or text size redraws the chips, keeping the caret where it is.
            let selected = field.editor.selectedRange()
            field.setDraft(text)
            if field.currentEditor() != nil { field.editor.setSelectedRange(selected) }
        }
        if !replaced, let range = caret?.range {
            let native = field.editorRange(range)
            if field.currentEditor() != nil, field.editor.selectedRange() != native { field.editor.setSelectedRange(native) }
        }
        if field.wantsFocus != focus.wrappedValue {
            field.wantsFocus = focus.wrappedValue
            field.applyFocus()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        field.preferredMaxLayoutWidth = width
        let height: CGFloat
        if field.currentEditor() != nil {
            // The cell holds what editing began with: the editor's words are the field's.
            height = field.fittingHeight(width: width)
        } else {
            let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            height = field.cell?.cellSize(forBounds: bounds).height ?? field.intrinsicContentSize.height
        }
        field.answered(height, forWidth: width)
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }
        func readText(_ field: Field) {
            field.publishingEdit = true
            defer { field.publishingEdit = false }
            // Not editing (an assistive client set AXValue): the cell holds the text, not the editor.
            let text = field.draftText
            field.publish(text)
            parent.text = text
            field.edited()
            readSelection(field)
        }
        func readSelection(_ field: Field) {
            parent.caret?.range = field.draftRange(field.editor.selectedRange())
        }
    }

    struct Style: Equatable {
        var appearance: ColorScheme
        var scale: CGFloat
        var text: Color
        var placeholderColor: Color
        var caret: Color
        var placeholder: String
        var lineSpacing: CGFloat
    }

    final class Field: NSTextField {
        let editor = Editor()
        private var appliedStyle: Style?
        private var pendingStyle: Style?

        /// The words the draft last spelled out of this field, and how often they changed.
        private(set) var published = ""
        private(set) var revision = 0
        /// Character edits the editor's storage has processed, and how many it had when `published` was set.
        private var storageEdits = 0
        private var publishedEdits = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(storageProcessed(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func storageProcessed(_ note: Notification) {
            if let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) { storageEdits &+= 1 }
        }

        /// The heights answered to `sizeThatFits`, and the editing heights measured for one set of words and style.
        private var answers = Heights()
        private var measured: (styleVersion: Int, revision: Int, heights: Heights)?
        /// Characters the field's measures have laid out; a test zeroes it before an edit.
        var lastMeasuredCharacters = 0

        /// A cell alike the field's in everything that sets its size, holding the sample being measured. It is
        /// never in a window.
        private lazy var measurer: NSTextField = {
            let measurer = NSTextField(frame: .zero)
            measurer.cell = Cell(textCell: "")
            ComposerTextField.configureLayout(measurer)
            return measurer
        }()

        func publish(_ text: String) {
            if text != published { revision &+= 1 }
            published = text
            publishedEdits = storageEdits
        }

        /// The editor holds `published` while it has had no character edit since: only the field's own edits
        /// changed it. Anything else (AppKit loading the cell as editing begins, undo, a service, a programmatic set)
        /// breaks this, and the update compares what the field shows.
        var trustsPublished: Bool { currentEditor() != nil && publishedEdits == storageEdits }

        func updateStyle(_ style: Style) {
            pendingStyle = style
            applyStyle()
        }

        private func applyStyle() {
            guard let style = pendingStyle, style != appliedStyle,
                  appliedStyle == nil || (window != nil && !isHiddenOrHasHiddenAncestor) else { return }
            SHFonts.register()
            font = NSFont(name: "\(SHFonts.sansFamily)-Regular", size: SHTextStyle.body.size * style.scale)
                ?? .systemFont(ofSize: SHTextStyle.body.size * style.scale)
            textColor = NSColor(style.text)
            placeholderAttributedString = NSAttributedString(string: style.placeholder, attributes: [
                .font: font!, .foregroundColor: NSColor(style.placeholderColor)
            ])
            editor.insertionPointColor = NSColor(style.caret)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            editor.defaultParagraphStyle = paragraph
            appliedStyle = style
            styleVersion &+= 1
            invalidateSize()
        }

        func invalidateSize() {
            SHRenderProbe.tick("layout.composerFieldInvalidated")
            invalidateIntrinsicContentSize()
        }

        func answered(_ height: CGFloat, forWidth width: CGFloat) { answers[width] = height }

        /// The field's words changed. Its size is asked again only when their height is not the one it last answered:
        /// a keystroke that keeps the height changes nothing SwiftUI laid out.
        func edited() {
            // The width SwiftUI proposed: the frame is wider than the alignment rect the field is placed by, and the
            // rect is on whole points where the proposal need not be.
            let placed = alignmentRect(forFrame: frame).width
            if currentEditor() != nil, placed > 0, let answer = answers.nearest(to: placed, within: 1),
               answer.height == fittingHeight(width: answer.width) { return }
            invalidateSize()
        }

        /// The height the words being edited need at `width`, as the cell would measure them whole, up to the
        /// field's lines. The sample laid out is the start of the words, only as long as it must be to see whether
        /// a line comes past the last one shown. Cached, so each edit is measured once.
        func fittingHeight(width: CGFloat) -> CGFloat {
            let words: String
            if trustsPublished {
                words = published
            } else {
                words = draftText
                publish(words)
            }
            if let measured, measured.styleVersion == styleVersion, measured.revision == revision, let height = measured.heights[width] {
                return height
            }
            let lines = SHComposerMetrics.fieldMaxLines
            let height = SHComposerFit.height { count in
                let sample = words.prefix(count)
                show(sample)
                let shown = cellHeight(of: sample, lines: lines, width: width)
                if sample.endIndex == words.endIndex { return (shown, true, false) }
                // A sample with a line past the last shown has the words' own first lines, and the cell stops at those.
                return (shown, false, cellHeight(of: sample, lines: lines + 1, width: width) > shown)
            }
            if measured?.styleVersion != styleVersion || measured?.revision != revision { measured = (styleVersion, revision, Heights()) }
            measured?.heights[width] = height
            return height
        }

        /// Puts `sample` in the measurer as the field holds the words: with chips only if `setDraft` showed chips.
        private func show(_ sample: Substring) {
            if measurer.font != font { measurer.font = font }
            if measurer.placeholderAttributedString !== placeholderAttributedString {
                measurer.placeholderAttributedString = placeholderAttributedString
            }
            let text = String(sample)
            guard showsChips else {
                measurer.stringValue = text
                return
            }
            let chips = text.contains(ComposerSkillToken.prefix)
                ? SHSkillChips.attributed(text, tokens: ComposerSkillToken.ranges(in: text), name: ComposerSkillToken.name,
                                          attributes: draftAttributes) : nil
            measurer.attributedStringValue = chips ?? NSAttributedString(string: text, attributes: draftAttributes)
        }

        private func cellHeight(of sample: Substring, lines: Int, width: CGFloat) -> CGFloat {
            SHRenderProbe.tick("layout.composerFieldMeasured")
            if SHRenderProbe.isRecording { lastMeasuredCharacters += sample.count }
            measurer.maximumNumberOfLines = lines
            return measurer.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        }

        /// Whether `setDraft` last showed the words with their skills as chips. Words typed or pasted in are plain text.
        private(set) var showsChips = false
        /// Bumped with each style applied; `chipsStyle` is the one the chips were drawn in.
        private(set) var styleVersion = 0
        private(set) var chipsStyle = 0
        /// What the field holds, as the draft spells it: each skill chip as its "/skill:name".
        var draftText: String {
            SHRenderProbe.tick("text.composerFieldCopied")
            if currentEditor() != nil, let storage = editor.textStorage { return SHSkillChips.text(of: storage) }
            return SHSkillChips.text(of: attributedStringValue)
        }
        private var shown: NSAttributedString { currentEditor() != nil ? editor.textStorage ?? attributedStringValue : attributedStringValue }
        func draftRange(_ range: NSRange) -> NSRange { SHSkillChips.draftRange(range, in: shown) }
        func editorRange(_ range: NSRange) -> NSRange { SHSkillChips.fieldRange(range, in: shown) }

        /// What the words are shown in when they hold skill chips.
        private var draftAttributes: [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: SHTextStyle.body.size)]
            if let textColor { attributes[.foregroundColor] = textColor }
            if let paragraph = editor.defaultParagraphStyle { attributes[.paragraphStyle] = paragraph }
            return attributes
        }

        /// Shows `text`, its skills as inline chips.
        func setDraft(_ text: String) {
            chipsStyle = styleVersion
            defer { publish(text) }
            guard let chips = SHSkillChips.attributed(text, tokens: ComposerSkillToken.ranges(in: text), name: ComposerSkillToken.name,
                                                      attributes: draftAttributes) else {
                showsChips = false
                stringValue = text
                return
            }
            showsChips = true
            attributedStringValue = chips
            if currentEditor() != nil { editor.textStorage?.setAttributedString(chips) }
        }

        override func viewDidUnhide() { super.viewDidUnhide(); applyStyle() }
        var updating = false
        var publishingEdit = false
        var wantsFocus = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyStyle(); applyFocus() }
        /// An assistive client (dictation, AX scripting) writing AXValue bypasses the field editor,
        /// so nothing fires `didChangeText`; publish the new text ourselves.
        override func setAccessibilityValue(_ value: Any?) {
            super.setAccessibilityValue(value)
            if currentEditor() == nil, let text = value as? String, stringValue != text { stringValue = text }
            editor.changedText?()
        }
        /// AXConfirm on the field is the Return key: the composer's handler sends or chooses.
        override func accessibilityPerformConfirm() -> Bool {
            guard isEnabled, let handler = editor.keys[.return] else { return super.accessibilityPerformConfirm() }
            return handler(Press(modifiers: [], editor: editor)) == .handled
        }
        func applyFocus() {
            guard let window else { return }
            if wantsFocus, currentEditor() == nil { window.makeFirstResponder(self) }
            else if !wantsFocus, window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
    }

    /// A height for each of the last few widths a field was asked at.
    struct Heights {
        private var entries: [(width: CGFloat, height: CGFloat)] = []
        /// The answer for the width nearest `width`, if one is within `tolerance` of it.
        func nearest(to width: CGFloat, within tolerance: CGFloat) -> (width: CGFloat, height: CGFloat)? {
            guard let best = entries.min(by: { abs($0.width - width) < abs($1.width - width) }),
                  abs(best.width - width) < tolerance else { return nil }
            return best
        }
        subscript(width: CGFloat) -> CGFloat? {
            get { entries.first { $0.width == width }?.height }
            set {
                entries.removeAll { $0.width == width }
                guard let newValue else { return }
                entries.append((width, newValue))
                if entries.count > 4 { entries.removeFirst() }
            }
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
            super.didChangeText()
            changedText?()
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
            guard isEditable else { return }
            let board = pasteboard()
            let providers = AppImageDrop.providers(from: board)
            if !providers.isEmpty, let attach { attach(providers); return }
            guard let type = preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil) else {
                NSSound.beep()
                return
            }
            breakUndoCoalescing()
            // The untyped reader is the Services entry point, not the selected-text paste path.
            if !super.readSelection(from: board, type: type) { NSSound.beep() }
            breakUndoCoalescing()
        }
        /// Dropped files and images attach like pasted ones instead of inserting their paths.
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let providers = AppImageDrop.providers(from: sender.draggingPasteboard)
            if isEditable, !providers.isEmpty, let attach { attach(providers); return true }
            return super.performDragOperation(sender)
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
