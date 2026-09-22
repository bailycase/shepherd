import SwiftUI
import Testing
import ShepherdCore
@testable import ShepherdDesign

/// Density and text scale live on the shared `ThemeStore`, so these run serialized and restore
/// the defaults.
@Suite("Density and text scale", .serialized)
@MainActor
struct DensityTests {
    private func withDensity(_ density: CGFloat, _ body: () -> Void) {
        let saved = ThemeStore.shared.density
        ThemeStore.shared.density = density
        defer { ThemeStore.shared.density = saved }
        body()
    }

    @Test func designedDensityGivesTheDenseSidebar() {
        withDensity(1) {
            #expect(Metrics.sidebarRowHeight == 26)
            #expect(Metrics.sidebarRowHeightCompact == 22)
            #expect(Metrics.settingsRowMinHeight == 52)
        }
    }

    @Test(arguments: [(0.85, 22.0, 19.0, 44.0), (1.2, 31.0, 26.0, 62.0)])
    func rowHeightsScaleAndRoundToWholePoints(density: Double, row: Double, compact: Double, settings: Double) {
        withDensity(CGFloat(density)) {
            #expect(Metrics.sidebarRowHeight == CGFloat(row))
            #expect(Metrics.sidebarRowHeightCompact == CGFloat(compact))
            #expect(Metrics.settingsRowMinHeight == CGFloat(settings))
        }
    }

    @Test func densityLeavesFixedSizesAlone() {
        withDensity(1.3) {
            #expect(Metrics.toolRowHeight == 36)
            #expect(Metrics.headerHeight == 52)
        }
    }

    @Test(arguments: [1.0, 1.25])
    func leadingScalesWithTextSize(scale: Double) {
        let saved = ThemeStore.shared.textScale
        ThemeStore.shared.textScale = CGFloat(scale)
        defer { ThemeStore.shared.textScale = saved }
        #expect(Fonts.bodyLeading == 15 * CGFloat(scale) * 0.6 - 3)
        #expect(Fonts.outputLeading == 12 * CGFloat(scale) * 0.55 - 2)
    }
}

@Suite("Layout constants")
struct LayoutConstantTests {
    @Test func proseIsNarrowerThanTheThreadColumn() {
        #expect(Metrics.userMaxWidth < Metrics.proseMaxWidth)
        #expect(Metrics.proseMaxWidth < Metrics.threadMaxWidth)
    }

    @Test func theWindowMinimumFitsTheMainColumnBesideTheFullSidebar() {
        #expect(Metrics.mainColumnMinWidth + Metrics.sidebarDefaultWidth <= Metrics.windowMinWidth)
    }
}

@Suite("Status tokens")
@MainActor
struct StatusTokenTests {
    @Test func runningIsAliveGreenAndBlockedIsWarning() {
        #expect(Tokens.statusDot(.working) == Tokens.success)
        #expect(Tokens.statusDot(.blocked) == Tokens.warning)
    }

    @Test(arguments: [AgentStatus.idle, .done])
    func restingAgentsAreGreyUnlessTheyAreTheOpenThread(_ status: AgentStatus) {
        #expect(Tokens.statusDot(status) == Tokens.dotIdle)
        #expect(Tokens.statusDot(status, isCurrent: true) == Tokens.accent)
    }

    @Test func pillStatesHaveTheirSpecLabels() {
        let states: [AgentPillState] = [.idle, .running, .needsYou, .error, .stopped]
        #expect(states.map(StatusPill.defaultLabel) == ["Idle", "Running", "Needs you", "Error", "Stopped"])
    }
}
