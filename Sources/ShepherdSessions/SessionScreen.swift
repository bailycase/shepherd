import Foundation
import SwiftTerm

/// Headless terminal emulation of one PTY session's screen (the tmux model).
/// PTY output is fed into a SwiftTerm `Terminal`; on attach, `snapshot()`
/// serializes the *current* screen state as self-contained ANSI that
/// reproduces it on a fresh, same-size terminal — replacing raw byte replay,
/// which corrupts fresh surfaces whenever redraw sequences assumed prior
/// screen state.
///
/// Not internally synchronized: like all session state, every call must run
/// under the in-process server queue hierarchy (PTYSession's queue targets
/// the server queue, so feeds and attach-time snapshots are mutually exclusive).
final class SessionScreen {
    /// Lines of scrollback the emulation retains, bounding app memory and
    /// attach-time snapshot size.
    static let defaultScrollbackLines = 2000

    /// Tracks state SwiftTerm only surfaces through delegate callbacks
    /// (cursor visibility and style have no public getters). Terminal holds
    /// its delegate weakly, so SessionScreen retains this strongly.
    private final class ScreenDelegate: TerminalDelegate {
        var cursorHidden = false
        var cursorStyle: CursorStyle?

        // Headless: the emulator never answers host queries (DA/DSR/...);
        // the attached client's real terminal responds to those instead.
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func showCursor(source: Terminal) { cursorHidden = false }
        func hideCursor(source: Terminal) { cursorHidden = true }
        func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) { cursorStyle = newStyle }
    }

    private let delegate: ScreenDelegate
    let terminal: Terminal

    var cols: Int { terminal.cols }
    var rows: Int { terminal.rows }

    init(cols: Int, rows: Int, scrollbackLines: Int = SessionScreen.defaultScrollbackLines) {
        let delegate = ScreenDelegate()
        self.delegate = delegate
        // SwiftTerm clamps to MINIMUM_COLS=2 / MINIMUM_ROWS=1 internally.
        self.terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: max(2, cols),
                rows: max(1, rows),
                scrollback: scrollbackLines
            )
        )
    }

    func feed(_ data: Data) {
        terminal.feed(byteArray: [UInt8](data))
    }

    /// Keep in sync with the PTY's winsize so wraps match what the child saw.
    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: max(2, cols), rows: max(1, rows))
    }

    // MARK: - Snapshot

    /// Serializes the current terminal state as self-contained ANSI: full
    /// reset, normal-buffer scrollback + screen (styled, wrap-preserving),
    /// alt screen if active, cursor position, and re-armed interaction modes.
    func snapshot(scrollbackLimit: Int? = nil) -> Data {
        // RIS puts the receiving terminal in a known state, but it is not
        // required to drop saved lines, and Ghostty keeps them. A snapshot is
        // a whole-screen restore, so any scrollback already in the surface
        // would remain *above* it and show earlier output (a pi startup
        // warning, say) a second time on every re-attach. ESC[3J erases the
        // saved lines explicitly, which makes the snapshot self-contained on
        // any receiver.
        var out = "\u{1b}c\u{1b}[3J"
        var run = SGRRun()

        if terminal.isCurrentBufferAlternate {
            // Normal-buffer history + screen first, so leaving the alt screen
            // lands on the right content. Only a plain-text rendition is
            // reachable here: SwiftTerm exposes the inactive normal buffer
            // solely via getBufferAsData (no per-cell attributes).
            appendNormalBufferPlainText(&out, scrollbackLimit: scrollbackLimit)
            out += "\u{1b}[?1049h\u{1b}[H"
            appendVisibleRowsStyled(&out, run: &run)
        } else {
            appendScrollbackAndScreenStyled(&out, run: &run, scrollbackLimit: scrollbackLimit)
        }

        out += "\u{1b}[0m"
        let cursor = terminal.getCursorLocation()
        // buffer.x may sit one past the last column (deferred wrap); clamp.
        let row = min(cursor.y, terminal.rows - 1) + 1
        let col = min(cursor.x, terminal.cols - 1) + 1
        out += "\u{1b}[\(row);\(col)H"
        appendModes(&out)
        return Data(out.utf8)
    }

    /// The flat line list of the active (normal) buffer: scrollback followed
    /// by the visible rows. Emitting every line — trailing blank screen rows
    /// included — makes the receiver's last `rows` lines line up exactly with
    /// the source screen (covers "cleared screen with history above" layouts).
    private func appendScrollbackAndScreenStyled(
        _ out: inout String,
        run: inout SGRRun,
        scrollbackLimit: Int?
    ) {
        let historyLines = terminal.getTopVisibleRow()
        let retainedHistory = min(historyLines, max(0, scrollbackLimit ?? historyLines))
        let top = terminal.buffer.totalLinesTrimmed + historyLines - retainedHistory
        let total = retainedHistory + terminal.rows
        for i in 0..<total {
            let line = terminal.getScrollInvariantLine(row: top + i)
            let nextWrapped = i + 1 < total
                && (terminal.getScrollInvariantLine(row: top + i + 1)?.isWrapped ?? false)
            appendStyledLine(line, fullWidth: nextWrapped, out: &out, run: &run)
            if i + 1 < total && !nextWrapped {
                out += "\r\n"
            }
        }
    }

    /// Visible rows of the active buffer only (used for the alt screen, which
    /// has no scrollback).
    private func appendVisibleRowsStyled(_ out: inout String, run: inout SGRRun) {
        let rows = terminal.rows
        for row in 0..<rows {
            let line = terminal.getLine(row: row)
            let nextWrapped = row + 1 < rows
                && (terminal.getLine(row: row + 1)?.isWrapped ?? false)
            appendStyledLine(line, fullWidth: nextWrapped, out: &out, run: &run)
            if row + 1 < rows && !nextWrapped {
                out += "\r\n"
            }
        }
    }

    private func appendStyledLine(
        _ line: BufferLine?, fullWidth: Bool, out: inout String, run: inout SGRRun
    ) {
        guard let line else { return }
        let limit = fullWidth
            ? min(terminal.cols, line.count)
            : styledWidth(of: line)
        var col = 0
        while col < limit {
            let cell = line[col]
            col += 1
            if cell.width == 0 { continue } // wide-char continuation stub
            if run.update(to: cell.attribute, params: sgrParams(for: cell.attribute)) {
                out += "\u{1b}[\(run.params)m"
            }
            // Erased/never-written cells render as blanks under their attribute.
            out.append(Self.isNull(cell) ? " " : terminal.getCharacter(for: cell))
        }
    }

    /// True for a cell whose stored code is 0 (erased or never written).
    /// CharData's raw code is not public; `getCharacter()` maps code 0 — and
    /// only code 0 — to NUL.
    private static func isNull(_ cell: CharData) -> Bool {
        cell.getCharacter() == "\u{0}"
    }

    /// Width of the line once trailing cells that render as pure default
    /// blanks are dropped (a fresh terminal's rows are already that). Blank
    /// cells carrying visible attributes (colored bg, inverse) are content.
    private func styledWidth(of line: BufferLine) -> Int {
        var end = min(terminal.cols, line.count)
        while end > 0 {
            let cell = line[end - 1]
            if !Self.isNull(cell) || sgrParams(for: cell.attribute) != "0" { break }
            end -= 1
        }
        return end
    }

    /// Plain-text rendition of the entire normal buffer (SwiftTerm's only
    /// public view of it while the alt buffer is active). Interior NULs are
    /// blanked so the receiver does not collapse erased gaps.
    private func appendNormalBufferPlainText(_ out: inout String, scrollbackLimit: Int?) {
        let text = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            .replacingOccurrences(of: "\0", with: " ")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() } // trailing newline artifact
        if let scrollbackLimit {
            lines = Array(lines.suffix(max(terminal.rows, terminal.rows + scrollbackLimit)))
        }
        out += lines.joined(separator: "\r\n")
    }

    /// Re-arm interaction modes the attached client's terminal must know
    /// about. Best effort: SwiftTerm does not expose application keypad
    /// (DECKPAM), DECAWM, charset selection, or the mouse coordinate
    /// encoding; SGR encoding (1006) is re-armed alongside any tracking mode
    /// since every current TUI requests it.
    private func appendModes(_ out: inout String) {
        // Patches replace raw PTY output, so clear every mode we mirror before
        // enabling the host's current state.
        out += "\u{1b}[?25h\u{1b}[?1l\u{1b}[?2004l\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l"
        if delegate.cursorHidden { out += "\u{1b}[?25l" }
        if terminal.applicationCursor { out += "\u{1b}[?1h" }
        if terminal.bracketedPasteMode { out += "\u{1b}[?2004h" }
        switch terminal.mouseMode {
        case .off: break
        case .x10: out += "\u{1b}[?9h"
        case .vt200: out += "\u{1b}[?1000h"
        case .buttonEventTracking: out += "\u{1b}[?1002h"
        case .anyEvent: out += "\u{1b}[?1003h"
        }
        if terminal.mouseMode != .off {
            out += "\u{1b}[?1006h"
        }
        if let style = delegate.cursorStyle {
            out += "\u{1b}[\(Self.decscusr(style)) q"
        }
    }

    private static func decscusr(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: return 1
        case .steadyBlock: return 2
        case .blinkUnderline: return 3
        case .steadyUnderline: return 4
        case .blinkBar: return 5
        case .steadyBar: return 6
        }
    }

    // MARK: - SGR

    /// Tracks the SGR state carried across emitted cells so runs of identical
    /// attributes cost one sequence. Attribute equality short-circuits the
    /// string work; distinct attributes rendering identically (default fg vs
    /// default-inverted fg) coalesce via the params comparison.
    private struct SGRRun {
        private var attribute: Attribute?
        private(set) var params = "0"

        mutating func update(to attr: Attribute, params newParams: @autoclosure () -> String) -> Bool {
            if let attribute, attribute == attr { return false }
            attribute = attr
            let p = newParams()
            if p == params { return false }
            params = p
            return true
        }
    }

    /// Full SGR parameter list reproducing `attr` from any prior state
    /// (starts with 0 so no reset bookkeeping is needed between runs).
    private func sgrParams(for attr: Attribute) -> String {
        var p = "0"
        let style = attr.style
        if style.contains(.bold) { p += ";1" }
        if style.contains(.dim) { p += ";2" }
        if style.contains(.italic) { p += ";3" }
        if style.contains(.underline) {
            switch attr.underlineStyle {
            case .none, .single: p += ";4"
            case .double: p += ";4:2"
            case .curly: p += ";4:3"
            case .dotted: p += ";4:4"
            case .dashed: p += ";4:5"
            }
        }
        if style.contains(.blink) { p += ";5" }
        if style.contains(.inverse) { p += ";7" }
        if style.contains(.invisible) { p += ";8" }
        if style.contains(.crossedOut) { p += ";9" }
        switch attr.fg {
        case .defaultColor, .defaultInvertedColor:
            break
        case .ansi256(let c):
            if c < 8 {
                p += ";\(30 + Int(c))"
            } else if c < 16 {
                p += ";\(90 + Int(c) - 8)"
            } else {
                p += ";38;5;\(c)"
            }
        case .trueColor(let r, let g, let b):
            p += ";38;2;\(r);\(g);\(b)"
        }
        switch attr.bg {
        case .defaultColor, .defaultInvertedColor:
            break
        case .ansi256(let c):
            if c < 8 {
                p += ";\(40 + Int(c))"
            } else if c < 16 {
                p += ";\(100 + Int(c) - 8)"
            } else {
                p += ";48;5;\(c)"
            }
        case .trueColor(let r, let g, let b):
            p += ";48;2;\(r);\(g);\(b)"
        }
        if let underlineColor = attr.underlineColor {
            switch underlineColor {
            case .ansi256(let c):
                p += ";58:5:\(c)"
            case .trueColor(let r, let g, let b):
                p += ";58:2::\(r):\(g):\(b)"
            case .defaultColor, .defaultInvertedColor:
                break
            }
        }
        return p
    }

    // MARK: - Introspection (tests and assertions)

    var isAlternateScreenActive: Bool { terminal.isCurrentBufferAlternate }
    var scrollbackRows: Int { terminal.getTopVisibleRow() }

    var isCursorHidden: Bool { delegate.cursorHidden }

    /// Cursor position in the visible screen, 0-based, deferred-wrap clamped.
    var cursorPosition: (col: Int, row: Int) {
        let c = terminal.getCursorLocation()
        return (min(c.x, terminal.cols - 1), min(c.y, terminal.rows - 1))
    }

    /// Rendered text of one visible row, right-trimmed, NULs normalized to
    /// spaces so erased cells compare equal to emitted blanks.
    func visibleText(row: Int) -> String {
        guard let line = terminal.getLine(row: row) else { return "" }
        return line
            .translateToString(trimRight: true, skipNullCellsFollowingWide: true) { [terminal] cell in
                Self.isNull(cell) ? " " : terminal.getCharacter(for: cell)
            }
            .replacingOccurrences(of: "\0", with: " ")
    }

    func visibleText() -> [String] {
        (0..<terminal.rows).map { visibleText(row: $0) }
    }

    /// Render-equivalence signature of one visible row: each rendered cell's
    /// character plus its normalized SGR params, trailing default blanks
    /// dropped. Two screens showing identical rows (text *and* attributes)
    /// produce identical signatures.
    func rowSignature(row: Int) -> String {
        guard let line = terminal.getLine(row: row) else { return "" }
        let limit = styledWidth(of: line)
        var signature = ""
        for col in 0..<limit {
            let cell = line[col]
            if cell.width == 0 { continue }
            let char = Self.isNull(cell) ? " " : terminal.getCharacter(for: cell)
            signature += "\(char)[\(sgrParams(for: cell.attribute))]"
        }
        return signature
    }
}
