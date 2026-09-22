import Foundation
import SwiftTerm
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// Feeds `screen` the UTF-8 bytes of `text`.
private func feed(_ screen: SessionScreen, _ text: String) {
    screen.feed(Data(text.utf8))
}

/// Round-trips `screen` through its own snapshot into a fresh same-size
/// screen and returns the reconstruction.
private func reconstruct(_ screen: SessionScreen) -> SessionScreen {
    let fresh = SessionScreen(cols: screen.cols, rows: screen.rows)
    fresh.feed(screen.snapshot())
    return fresh
}

/// Asserts two screens render identically: text and attributes of every
/// visible row, plus the cursor position.
private func expectSameScreen(_ a: SessionScreen, _ b: SessionScreen) {
    #expect(a.cols == b.cols)
    #expect(a.rows == b.rows)
    for row in 0..<a.rows {
        #expect(
            a.visibleText(row: row) == b.visibleText(row: row),
            "text mismatch at row \(row): \(a.visibleText(row: row)) vs \(b.visibleText(row: row))"
        )
        #expect(
            a.rowSignature(row: row) == b.rowSignature(row: row),
            "attribute mismatch at row \(row)"
        )
    }
    let ac = a.cursorPosition
    let bc = b.cursorPosition
    #expect(ac.col == bc.col && ac.row == bc.row, "cursor mismatch: \(ac) vs \(bc)")
}

@Suite("Session screen snapshots")
struct SessionScreenTests {
    @Test func roundTripReproducesScreenAndCursor() {
        let a = SessionScreen(cols: 80, rows: 24)
        // Enough output to push lines into scrollback.
        for i in 0..<30 {
            feed(a, "line \(i) with some content\r\n")
        }
        // Colored text, absolute cursor moves, and a prompt-redraw loop
        // (the raw-replay killer: CR + clear-line + rewrite, repeatedly).
        feed(a, "\u{1b}[31mred\u{1b}[0m and \u{1b}[1;4;32mbold-green-underline\u{1b}[0m\r\n")
        feed(a, "\u{1b}[10;5HGRID\u{1b}[10;40H\u{1b}[7mmarker\u{1b}[0m")
        feed(a, "\u{1b}[12;1H")
        for i in 0..<5 {
            feed(a, "\r\u{1b}[K> some text \(i)")
        }

        let b = reconstruct(a)
        expectSameScreen(a, b)
        #expect(b.visibleText(row: 11) == "> some text 4")
        // The reconstruction carries the same amount of scrollback.
        #expect(a.terminal.getTopVisibleRow() == b.terminal.getTopVisibleRow())
    }

    @Test func snapshotReproducesAfterResize() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, String(repeating: "X", count: 100))
        feed(a, "\r\ntail line\r\n")
        feed(a, "\u{1b}[35mstyled after wrap\u{1b}[0m")
        a.resize(cols: 100, rows: 24)

        // The snapshot must reproduce on a fresh 100-col screen with no
        // artifacts, whatever reflow did to the 80-col content.
        let b = reconstruct(a)
        #expect(b.cols == 100)
        expectSameScreen(a, b)
        let joined = b.visibleText().joined(separator: "\n")
        #expect(joined.contains("tail line"))
        #expect(joined.contains("styled after wrap"))
    }

    @Test func colorsAndAttributesSurviveRoundTrip() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, "\u{1b}[38;5;196mA\u{1b}[0m")            // 256-color fg
        feed(a, "\u{1b}[48;5;24mB\u{1b}[0m")             // 256-color bg
        feed(a, "\u{1b}[38;2;12;34;56mC\u{1b}[0m")       // truecolor fg
        feed(a, "\u{1b}[48;2;65;43;21mD\u{1b}[0m")       // truecolor bg
        feed(a, "\u{1b}[1mE\u{1b}[0m")                   // bold
        feed(a, "\u{1b}[2mF\u{1b}[0m")                   // dim
        feed(a, "\u{1b}[3mG\u{1b}[0m")                   // italic
        feed(a, "\u{1b}[4mH\u{1b}[0m")                   // underline
        feed(a, "\u{1b}[7mI\u{1b}[0m")                   // inverse
        feed(a, "\u{1b}[1;4;33;44mJ\u{1b}[0m")           // combined
        feed(a, "\u{1b}[94mK\u{1b}[0m")                  // bright fg
        feed(a, "\u{1b}[101mL\u{1b}[0m")                 // bright bg

        let b = reconstruct(a)
        expectSameScreen(a, b)
        // Cell-level attribute equality, not just the signature rendering.
        for col in 0..<12 {
            let aCell = a.terminal.getCharData(col: col, row: 0)
            let bCell = b.terminal.getCharData(col: col, row: 0)
            #expect(aCell?.attribute == bCell?.attribute, "attribute differs at col \(col)")
            #expect(aCell.map { a.terminal.getCharacter(for: $0) } == bCell.map { b.terminal.getCharacter(for: $0) })
        }
    }

    @Test func wideCharactersEmitOnce() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, "宽 characters \u{1b}[31m漢字\u{1b}[0m end")

        let b = reconstruct(a)
        expectSameScreen(a, b)
        #expect(b.visibleText(row: 0).contains("宽 characters 漢字 end"))
        // The wide cell occupies two columns; its continuation stub must not
        // have been emitted as a second copy or an extra space.
        #expect(b.terminal.getCharData(col: 0, row: 0)?.width == 2)
        #expect(b.terminal.getCharData(col: 1, row: 0)?.width == 0)
        #expect(b.terminal.getCharacter(col: 2, row: 0) == " ")
    }

    @Test func altScreenRoundTrip() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, "before alt\r\n")
        feed(a, "\u{1b}[?1049h\u{1b}[H\u{1b}[2J")
        feed(a, "\u{1b}[1;1HALT TOP \u{1b}[7minverse\u{1b}[0m")
        feed(a, "\u{1b}[5;10H\u{1b}[38;5;208mmiddle\u{1b}[0m")
        feed(a, "\u{1b}[3;4H")
        #expect(a.isAlternateScreenActive)

        let b = reconstruct(a)
        #expect(b.isAlternateScreenActive)
        expectSameScreen(a, b)

        // Leaving the alt screen must land on the normal-buffer content
        // (text fidelity; attributes are not preserved for the inactive
        // normal buffer — SwiftTerm only exposes it as plain text).
        feed(a, "\u{1b}[?1049l")
        feed(b, "\u{1b}[?1049l")
        #expect(!b.isAlternateScreenActive)
        for row in 0..<a.rows {
            #expect(a.visibleText(row: row) == b.visibleText(row: row), "post-alt text mismatch at row \(row)")
        }
    }

    @Test func interactionModesAreReArmed() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, "\u{1b}[?25l\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h")

        let b = reconstruct(a)
        #expect(b.isCursorHidden)
        #expect(b.terminal.applicationCursor)
        #expect(b.terminal.bracketedPasteMode)
        #expect(b.terminal.mouseMode == .buttonEventTracking)
    }

    /// A snapshot is a whole-screen restore, so it must erase the receiver's
    /// saved lines too. Ghostty keeps scrollback across RIS, so without an
    /// explicit ESC[3J a re-attach (theme switch, surface rebuild, split
    /// collapse) leaves the previous content scrolled above the restored
    /// screen — which showed pi's startup warning twice in agent panes.
    @Test func snapshotErasesReceiverScrollback() {
        let source = SessionScreen(cols: 80, rows: 24)
        feed(source, "startup warning line\r\n$ ")

        let snapshot = source.snapshot()
        let text = String(decoding: snapshot, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}c\u{1b}[3J"), "snapshot must reset and erase saved lines first")

        // Replaying into a surface that already shows the same output must
        // leave exactly one copy, with nothing pushed into scrollback.
        let surface = SessionScreen(cols: 80, rows: 24)
        feed(surface, "startup warning line\r\n$ ")
        surface.feed(snapshot)
        expectSameScreen(source, surface)
        #expect(surface.terminal.getTopVisibleRow() == 0, "replay must not leave scrollback above the screen")
    }

    @Test func deadSessionSnapshotIsDeterministic() {
        let a = SessionScreen(cols: 80, rows: 24)
        feed(a, "final output\r\n$ ")
        let first = a.snapshot()
        let second = a.snapshot()
        #expect(first == second)
        // Snapshotting must not perturb the screen it serializes.
        let b = SessionScreen(cols: 80, rows: 24)
        b.feed(first)
        expectSameScreen(a, b)
    }
}
