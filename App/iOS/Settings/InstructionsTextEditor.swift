import SwiftUI
import UIKit
import ShepherdUI
import ShepherdRemote

/// The root instruction file's editor on iPhone and iPad (MobileInstructionsEdit,
/// iPadSettingsInstructions), as the Mac's Settings ▸ Instructions draws it: the file as plain
/// Markdown in Geist Mono on even lines, a gutter of line numbers, light highlighting
/// (`InstructionsText.highlight`: heading marks `textTertiary` and words semibold `textPrimary`,
/// bullets `lanternText`, code spans `synString`, the rest `textSecondary`), every line changed
/// since the last save tinted `lanternTint`, and a `lantern` caret. Sizes follow Dynamic Type.
struct InstructionsTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// What is saved: lines that differ from it are tinted.
    let saved: String
    let metrics: InstructionsEditorMetrics
    /// Where the key row reaches the text, and whether the editor has the keyboard.
    let focus: InstructionsEditorFocus
    let accessibilityLabel: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InstructionsTextView {
        let view = InstructionsTextView(metrics: metrics)
        view.delegate = context.coordinator
        view.text = text
        view.accessibilityLabel = accessibilityLabel
        focus.textView = view
        context.coordinator.restyle(view)
        return view
    }

    func updateUIView(_ view: InstructionsTextView, context: Context) {
        context.coordinator.parent = self
        focus.textView = view
        view.accessibilityLabel = accessibilityLabel
        if view.metrics != metrics { view.metrics = metrics }
        // Another file, another host, a revert or a save from elsewhere: the text changes under
        // the editor.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            view.undoManager?.removeAllActions()
        }
        // A new text size restyles at the new size.
        _ = dynamicTypeSize
        context.coordinator.restyle(view)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InstructionsTextEditor
        /// What the text view was last styled for: a render that changes none of it leaves the
        /// text alone (and an input method's marked text with it).
        private var styled: (text: String, saved: String, size: CGFloat)?

        init(_ parent: InstructionsTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? InstructionsTextView else { return }
            if parent.text != view.text { parent.text = view.text }
            restyle(view)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focus.editing { parent.focus.editing = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focus.editing { parent.focus.editing = false }
        }

        /// Sets every line's attributes from its highlight, and which lines are tinted.
        func restyle(_ view: InstructionsTextView) {
            // Never under an input method's marked text: it restyles once the text is committed.
            guard view.markedTextRange == nil else { return }
            let text = view.text ?? ""
            let saved = parent.saved
            let styles = InstructionsEditorStyles(metrics: view.metrics, traits: view.traitCollection)
            if let styled, styled.text == text, styled.saved == saved, styled.size == styles.size { return }
            styled = (text, saved, styles.size)
            let storage = view.textStorage
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
            view.typingAttributes = styles.base
            view.decorate(changed: InstructionsText.changedLines(saved: saved, draft: text), styles: styles)
        }
    }
}

/// The editor's measures: the phone's (mono 13 on 21pt lines, a 28pt gutter) or the iPad's
/// (mono 14 on 26pt lines, a 34pt gutter), before Dynamic Type.
struct InstructionsEditorMetrics: Equatable {
    var textSize: CGFloat
    var lineHeight: CGFloat
    var numberSize: CGFloat
    var gutterWidth: CGFloat
    /// Between the gutter and the text, and after the text.
    var gutterGap: CGFloat
    /// Above the first line and below the last.
    var inset: CGFloat

    static let phone = InstructionsEditorMetrics(
        textSize: MobileLayout.instructionsPhoneTextSize, lineHeight: MobileLayout.instructionsPhoneLineHeight,
        numberSize: MobileLayout.instructionsNumberSize, gutterWidth: MobileLayout.instructionsPhoneGutter,
        gutterGap: MobileLayout.instructionsGutterGap, inset: MobileLayout.instructionsEditorInset)
    static let pad = InstructionsEditorMetrics(
        textSize: MobileLayout.instructionsPadTextSize, lineHeight: MobileLayout.instructionsPadLineHeight,
        numberSize: MobileLayout.instructionsNumberSize, gutterWidth: MobileLayout.instructionsPadGutter,
        gutterGap: MobileLayout.instructionsGutterGap, inset: MobileLayout.instructionsEditorInset)
}

/// The editor's fonts and colors at the current text size. Colors are dynamic: they follow the
/// editor's appearance when it draws.
@MainActor
struct InstructionsEditorStyles {
    /// The text size after Dynamic Type.
    let size: CGFloat
    let lineHeight: CGFloat
    let base: [NSAttributedString.Key: Any]
    let heading: [NSAttributedString.Key: Any]
    let headingMarker: [NSAttributedString.Key: Any]
    let bullet: [NSAttributedString.Key: Any]
    let code: [NSAttributedString.Key: Any]
    let numbers: [NSAttributedString.Key: Any]
    let numberHeight: CGFloat

    init(metrics: InstructionsEditorMetrics, traits: UITraitCollection) {
        let scaling = UIFontMetrics(forTextStyle: .callout)
        size = min(scaling.scaledValue(for: metrics.textSize, compatibleWith: traits), MobileLayout.instructionsMaximumTextSize)
        let scale = size / metrics.textSize
        lineHeight = (metrics.lineHeight * scale).rounded()
        let font = UIFont(name: "GeistMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont(name: "GeistMono-SemiBold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        base = [
            .font: font,
            .foregroundColor: UIColor(Color.nw.textSecondary),
            .paragraphStyle: paragraph,
            // Centred on the line rather than sitting on its bottom.
            .baselineOffset: max(0, (lineHeight - font.lineHeight) / 2),
        ]
        heading = [.font: bold, .foregroundColor: UIColor(Color.nw.textPrimary)]
        headingMarker = [.foregroundColor: UIColor(Color.nw.textTertiary)]
        bullet = [.foregroundColor: UIColor(Color.nw.lanternText)]
        code = [.foregroundColor: UIColor(Color.nw.synString)]
        let numberSize = metrics.numberSize * scale
        let numberFont = UIFont(name: "GeistMono-Regular", size: numberSize) ?? .monospacedSystemFont(ofSize: numberSize, weight: .regular)
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        numbers = [.font: numberFont, .foregroundColor: UIColor(Color.nw.textTertiary), .paragraphStyle: right]
        numberHeight = numberFont.lineHeight
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

/// The text view behind the editor, on TextKit 1 so its layout manager can draw the gutter: its
/// text starts after the gutter, and behind the text it draws the changed lines' tint and the
/// line numbers.
final class InstructionsTextView: UITextView {
    var metrics: InstructionsEditorMetrics {
        didSet { applyInsets() }
    }

    /// The text system: the view holds the storage, which holds the layout manager, which holds
    /// the container.
    private let storage: NSTextStorage
    private let decorations: InstructionsLayoutManager

    init(metrics: InstructionsEditorMetrics) {
        self.metrics = metrics
        storage = NSTextStorage()
        decorations = InstructionsLayoutManager()
        storage.addLayoutManager(decorations)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        decorations.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        tintColor = UIColor(Color.nw.lantern)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        applyInsets()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws `changed` lines tinted, and the numbers, at `styles`' sizes.
    func decorate(changed: Set<Int>, styles: InstructionsEditorStyles) {
        decorations.changedLines = changed
        decorations.numberAttributes = styles.numbers
        decorations.numberHeight = styles.numberHeight
        decorations.rowHeight = styles.lineHeight
        decorations.tint = UIColor(Color.nw.lanternTint)
        decorations.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        setNeedsDisplay()
    }

    private func applyInsets() {
        textContainerInset = UIEdgeInsets(top: metrics.inset, left: metrics.gutterWidth + metrics.gutterGap,
                                          bottom: metrics.inset, right: metrics.gutterGap)
        decorations.gutterWidth = metrics.gutterWidth
        decorations.trailingInset = metrics.gutterGap
    }
}

/// Draws behind the text: a changed line's tint across the editor, and each line's number in
/// the gutter beside its first row.
final class InstructionsLayoutManager: NSLayoutManager {
    var changedLines: Set<Int> = []
    var numberAttributes: [NSAttributedString.Key: Any] = [:]
    var numberHeight: CGFloat = 12
    var rowHeight: CGFloat = 21
    var gutterWidth: CGFloat = 28
    var trailingInset: CGFloat = 8
    var tint: UIColor = .clear

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let string = textStorage?.string else { return }
        let text = string as NSString
        let starts = Self.lineStarts(text)
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let characters = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let line = Self.line(at: characters.location, starts: starts)
            let row = rect.offsetBy(dx: origin.x, dy: origin.y)
            if self.changedLines.contains(line) {
                self.tint.setFill()
                UIRectFill(CGRect(x: 0, y: row.minY, width: row.maxX + self.trailingInset, height: row.height))
            }
            // A line wrapped over several rows is numbered on its first.
            if characters.location == starts[line] { self.drawNumber(line + 1, top: row.minY) }
        }
        // The empty line of an empty file, or after a final newline, is numbered too.
        let extra = extraLineFragmentRect
        if !extra.isEmpty, text.length == 0 || text.hasSuffix("\n") {
            drawNumber(starts.count, top: extra.minY + origin.y)
        }
    }

    /// A number right-aligned in the gutter, centred on its line's first row.
    private func drawNumber(_ number: Int, top: CGFloat) {
        ("\(number)" as NSString).draw(
            in: CGRect(x: 0, y: top + (rowHeight - numberHeight) / 2, width: gutterWidth, height: numberHeight),
            withAttributes: numberAttributes
        )
    }

    /// Where each line starts, in UTF-16 offsets: 0, then just after every newline.
    static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        return starts
    }

    /// The line (from 0) holding `location`.
    static func line(at location: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

// MARK: The key row

/// The keys over the keyboard while the editor has it (MobileInstructionsEdit): Markdown's marks,
/// and an indent.
enum InstructionsKey: String, CaseIterable {
    case heading, bullet, code, bold, indent

    var label: String {
        switch self {
        case .heading: "#"
        case .bullet: "-"
        case .code: "`"
        case .bold: "**"
        case .indent: "Tab"
        }
    }

    var spokenLabel: String {
        switch self {
        case .heading: "Heading mark"
        case .bullet: "List bullet"
        case .code: "Code"
        case .bold: "Bold"
        case .indent: "Indent"
        }
    }
}

/// Reaches the editor's text view from outside it: whether it has the keyboard (the key row
/// shows while it does), and what a key types.
@MainActor
@Observable
final class InstructionsEditorFocus {
    var editing = false
    @ObservationIgnored weak var textView: UITextView?

    /// Types a key: a mark where the caret is; `code` and bold wrap a selection instead; Tab
    /// indents two spaces, as a nested list item needs.
    func press(_ key: InstructionsKey) {
        guard let textView else { return }
        switch key {
        case .heading, .bullet: textView.insertText(key.label)
        case .indent: textView.insertText("  ")
        case .code, .bold:
            if let range = textView.selectedTextRange, !range.isEmpty, let selected = textView.text(in: range) {
                textView.replace(range, withText: key.label + selected + key.label)
            } else {
                textView.insertText(key.label)
            }
        }
        // Programmatic edits report like typed ones, so the draft always holds what shows.
        textView.delegate?.textViewDidChange?(textView)
    }

    /// The key row's keys.
    static var keycaps: [NWTerminalKeycap] {
        InstructionsKey.allCases.map { NWTerminalKeycap(id: $0.rawValue, label: $0.label, spokenLabel: $0.spokenLabel) }
    }
}

/// The key row under the editor while it has the keyboard.
struct InstructionsKeyRow: View {
    let focus: InstructionsEditorFocus

    var body: some View {
        NWTerminalKeyRow(InstructionsEditorFocus.keycaps) { id in
            if let key = InstructionsKey(rawValue: id) { focus.press(key) }
        }
        .accessibilityLabel("Markdown keys")
    }
}
