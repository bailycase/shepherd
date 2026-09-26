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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InstructionsTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
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
        textView.backgroundColor = NSColor(Color.nw.bgWindow)
        textView.insertionPointColor = NSColor(Color.nw.lantern)
        textView.textContainerInset = NSSize(width: 0, height: AppLayout.instructionsEditorInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.restyle(textView, saved: saved)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? InstructionsTextView else { return }
        textView.setAccessibilityLabel(accessibilityLabel)
        // Another file, a revert, or a save from elsewhere: the text changes under the editor.
        if textView.string != text {
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
        context.coordinator.restyle(textView, saved: saved)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InstructionsEditor
        /// What the text view was last styled for: a render that changes none of it leaves the
        /// text alone (and an input method's marked text with it).
        private var styled: (text: String, saved: String, scale: CGFloat)?

        init(_ parent: InstructionsEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? InstructionsTextView else { return }
            parent.text = textView.string
            restyle(textView, saved: parent.saved)
        }

        /// Sets every line's attributes from its highlight, and which lines are tinted.
        func restyle(_ textView: InstructionsTextView, saved: String) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let scale = ThemeStore.shared.textScale
            if let styled, styled.text == text, styled.saved == saved, styled.scale == scale { return }
            styled = (text, saved, scale)
            let styles = InstructionsEditorStyles(scale: scale)
            storage.beginEditing()
            storage.setAttributes(styles.base, range: NSRange(location: 0, length: storage.length))
            var location = 0
            for line in text.components(separatedBy: "\n") {
                for span in InstructionsText.highlight(line: line) {
                    let range = NSRange(location: location + span.range.lowerBound, length: span.range.count)
                    guard NSMaxRange(range) <= storage.length else { continue }
                    storage.addAttributes(styles.attributes(for: span.role), range: range)
                }
                location += (line as NSString).length + 1
            }
            storage.endEditing()
            textView.typingAttributes = styles.base
            let changed = InstructionsText.changedLines(saved: saved, draft: text)
            if textView.changedLines != changed {
                textView.changedLines = changed
                textView.needsDisplay = true
            }
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

    init(scale: CGFloat) {
        let size = AppLayout.instructionsEditorTextSize * scale
        let font = NSFont(name: "GeistMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont(name: "GeistMono-SemiBold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
        let lineHeight = AppLayout.instructionsEditorLineHeight * scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // Centred on the line rather than sitting on its bottom.
        let offset = max(0, (lineHeight - (font.ascender - font.descender)) / 2)
        base = [
            .font: font,
            .foregroundColor: NSColor(Color.nw.textSecondary),
            .paragraphStyle: paragraph,
            .baselineOffset: offset,
        ]
        heading = [.font: bold, .foregroundColor: NSColor(Color.nw.textPrimary)]
        headingMarker = [.foregroundColor: NSColor(Color.nw.textTertiary)]
        bullet = [.foregroundColor: NSColor(Color.nw.lanternText)]
        code = [.foregroundColor: NSColor(Color.nw.synString)]
        let numberSize = AppLayout.instructionsNumberSize * scale
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        numbers = [
            .font: NSFont(name: "GeistMono-Regular", size: numberSize) ?? .monospacedSystemFont(ofSize: numberSize, weight: .regular),
            .foregroundColor: NSColor(Color.nw.textTertiary),
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
    /// Lines (from 0) changed since the last save.
    var changedLines: Set<Int> = []

    private var leading: CGFloat { AppLayout.instructionsGutterWidth + AppLayout.instructionsGutterGap }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: leading, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(0, newSize.width - leading - AppLayout.instructionsGutterGap)
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager else { return }
        let styles = InstructionsEditorStyles.current
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
        if changedLines.contains(index) {
            NSColor(Color.nw.lanternTint).setFill()
            NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()
        }
        let numberHeight = (styles.numbers[.font] as? NSFont).map { $0.ascender - $0.descender } ?? 12
        let row = min(lineRect.height, AppLayout.instructionsEditorLineHeight * ThemeStore.shared.textScale)
        ("\(index + 1)" as NSString).draw(
            in: NSRect(x: 0, y: lineRect.minY + (row - numberHeight) / 2,
                       width: AppLayout.instructionsGutterWidth, height: numberHeight),
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
