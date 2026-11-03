import SwiftUI
import AppKit
import ShepherdUI
import ShepherdRemote

/// Settings ▸ Instructions' editor (SettingsInstructions): the file as plain Markdown in mono 12.5
/// on 21pt lines, a 34pt gutter of line numbers, light highlighting (`InstructionsText.highlight`:
/// heading marks `textTertiary` and words semibold `textPrimary`, bullets `lanternText`, code
/// spans `synString`, the rest `textSecondary`), and every line changed since the last save
/// tinted `lanternTint` across the editor.
struct InstructionsEditor: NSViewRepresentable {
    @Binding var text: String
    /// What is saved: lines that differ from it are tinted.
    let saved: String
    let accessibilityLabel: String
    var project = false
    var markdown = true
    /// A project editor without the gutter: text in the primary color on the board's 1.65 line
    /// (the subagent form's Instructions pane).
    var plain = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView(project: project, plain: plain)
        textView.delegate = context.coordinator
        textView.isEditable = context.environment.isEnabled
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.string = text
        textView.textStorage?.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.restyle(textView, saved: saved)
        return scroll
    }

    /// The configured text view. Writing Tools is off: its "compose" affordance for an empty
    /// view is a child window that outlived the editor and floated over later Settings pages.
    static func makeTextView(project: Bool, plain: Bool) -> InstructionsTextView {
        let textView = InstructionsTextView(usingTextLayoutManager: false)
        textView.writingToolsBehavior = .none
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.project = project
        textView.plain = plain
        textView.backgroundColor = NSColor(project ? Color.sh.projectEditorBackground : Color.sh.bgWindow)
        textView.insertionPointColor = NSColor(Color.sh.lantern)
        textView.textContainerInset = NSSize(width: 0, height: project ? AppLayout.projectEditorInset : AppLayout.instructionsEditorInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? InstructionsTextView else { return }
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isEditable = context.environment.isEnabled
        // Another file, a revert, or a save from elsewhere: the text changes under the editor.
        if textView.string != text {
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
        context.coordinator.restyle(textView, saved: saved)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: InstructionsEditor
        /// What the text view was last styled for: a render that changes none of it leaves the
        /// text alone (and an input method's marked text with it).
        private var styled: (text: String, scale: CGFloat, markdown: Bool)?
        /// Characters typed since the last styling (UTF-16, in the text as it is now): only their
        /// lines are styled again.
        private var edited: NSRange?
        /// The tint's diff: the text and saved version it was asked for, and the one in flight.
        private var diffed: (text: String, saved: String)?
        private(set) var diffing: Task<Void, Never>?
        /// Tint diffs run (tests).
        private(set) var diffRuns = 0

        /// `**bold**` in a project file: compiled once, not per line per keystroke.
        private static let bold = try! NSRegularExpression(pattern: "\\*\\*[^*]+\\*\\*")

        init(_ parent: InstructionsEditor) {
            self.parent = parent
        }

        /// Every change of characters (typing, paste, undo, an input method), in the text's new coordinates.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { noteEdit(editedRange, delta: delta, length: textStorage.length) }
        }

        func noteEdit(_ range: NSRange, delta: Int, length: Int) {
            guard var previous = edited else { edited = range; return }
            // An earlier pending range shifts with an edit before it.
            if range.location <= previous.location { previous.location = max(0, previous.location + delta) }
            let union = NSUnionRange(previous, range)
            let end = min(length, NSMaxRange(union))
            edited = NSRange(location: min(union.location, end), length: end - min(union.location, end))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? InstructionsTextView else { return }
            parent.text = textView.string
            restyle(textView, saved: parent.saved)
        }

        /// Styles what changed: the edited lines after typing, every line for another file or text
        /// size. While an input method is composing, styling waits for it to commit. The changed
        /// lines' tint is diffed off the main actor.
        func restyle(_ textView: InstructionsTextView, saved: String) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let scale = ThemeStore.shared.textScale
            let markdown = parent.markdown
            if !textView.hasMarkedText(), styled.map({ $0.text != text || $0.scale != scale || $0.markdown != markdown }) ?? true {
                let styles = InstructionsEditorStyles(scale: scale, project: parent.project, plain: parent.plain)
                let full = NSRange(location: 0, length: storage.length)
                // Only typing restyles part of the text; anything else (first styling, text size) restyles it all.
                let sameStyles = styled.map { $0.scale == scale && $0.markdown == markdown } ?? false
                let lines = sameStyles ? edited.map { Self.lineRange(of: $0, in: text as NSString) } ?? full : full
                styled = (text, scale, markdown)
                edited = nil
                style(storage, range: lines, styles: styles)
                textView.typingAttributes = styles.base
            }
            tint(textView, text: text, saved: saved)
        }

        /// The whole lines (split at "\n", as the gutter numbers them) that `range` touches.
        static func lineRange(of range: NSRange, in text: NSString) -> NSRange {
            let length = text.length
            let lower = min(range.location, length), upper = min(NSMaxRange(range), length)
            let before = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: lower))
            let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
            let after = text.range(of: "\n", range: NSRange(location: upper, length: length - upper))
            let end = after.location == NSNotFound ? length : after.location
            return NSRange(location: start, length: end - start)
        }

        private func style(_ storage: NSTextStorage, range: NSRange, styles: InstructionsEditorStyles) {
            let text = storage.string as NSString
            storage.beginEditing()
            storage.setAttributes(styles.base, range: range)
            var location = range.location
            for line in text.substring(with: range).components(separatedBy: "\n") {
                for span in parent.markdown ? InstructionsText.highlight(line: line) : [] {
                    let spanRange = NSRange(location: location + span.range.lowerBound, length: span.range.count)
                    guard NSMaxRange(spanRange) <= storage.length else { continue }
                    storage.addAttributes(styles.attributes(for: span.role), range: spanRange)
                }
                if parent.project, parent.markdown, line.contains("**") {
                    for match in Self.bold.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        storage.addAttributes(styles.heading, range: NSRange(location: location + match.range.location, length: match.range.length))
                    }
                }
                location += (line as NSString).length + 1
            }
            storage.endEditing()
        }

        /// The changed lines' tint, diffed in a detached task: one at a time, the newest text
        /// next. A result for text the editor no longer holds never lands.
        private func tint(_ textView: InstructionsTextView, text: String, saved: String) {
            if let diffed, diffed.text == text, diffed.saved == saved { return }
            diffed = (text, saved)
            if text == saved {
                diffing?.cancel()
                diffing = nil
                apply([], to: textView)
                return
            }
            guard diffing == nil else { return }
            diffRuns += 1
            diffing = Task { [weak self, weak textView] in
                let changed = await Task.detached(priority: .userInitiated) {
                    let interval = AppSignposts.input.beginInterval("instructions tint diff")
                    defer { AppSignposts.input.endInterval("instructions tint diff", interval) }
                    return InstructionsText.changedLines(saved: saved, draft: text)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.diffing = nil
                guard let textView else { return }
                if textView.string == text, self.parent.saved == saved {
                    self.apply(changed, to: textView)
                } else {
                    // Superseded while it ran: diff the newest text.
                    self.diffed = nil
                    self.tint(textView, text: textView.string, saved: self.parent.saved)
                }
            }
        }

        private func apply(_ changed: Set<Int>, to textView: InstructionsTextView) {
            guard textView.changedLines != changed else { return }
            textView.changedLines = changed
            textView.needsDisplay = true
        }
    }
}

/// The editor's fonts and colors at the current text size. Colors are dynamic: they follow the
/// editor's appearance when it draws.
@MainActor
struct InstructionsEditorStyles {
    let base: [NSAttributedString.Key: Any]
    let heading: [NSAttributedString.Key: Any]
    let headingMarker: [NSAttributedString.Key: Any]
    let bullet: [NSAttributedString.Key: Any]
    let code: [NSAttributedString.Key: Any]
    let numbers: [NSAttributedString.Key: Any]

    static var current: InstructionsEditorStyles { InstructionsEditorStyles(scale: ThemeStore.shared.textScale) }

    init(scale: CGFloat, project: Bool = false, plain: Bool = false) {
        let size = (project ? AppLayout.projectsHostSize : AppLayout.instructionsEditorTextSize) * scale
        let font = NSFont(name: "GeistMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont(name: "GeistMono-SemiBold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
        let lineHeight = (plain ? AppLayout.subagentInstructionLineHeight : project ? AppLayout.projectEditorLineHeight : AppLayout.instructionsEditorLineHeight) * scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // Centred on the line rather than sitting on its bottom.
        let offset = max(0, (lineHeight - (font.ascender - font.descender)) / 2)
        base = [
            .font: font,
            .foregroundColor: NSColor(plain ? Color.sh.textPrimary : project ? Color.sh.projectInstructionText : Color.sh.textSecondary),
            .paragraphStyle: paragraph,
            .baselineOffset: offset,
        ]
        heading = [.font: project ? font : bold, .foregroundColor: NSColor(project ? Color.sh.projectMarkdownHeading : Color.sh.textPrimary)]
        headingMarker = project ? heading : [.foregroundColor: NSColor(Color.sh.textTertiary)]
        bullet = [.foregroundColor: NSColor(project ? Color.sh.settingsMuted : Color.sh.lanternText)]
        code = [.foregroundColor: NSColor(project ? Color.sh.projectMarkdownCode : Color.sh.synString)]
        let numberSize = (project ? AppLayout.projectsPathSize : AppLayout.instructionsNumberSize) * scale
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        numbers = [
            .font: NSFont(name: "GeistMono-Regular", size: numberSize) ?? .monospacedSystemFont(ofSize: numberSize, weight: .regular),
            .foregroundColor: NSColor(Color.sh.textTertiary),
            .paragraphStyle: right,
        ]
    }

    func attributes(for role: InstructionsSpan.Role) -> [NSAttributedString.Key: Any] {
        switch role {
        case .heading: heading
        case .headingMarker: headingMarker
        case .bullet: bullet
        case .code: code
        }
    }
}

/// The text view behind the editor: its text starts after the gutter, and its background draws
/// the changed lines' tint and the line numbers.
final class InstructionsTextView: NSTextView {
    // A window's shared undo stack outlives an editor replaced when its file or host changes.
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }

    /// Lines (from 0) changed since the last save.
    var changedLines: Set<Int> = []
    var project = false
    var plain = false
    private var gutter: CGFloat { plain ? 0 : project ? AppLayout.projectEditorGutter : AppLayout.instructionsGutterWidth }
    private var leading: CGFloat { plain ? AppLayout.subagentInstructionInset : project ? gutter + AppLayout.projectEditorInset : gutter + AppLayout.instructionsGutterGap }
    private var trailing: CGFloat { plain ? AppLayout.subagentInstructionInset : AppLayout.instructionsGutterGap }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: leading, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(0, newSize.width - leading - trailing)
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager else { return }
        let styles = InstructionsEditorStyles(scale: ThemeStore.shared.textScale, project: project, plain: plain)
        if project, !plain {
            NSColor(Color.sh.projectEditorBackground).setFill()
            NSRect(x: 0, y: rect.minY, width: gutter, height: rect.height).fill()
        }
        let origin = textContainerOrigin
        let text = string as NSString
        var index = 0
        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let lineRect = paragraphRect(lineRange, layoutManager: layoutManager).offsetBy(dx: origin.x, dy: origin.y)
            if lineRect.minY > rect.maxY { return }
            if lineRect.maxY >= rect.minY { drawLine(index, in: lineRect, styles: styles) }
            index += 1
            location = NSMaxRange(lineRange)
        }
        // The empty line of an empty file, or after a final newline, is numbered too.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, text.length == 0 || text.hasSuffix("\n") {
            drawLine(index, in: extra.offsetBy(dx: origin.x, dy: origin.y), styles: styles)
        }
    }

    /// The tint across a changed line, and its number in the gutter beside its first row.
    private func drawLine(_ index: Int, in lineRect: NSRect, styles: InstructionsEditorStyles) {
        if plain { return }
        if !project, changedLines.contains(index) {
            NSColor(Color.sh.lanternTint).setFill()
            NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()
        }
        let numberHeight = (styles.numbers[.font] as? NSFont).map { $0.ascender - $0.descender } ?? 12
        let row = min(lineRect.height, (project ? AppLayout.projectEditorLineHeight : AppLayout.instructionsEditorLineHeight) * ThemeStore.shared.textScale)
        ("\(index + 1)" as NSString).draw(
            in: NSRect(x: 0, y: lineRect.minY + (row - numberHeight) / 2,
                       width: gutter - (project ? AppLayout.projectEditorInset : 0), height: numberHeight),
            withAttributes: styles.numbers
        )
    }

    /// Where a paragraph (one numbered line, however many rows it wraps to) lies in the text
    /// container.
    private func paragraphRect(_ range: NSRange, layoutManager: NSLayoutManager) -> NSRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return first.union(last)
    }
}
