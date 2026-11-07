import SwiftUI
import UIKit
import ShepherdUI
import ShepherdRemote

/// The iPad Files editor's text (iPadPaneFiles): Geist Mono on even lines with numbers in a gutter, syntax colors
/// (`ReviewSyntax`), and beside each line a bar for the person's unsaved change (`lantern`, the line tinted
/// `lanternTint`) or the agent's last change on disk (`running`), as the Mac's Files editor marks them. Built on the
/// Instructions editor's text view and layout manager.
struct FileCodeEditor: UIViewRepresentable {
    let path: String
    /// The editor's text; the person's typing goes to `onEdit`.
    let text: String
    /// What is on disk: lines that differ from it are the person's.
    let saved: String
    /// The file before the agent's last change: lines that differ from it (and aren't the person's) are the agent's.
    let before: String?
    /// `ThreadFilesModel.textRevision`: the text was replaced from outside the editor.
    let revision: UInt
    let editable: Bool
    let onEdit: (String) -> Void
    let onCursor: (FileCursor) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InstructionsTextView {
        let view = InstructionsTextView(metrics: .files)
        view.wraps = false
        view.delegate = context.coordinator
        view.accessibilityLabel = "File contents"
        return view
    }

    func updateUIView(_ view: InstructionsTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.isEditable = editable
        // Another file, or its text replaced from outside (a read, a revert, a draft set while the editor isn't
        // typed in): never under the person's typing.
        if coordinator.shown?.path != path || coordinator.shown?.revision != revision || (!view.isFirstResponder && view.text != text) {
            coordinator.shown = (path, revision)
            if view.text != text, view.markedTextRange == nil {
                let samePath = coordinator.shownPath == path
                let selection = view.selectedRange
                view.text = text
                view.undoManager?.removeAllActions()
                if samePath, NSMaxRange(selection) <= (text as NSString).length { view.selectedRange = selection }
            }
            coordinator.shownPath = path
            coordinator.styled = nil
        }
        coordinator.category = UIContentSizeCategory(dynamicTypeSize)
        coordinator.restyle(view)
    }

    static func dismantleUIView(_ view: InstructionsTextView, coordinator: Coordinator) {
        coordinator.pending?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FileCodeEditor
        var category: UIContentSizeCategory = .large
        var shown: (path: String, revision: UInt)?
        var shownPath: String?
        /// What the view was last styled for.
        var styled: (text: String, saved: String, before: String?, size: CGFloat)?
        /// Colors after a pause in typing: re-lexing every line on each key would lag a long file.
        var pending: Task<Void, Never>?

        init(_ parent: FileCodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.onEdit(textView.text)
            guard let view = textView as? InstructionsTextView else { return }
            pending?.cancel()
            pending = Task { [weak self, weak view] in
                try? await Task.sleep(for: MobileLayout.fileRestyleDelay)
                guard !Task.isCancelled, let self, let view else { return }
                self.restyle(view)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let text = textView.text as NSString
            let location = min(textView.selectedRange.location, text.length)
            let before = text.substring(to: location) as NSString
            let line = (before as String).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let newline = before.range(of: "\n", options: .backwards)
            let column = before.length - (newline.location == NSNotFound ? 0 : newline.location + 1) + 1
            parent.onCursor(FileCursor(line: line, column: column))
        }

        /// Every line's colors from its syntax, and the marks.
        func restyle(_ view: InstructionsTextView) {
            guard view.markedTextRange == nil else { return }
            let text = view.text ?? ""
            let saved = parent.saved, before = parent.before
            let styles = InstructionsEditorStyles(metrics: view.metrics, traits: UITraitCollection(preferredContentSizeCategory: category))
            if let styled, styled.text == text, styled.saved == saved, styled.before == before, styled.size == styles.size { return }
            styled = (text, saved, before, styles.size)
            let storage = view.textStorage
            storage.beginEditing()
            storage.setAttributes(styles.base, range: NSRange(location: 0, length: storage.length))
            if let language = ReviewSyntax.language(forPath: parent.path) {
                let palette = FileSyntaxPalette()
                var location = 0
                for line in text.components(separatedBy: "\n") {
                    for span in ReviewSyntax.spans(line, language: language) {
                        let length = (span.text as NSString).length
                        if let kind = span.kind, location + length <= storage.length {
                            storage.addAttribute(.foregroundColor, value: palette.color(kind), range: NSRange(location: location, length: length))
                        }
                        location += length
                    }
                    location += 1
                }
            }
            storage.endEditing()
            view.typingAttributes = styles.base
            let unsaved = text == saved ? [] : InstructionsText.changedLines(saved: saved, draft: text)
            let agent = before.map { InstructionsText.changedLines(saved: $0, draft: text).subtracting(unsaved) } ?? []
            view.decorate(changed: unsaved, agent: agent, styles: styles)
        }
    }
}

/// The caret's line and column, from 1 (the status bar's "Ln 94, Col 48").
struct FileCursor: Equatable {
    var line = 1
    var column = 1
    var label: String { "Ln \(line), Col \(column)" }
}

/// Syntax colors by kind, as the Changes reader colors a diff.
@MainActor
struct FileSyntaxPalette {
    private let sh = Color.sh

    func color(_ kind: ReviewSyntax.Kind) -> UIColor {
        switch kind {
        case .keyword: UIColor(sh.synKeyword)
        case .type: UIColor(sh.synType)
        case .string: UIColor(sh.synString)
        case .number: UIColor(sh.synNumber)
        case .function: UIColor(sh.synFunction)
        case .comment: UIColor(sh.synComment)
        }
    }
}

extension InstructionsEditorMetrics {
    /// The Files editor's (iPadPaneFiles): mono 13 on 24pt lines, numbers in a 36pt gutter, then a 3pt mark 8pt
    /// after them and the text 10pt after the mark.
    static let files = InstructionsEditorMetrics(
        textSize: MobileLayout.fileCodeTextSize, lineHeight: MobileLayout.fileCodeLineHeight,
        numberSize: MobileLayout.fileCodeNumberSize, gutterWidth: MobileLayout.fileCodeGutter,
        gutterGap: MobileLayout.fileCodeMarkGap + MobileLayout.fileMarkWidth + MobileLayout.fileCodeTextGap,
        inset: SH.Space.m)
}

extension InstructionsTextView {
    /// The Files editor's marks: `changed` lines tinted with a `lantern` bar, `agent` lines with a `running` bar.
    func decorate(changed: Set<Int>, agent: Set<Int>, styles: InstructionsEditorStyles) {
        let layout = layoutManager as? InstructionsLayoutManager
        layout?.agentLines = agent
        layout?.markX = metrics.gutterWidth + MobileLayout.fileCodeMarkGap
        layout?.markWidth = MobileLayout.fileMarkWidth
        layout?.mark = UIColor(Color.sh.lantern)
        layout?.agentMark = UIColor(Color.sh.running)
        decorate(changed: changed, styles: styles)
    }
}
