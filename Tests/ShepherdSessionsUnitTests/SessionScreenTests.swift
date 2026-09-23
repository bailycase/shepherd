import Foundation
import SwiftTerm
import Testing
@testable import ShepherdSessions

/// Replay into a fresh surface is a snapshot of the headless screen, not raw bytes: feeding the
/// snapshot to a same-size screen must reproduce text, attributes, cursor, and modes.
@Suite("Session screen snapshots")
struct SessionScreenTests {
    private func screen(_ cols: Int = 80, _ rows: Int = 24, _ output: String...) -> SessionScreen {
        let screen = SessionScreen(cols: cols, rows: rows)
        for chunk in output { screen.feed(Data(chunk.utf8)) }
        return screen
    }

    /// Round-trips `source` through its own snapshot into a fresh same-size screen.
    private func replayed(_ source: SessionScreen) -> SessionScreen {
        let fresh = SessionScreen(cols: source.cols, rows: source.rows)
        fresh.feed(source.snapshot())
        return fresh
    }

    private func expectSameScreen(_ a: SessionScreen, _ b: SessionScreen, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.cols == b.cols && a.rows == b.rows, sourceLocation: sourceLocation)
        for row in 0..<a.rows {
            #expect(a.visibleText(row: row) == b.visibleText(row: row), "text at row \(row)", sourceLocation: sourceLocation)
            #expect(a.rowSignature(row: row) == b.rowSignature(row: row), "attributes at row \(row)", sourceLocation: sourceLocation)
        }
        #expect(a.cursorPosition.col == b.cursorPosition.col && a.cursorPosition.row == b.cursorPosition.row, "cursor", sourceLocation: sourceLocation)
    }

    @Test func aReplayReproducesTextCursorAndScrollback() {
        let source = screen()
        for i in 0..<30 { source.feed(Data("line \(i) with some content\r\n".utf8)) }
        // Absolute moves and a prompt-redraw loop: the case raw byte replay gets wrong.
        source.feed(Data("\u{1b}[10;5HGRID\u{1b}[10;40H\u{1b}[7mmarker\u{1b}[0m\u{1b}[12;1H".utf8))
        for i in 0..<5 { source.feed(Data("\r\u{1b}[K> some text \(i)".utf8)) }

        let copy = replayed(source)
        expectSameScreen(source, copy)
        #expect(copy.visibleText(row: 11) == "> some text 4")
        #expect(copy.scrollbackRows == source.scrollbackRows)
    }

    @Test(arguments: [
        "\u{1b}[38;5;196mA", "\u{1b}[48;5;24mB", "\u{1b}[38;2;12;34;56mC", "\u{1b}[48;2;65;43;21mD",
        "\u{1b}[1mE", "\u{1b}[2mF", "\u{1b}[3mG", "\u{1b}[4mH", "\u{1b}[7mI", "\u{1b}[1;4;33;44mJ",
        "\u{1b}[94mK", "\u{1b}[101mL",
    ])
    func everySGRAttributeSurvivesAReplay(styled: String) {
        let source = screen(80, 24, "plain " + styled + "\u{1b}[0m after")
        let copy = replayed(source)
        expectSameScreen(source, copy)
        #expect(copy.rowSignature(row: 0) == source.rowSignature(row: 0))
    }

    @Test func aReplayAfterResizeHasNoReflowArtifacts() {
        let source = screen(80, 24, String(repeating: "X", count: 100), "\r\ntail line\r\n", "\u{1b}[35mstyled after wrap\u{1b}[0m")
        source.resize(cols: 100, rows: 24)
        let copy = replayed(source)
        #expect(copy.cols == 100)
        expectSameScreen(source, copy)
    }

    @Test func wideCharactersAreEmittedOnce() {
        let source = screen(80, 24, "宽 characters \u{1b}[31m漢字\u{1b}[0m end")
        let copy = replayed(source)
        expectSameScreen(source, copy)
        #expect(copy.visibleText(row: 0) == "宽 characters 漢字 end")
    }

    @Test func theAlternateScreenIsRestoredAboveTheNormalBuffer() {
        let source = screen(80, 24, "before alt\r\n", "\u{1b}[?1049h\u{1b}[H\u{1b}[2J",
                            "\u{1b}[1;1HALT TOP \u{1b}[7minverse\u{1b}[0m", "\u{1b}[5;10H\u{1b}[38;5;208mmiddle\u{1b}[0m", "\u{1b}[3;4H")
        let copy = replayed(source)
        #expect(copy.isAlternateScreenActive)
        expectSameScreen(source, copy)

        // Leaving the alt screen lands on the normal buffer's text.
        source.feed(Data("\u{1b}[?1049l".utf8))
        copy.feed(Data("\u{1b}[?1049l".utf8))
        #expect(!copy.isAlternateScreenActive)
        #expect(copy.visibleText() == source.visibleText())
    }

    @Test func interactionModesAreReArmed() {
        let copy = replayed(screen(80, 24, "\u{1b}[?25l\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h"))
        #expect(copy.isCursorHidden)
        #expect(copy.terminal.applicationCursor)
        #expect(copy.terminal.bracketedPasteMode)
        #expect(copy.terminal.mouseMode == .buttonEventTracking)
    }

    @Test func modesTheSourceNoLongerHasAreClearedOnTheReceiver() {
        let receiver = screen(80, 24, "\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1000h")
        receiver.feed(screen(80, 24, "fresh").snapshot())
        #expect(!receiver.isCursorHidden)
        #expect(!receiver.terminal.bracketedPasteMode)
        #expect(receiver.terminal.mouseMode == .off)
    }

    /// Ghostty keeps scrollback across RIS, so a snapshot must erase saved lines explicitly or a
    /// re-attach shows earlier output twice.
    @Test func aSnapshotReplacesTheReceiversScrollback() {
        let source = screen(80, 24, "startup warning line\r\n$ ")
        let snapshot = source.snapshot()
        #expect(String(decoding: snapshot, as: UTF8.self).hasPrefix("\u{1b}c\u{1b}[3J"))

        let surface = screen(80, 24, "startup warning line\r\n$ ")
        surface.feed(snapshot)
        expectSameScreen(source, surface)
        #expect(surface.scrollbackRows == 0)
    }

    @Test func snapshottingIsDeterministicAndDoesNotPerturbTheScreen() {
        let source = screen(80, 24, "final output\r\n$ ")
        let first = source.snapshot()
        #expect(source.snapshot() == first)
        expectSameScreen(source, replayed(source))
    }

    @Test func scrollbackIsBoundedToTheConfiguredLines() {
        let source = SessionScreen(cols: 40, rows: 5, scrollbackLines: 10)
        for i in 0..<50 { source.feed(Data("row \(i)\r\n".utf8)) }
        #expect(source.scrollbackRows <= 10)
        #expect(source.visibleText().contains("row 49"))
    }
}
