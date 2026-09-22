import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// A pane's PTY must be created at the grid the surface will actually render,
/// not at a placeholder size. Spawning at 80×24 made pi paint its whole TUI
/// for the wrong terminal and visibly reflow on the first resize.
@Suite("Pane grid handshake")
@MainActor
struct PaneGridTests {
    @Test func awaitGridResumesOnFirstSurfaceReport() async {
        let session = TerminalSessionStore.PaneSession(paneID: PaneID())
        #expect(session.lastCols == 80 && session.lastRows == 24)

        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            session.noteGrid(cols: 150, rows: 50)
        }

        // Generous budget: this must resolve via the report, not the timeout.
        await session.awaitGrid(timeoutNanoseconds: 5_000_000_000)
        #expect(session.lastCols == 150)
        #expect(session.lastRows == 50)
    }

    /// A surface that already reported must not wait at all.
    @Test func awaitGridReturnsImmediatelyOnceReported() async {
        let session = TerminalSessionStore.PaneSession(paneID: PaneID())
        session.noteGrid(cols: 96, rows: 48)

        let start = Date()
        await session.awaitGrid(timeoutNanoseconds: 5_000_000_000)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(session.lastCols == 96 && session.lastRows == 48)
    }

    /// A pane whose surface never lays out must still get its process, at the
    /// fallback grid, rather than hanging forever.
    @Test func awaitGridFallsBackWhenNoReportArrives() async {
        let session = TerminalSessionStore.PaneSession(paneID: PaneID())
        await session.awaitGrid(timeoutNanoseconds: 50_000_000)
        #expect(session.lastCols == 80 && session.lastRows == 24)
    }
}
