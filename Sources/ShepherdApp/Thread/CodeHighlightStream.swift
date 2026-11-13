import Foundation
import ShepherdUI

/// The colors of a fence a reply is writing, as tree-sitter gives them: each request colors only
/// the lines added since the last, off the main actor, and what lands is what the block draws, the
/// text after it plain. One request runs at a time; those that arrive meanwhile are replaced by the
/// newest, which covers them.
@MainActor final class CodeHighlightStream {
    private struct Request {
        let code: String
        let lines: Int
        let path: String
        let style: CodeHighlight.Style
        let landed: @MainActor () -> Void
    }

    /// The colors of `colored`, the fence's first lines.
    private(set) var colors = SHCodeColors()
    private var colored = ""
    private var session: CodeHighlight.Session?
    private var pending: Request?
    private var running = false
    /// Counts the times the stream was let go of, so a request in flight does not bring it back.
    private var epoch = 0
    private let none = SHCodeColors()

    /// Whether any lines have been colored.
    var isColoring: Bool { colors.revision > 0 }

    /// The colors to draw `code` with: those of its first lines, or none if it no longer begins with them.
    func colors(for code: String) -> SHCodeColors {
        Self.begins(code, with: colored) ? colors : none
    }

    /// Colors the first `lines` lines of `code`; `landed` is called (on the main actor) when the result is in.
    func request(code: String, lines: Int, path: String, landed: @escaping @MainActor () -> Void) {
        pending = Request(code: code, lines: lines, path: path, style: CodeHighlight.Style.theme, landed: landed)
        guard !running else { return }
        running = true
        Task { await run() }
    }

    /// Lets go of the tree and the colors, for a block that is colored in full.
    func finish() {
        epoch &+= 1
        pending = nil
        session = nil
        colors = SHCodeColors()
        colored = ""
    }

    private func run() async {
        while let next = pending {
            pending = nil
            let epoch = epoch
            let previous = session
            let (code, lines, path, style) = (next.code, next.lines, next.path, next.style)
            let (session, update) = await Task.detached(priority: .userInitiated) {
                let session = previous?.path == path ? previous : CodeHighlight.Session(path: path)
                return (session, session?.advance(code: code, lines: lines, style: style))
            }.value
            guard epoch == self.epoch else { continue }
            self.session = session
            if let update {
                colors.recolor(from: update.from, with: update.spans)
                colored = update.text
            }
            next.landed()
        }
        running = false
    }

    private static func begins(_ text: String, with prefix: String) -> Bool {
        if prefix.isEmpty { return true }
        var text = text, prefix = prefix
        return text.withUTF8 { whole in
            prefix.withUTF8 { head in head.count <= whole.count && memcmp(whole.baseAddress, head.baseAddress, head.count) == 0 }
        }
    }
}
