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
/// 172-board canvas in an off-screen window: opening it holds at most six web views, and panning
/// recycles them within that. Counts hold on a slow machine; timings would not.
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
