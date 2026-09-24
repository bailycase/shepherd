import SwiftUI
import Testing
import ShepherdCore
import ShepherdRemote
import ShepherdUI
@testable import ShepherdApp

/// Density lives on the shared `ThemeStore`, so these run serialized and restore it.
@Suite("App layout", .serialized)
@MainActor
struct AppLayoutTests {
    private func withDensity(_ density: CGFloat, _ body: () -> Void) {
        let saved = ThemeStore.shared.density
        ThemeStore.shared.density = density
        defer { ThemeStore.shared.density = saved }
        body()
    }

    @Test(arguments: [(NWDensity.compact, 22.0), (.standard, 28.0), (.comfortable, 36.0)])
    func sidebarRowsFollowNightWatchAtTheDesignedDensity(rows: NWDensity, height: Double) {
        withDensity(1) {
            #expect(rows.rowHeight == CGFloat(height))
            #expect(AppLayout.settingsRowMinHeight == 52)
        }
    }

    @Test(arguments: [(0.85, 24.0, 44.0), (1.2, 34.0, 62.0)])
    func rowHeightsScaleAndRoundToWholePoints(density: Double, row: Double, settings: Double) {
        withDensity(CGFloat(density)) {
            #expect(NWDensity.standard.rowHeight == CGFloat(row))
            #expect(AppLayout.settingsRowMinHeight == CGFloat(settings))
        }
    }

    @Test func densityLeavesFixedSizesAlone() {
        withDensity(1.3) {
            #expect(AppLayout.threadMaxWidth == 820)
            #expect(AppLayout.headerHeight == 44)
        }
    }

    @Test func proseIsNarrowerThanTheThreadColumn() {
        #expect(AppLayout.userMaxWidth < AppLayout.proseMaxWidth)
        #expect(AppLayout.proseMaxWidth < AppLayout.threadMaxWidth)
    }

    /// The Navigation board's column ("thread column · max 820 · prose 640"), with the Thread
    /// board's 640pt prose measure and 600pt bubbles.
    @Test func theThreadColumnIsTheBoards820PointsWithItsProseMeasure() {
        #expect(AppLayout.threadMaxWidth == 820)
        #expect(AppLayout.proseMaxWidth == NWThreadMetrics.proseMeasure && AppLayout.proseMaxWidth == 640)
        #expect(AppLayout.userMaxWidth == NWThreadMetrics.bubbleMaxWidth && AppLayout.userMaxWidth == 600)
    }

    /// A thread keeps its 32pt gutters only while the widest column fits between them (820 +
    /// 2 × 32 = 884); narrower, it keeps its column and drops to 16pt gutters.
    @Test(arguments: [(1180.0, 32.0), (884.0, 32.0), (883.0, 16.0), (606.0, 16.0), (0.0, 16.0)])
    func aNarrowThreadKeepsItsColumnAndDropsToCompactGutters(width: Double, gutter: Double) {
        #expect(AppLayout.threadGutter(width: CGFloat(width)) == CGFloat(gutter))
    }

    @Test func theMinimumWindowIsTheMainColumnAloneSoTheSidebarOverlaysThere() {
        #expect(AppLayout.windowMinWidth == AppLayout.mainColumnMinWidth)
        #expect(ShellLayout.sidebarFitWidth(AppLayout.sidebarDefaultWidth) > AppLayout.windowMinWidth)
        #expect(ShellLayout.sidebarFitWidth(AppLayout.sidebarDefaultWidth) <= AppLayout.windowDefaultWidth)
    }
}

@Suite("Agent state mapping")
struct AgentStateMappingTests {
    @Test(arguments: [(AgentStatus.working, AgentState.running), (.blocked, .attention), (.done, .done), (.idle, .idle)])
    func agentStatusMapsToItsState(_ status: AgentStatus, _ state: AgentState) {
        #expect(AgentState(status) == state)
    }

    @Test(arguments: [(NativeSubagentState.running, AgentState.running), (.needsYou, .attention), (.done, .done), (.failed, .failed)])
    func subagentStateMapsToItsState(_ subagent: NativeSubagentState, _ state: AgentState) {
        #expect(AgentState(subagent) == state)
    }

    @Test(arguments: [(NativeToolRow.State.running, AgentState.running), (.done, .done), (.failed, .failed)])
    func toolStateMapsToItsState(_ tool: NativeToolRow.State, _ state: AgentState) {
        #expect(AgentState(tool) == state)
    }
}
