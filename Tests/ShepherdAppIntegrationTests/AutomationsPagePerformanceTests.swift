import AppKit
import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Automations page's table is a long list too (DESIGN.md › Performance): it builds the
/// rows on screen, and one automation changing or the selection moving redraws only the rows
/// they touch. Counted in row bodies (`NWRenderProbe`), like `ListPerformanceTests`.
@Suite("Automations page performance", .mainActorExclusive)
@MainActor
struct AutomationsPagePerformanceTests {
    private static let size = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 800)

    /// How many table rows fit under the header and the column labels (a row is at least a
    /// switch tall plus its padding).
    private static var rowsOnScreen: Int {
        let row = NWAutomationMetrics.switchSize.height + 2 * NWPageMetrics.rowVertical
        return Int((size.height - NWPageMetrics.headerHeight) / row) + 1
    }

    /// Two hundred automations, off, so the first adoption starts no run; their run logs read.
    private func page(_ app: AppHarness) async throws -> (ShepherdViewModel, OffscreenWindow) {
        let automations = (0..<200).map { Automation(name: "Automation \($0)", prompt: "watch \($0)", cwd: app.dir.path, enabled: false) }
        let vm = try await app.start(with: ShepherdState(automations: automations))
        await vm.loadAutomationPageRuns()
        let window = OffscreenWindow(size: Self.size, dark: true, AutomationsDestination(vm: vm))
        ListPerf.settle(window)
        // The server's launch broadcasts and the page's own read of the runs land before counting.
        await app.settle()
        ListPerf.settle(window)
        return (vm, window)
    }

    @Test func openingThePageOverTwoHundredAutomationsBuildsOnlyTheRowsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let automations = (0..<200).map { Automation(name: "Automation \($0)", prompt: "watch \($0)", cwd: app.dir.path, enabled: false) }
        let vm = try await app.start(with: ShepherdState(automations: automations))
        await vm.loadAutomationPageRuns()
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.size, dark: true, AutomationsDestination(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(rows["automations.row", default: 0] >= Self.rowsOnScreen - 2, "the rows on screen were built: \(rows)")
        #expect(rows["automations.row", default: 0] <= 2 * Self.rowsOnScreen, "\(rows)")
    }

    /// Switching one automation redraws its row (and the detail, when it is the selected one);
    /// moving the selection redraws the row it leaves and the one it lands on.
    @Test func oneAutomationChangingOrTheSelectionMovingRedrawsOnlyTheRowsTheyTouch() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await page(app)
        defer { window.close() }
        let ids = vm.state.automations.prefix(6).map(\.id)

        let switched = ListPerf.counting {
            for id in ids {
                var next = vm.state
                if let index = next.automations.firstIndex(where: { $0.id == id }) { next.automations[index].enabled.toggle() }
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(switched["automations.row", default: 0] >= ids.count, "each switched row redrew: \(switched)")
        #expect(switched["automations.row", default: 0] <= ids.count * 2, "\(switched)")

        let moved = ListPerf.counting {
            for id in ids.dropFirst() {
                ListPerf.time(window) { vm.automationsPageSelection = AutomationKey(host: PageHost.localID, automation: id) }
            }
        }
        #expect(moved["automations.row", default: 0] <= (ids.count - 1) * 2 * 2, "\(moved)")
    }
}
