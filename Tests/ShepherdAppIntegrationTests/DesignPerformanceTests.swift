import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// The design canvas's budgets (docs/designs.md › Performance), as counts over a synthesized
/// 172-board canvas in an off-screen window: opening it holds at most six web views, panning
/// recycles them within that, and one board changing redraws that board's frame once with one
/// snapshot. Counts hold on a slow machine; timings would not.
@Suite("Design performance", .mainActorExclusive)
@MainActor
struct DesignPerformanceTests {
    /// Live views plus the rasterizer's one.
    private static let webViewBudget = DesignLivePlan.liveCap + 1
    private static let boards = DesignFixtures.grid(172, perRow: 12)

    /// The 172-board design on screen, settled at `zoom` with its top-leading corner in view.
    private func openLargeCanvas(_ app: AppHarness, zoom: CGFloat = 0.5) async throws
        -> (vm: ShepherdViewModel, window: OffscreenWindow, screen: DesignScreenModel, host: DesignHost) {
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Large canvas", in: space)
        let design = Design(name: "Large canvas", spaceID: space.id, agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(Self.boards, in: design.id, on: app.server, perRow: 12)
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        let host = try #require(screen.host)
        try await eventuallyOnMain("the canvas to fit its boards", timeout: .seconds(30)) {
            window.layout()
            return screen.snapshot?.index.boards.count == Self.boards.count && screen.viewport.zoom < 1
        }
        screen.viewport = NWCanvasViewport(offset: CGPoint(x: 44, y: 52), zoom: zoom)
        screen.planLive()
        try await eventuallyOnMain("every board on screen to draw", timeout: .seconds(90)) {
            window.layout()
            return screen.isDrawn && host.liveCount == DesignLivePlan.liveCap
        }
        return (vm, window, screen, host)
    }

    @Test func openingALargeCanvasHoldsAtMostSixWebViewsAndBuildsOnlyTheBoardsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        var opened: (vm: ShepherdViewModel, window: OffscreenWindow, screen: DesignScreenModel, host: DesignHost)!
        let counts = try await ListPerf.countingAsync { opened = try await openLargeCanvas(app) }
        defer { opened.window.close() }
        let visible = opened.screen.visibleBoards.count
        #expect(visible > DesignLivePlan.liveCap && visible < Self.boards.count)
        #expect(opened.vm.designRendering.rasterizer.peakWebViews <= Self.webViewBudget)
        #expect(opened.host.liveCount == DesignLivePlan.liveCap)
        // Frames built: the boards on screen, each drawn a few times as its view and snapshot land.
        #expect(counts["design.board", default: 0] < visible * 8, "\(counts)")
    }

    /// Panning across the canvas moves the live views along with it and never holds more than six.
    @Test func panningRecyclesTheLiveViews() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, screen, host) = try await openLargeCanvas(app)
        defer { window.close() }
        let rasterizer = vm.designRendering.rasterizer
        rasterizer.resetPeak()
        let first = host.liveBoards
        var seen = first
        for step in 1...4 {
            screen.viewport = NWCanvasViewport(offset: CGPoint(x: 44 - CGFloat(step) * 600, y: 52 - CGFloat(step) * 180), zoom: 0.5)
            screen.planLive()
            try await eventuallyOnMain("the boards on screen after pan \(step) to draw", timeout: .seconds(60)) {
                window.layout()
                return screen.isDrawn && host.liveCount == DesignLivePlan.liveCap
            }
            #expect(host.liveCount <= DesignLivePlan.liveCap)
            #expect(host.liveBoards.isSubset(of: Set(screen.visibleBoards)), "live views follow the view")
            seen.formUnion(host.liveBoards)
        }
        #expect(rasterizer.peakWebViews <= Self.webViewBudget)
        #expect(host.liveBoards.isDisjoint(with: first), "the first boards' views went to the boards now on screen")
        #expect(seen.count > DesignLivePlan.liveCap * 2)
    }

    /// One board changing on a canvas of 172: that board's frame redraws once and one snapshot is
    /// taken, whether it drew from a snapshot or a live view.
    @Test(arguments: [false, true])
    func oneBoardChangingRedrawsThatBoardAlone(live: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, screen, host) = try await openLargeCanvas(app)
        defer { window.close() }
        let design = screen.designID
        let target = try #require(screen.visibleBoards.first { host.liveBoards.contains($0) == live })
        let board = try #require(Self.boards.first { $0.path == target.rawValue })
        let snapshots = host.snapshotsTaken

        let counts = try await ListPerf.countingAsync {
            let written = try await app.server.writeDesignBoard(design, path: target, source: DesignFixtures.source(board, note: "changed"))
            try await eventuallyOnMain("\(target) to show the change", timeout: .seconds(30)) {
                window.layout()
                return screen.snapshot?.boards[target] == written.sha256 && host.isDrawn([target]) && host.snapshotsTaken > snapshots
            }
            window.layout()
        }
        #expect(counts["design.board", default: 0] == 1, "\(counts)")
        #expect(host.snapshotsTaken == snapshots + 1)
    }

    /// Selecting an element on a live board, and the pointer ringing one, draw rings over the
    /// boards: no board frame redraws.
    @Test func selectingAnElementRedrawsNoBoardFrame() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, screen, host) = try await openLargeCanvas(app)
        defer { window.close() }
        let target = try #require(screen.visibleBoards.first { host.liveBoards.contains($0) })
        let heading = CGPoint(x: 100, y: 45)

        let counts = try await ListPerf.countingAsync {
            screen.pick(NWCanvasPick(board: target.rawValue, point: heading))
            try await eventuallyOnMain("an element on \(target) to be selected", timeout: .seconds(30)) {
                window.layout()
                return !screen.isPicking && screen.selectedElements.count == 1
            }
            screen.pointer(NWCanvasPick(board: target.rawValue, point: heading))
            try await eventuallyOnMain("the element under the pointer to be ringed", timeout: .seconds(30)) {
                window.layout()
                return screen.hover != nil
            }
            window.layout()
        }
        #expect(counts["design.board", default: 0] == 0, "\(counts)")
    }

    /// Tweak (DZTweak): dragging a slider previews in the board's live view and redraws no board
    /// frame; letting go writes once, and only the tweaked board's frame redraws.
    @Test func aTweakDragRedrawsOnlyTheTweakedBoard() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, screen, host) = try await openLargeCanvas(app)
        defer { window.close() }
        let tweak = try #require(screen.tweak)
        let target = try #require(screen.visibleBoards.first { host.liveBoards.contains($0) })
        screen.pick(NWCanvasPick(board: target.rawValue, point: CGPoint(x: 100, y: 45)))
        try await eventuallyOnMain("an element on \(target) to be selected", timeout: .seconds(30)) {
            !screen.isPicking && screen.selectedElements.count == 1
        }
        await tweak.select(screen.tweakTarget)
        guard case .steps(let values, _)? = tweak.presentation.groups.flatMap(\.rows).first(where: { $0.id == .style(.padding) })?.control else {
            Issue.record("the selected element offers no padding: \(tweak.presentation)")
            return
        }
        let before = try await app.server.designSnapshot(screen.designID).revision

        let dragging = try await ListPerf.countingAsync {
            for index in [4, 6, 8, 10, 8] where index < values.count { tweak.setStep(.padding, index: index, phase: .changed) }
            try await eventuallyOnMain("the drag to show in the live view") { tweak.previews > 0 }
            window.layout()
        }
        #expect(dragging["design.board", default: 0] == 0, "\(dragging)")
        #expect(try await app.server.designSnapshot(screen.designID).revision == before, "nothing written while dragging")

        let released = try await ListPerf.countingAsync {
            tweak.setStep(.padding, index: min(8, values.count - 1), phase: .ended)
            try await eventuallyOnMain("the tweak to be written and drawn", timeout: .seconds(30)) {
                window.layout()
                return tweak.writes == 1 && screen.snapshot?.revision == before + 1 && host.isDrawn([target])
            }
            window.layout()
        }
        #expect(released["design.board", default: 0] == 1, "\(released)")
    }
}

extension ListPerf {
    /// `counting` for work that awaits.
    @MainActor
    static func countingAsync(_ work: () async throws -> Void) async throws -> [String: Int] {
        NWRenderProbe.start()
        do {
            try await work()
        } catch {
            NWRenderProbe.stop()
            throw error
        }
        return NWRenderProbe.stop()
    }
}
