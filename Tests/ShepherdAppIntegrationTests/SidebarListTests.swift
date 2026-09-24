import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar as one lazy list: keyboard selection still scrolls a row that was never built
/// into view, and the list's one drop target lands a reorder where its line is drawn.
@Suite("Sidebar list", .mainActorExclusive)
@MainActor
struct SidebarListTests {
    private static let size = CGSize(width: AppLayout.sidebarDefaultWidth, height: 600)

    @Test func selectingAnAgentFarDownTheFleetScrollsItsRowIntoView() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        let window = OffscreenWindow(size: Self.size, dark: true, SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))
        #expect(scroll.contentView.bounds.minY < 1)

        // The last row in sidebar order, as ⌘↑ from the first agent reaches it.
        let last = try #require(vm.orderedAgents.last)
        vm.selectAgent(last.id)

        try await eventuallyOnMain("the sidebar to scroll to the last row") {
            window.layout()
            let document = scroll.documentView?.bounds.height ?? 0
            return scroll.contentView.bounds.maxY > document - 2 * NWDensity.standard.rowHeight
        }
    }

    /// Two spaces with three agents each.
    private func twoSpaces(_ app: AppHarness) async throws -> (ShepherdViewModel, [AgentFixture]) {
        let one = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let two = Fixture.space("two", path: app.dir.appendingPathComponent("two").path)
        let agents = (0..<3).map { Fixture.agent("one-\($0)", in: one, order: $0) }
            + (0..<3).map { Fixture.agent("two-\($0)", in: two, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [one, two], agents: agents))
        return (vm, agents)
    }

    /// Where each drop row sits, top to bottom, sampled down the list.
    private func rows(_ zone: SidebarDropZone) -> [(id: AnyHashable, frame: CGRect)] {
        var found: [(id: AnyHashable, frame: CGRect)] = []
        for y in stride(from: CGFloat(0), to: Self.size.height, by: 2) {
            if let row = zone.row(at: CGPoint(x: 40, y: y)), found.last?.id != row.id { found.append((row.id, row.frame)) }
        }
        return found
    }

    @Test func dropARowOnTheLowerHalfOfAnotherAndItLandsBelowIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await twoSpaces(app)
        let zone = SidebarDropZone()
        let window = OffscreenWindow(size: Self.size, dark: true, SidebarView(vm: vm, dropZone: zone))
        defer { window.close() }
        ListPerf.settle(window)

        let rows = rows(zone)
        // Both spaces and all six agents take drops; the section header doesn't.
        #expect(rows.count == 8, "\(rows.map(\.id))")
        let target = try #require(rows.first { $0.id == AnyHashable(agents[2].agent.id) })
        let payload = ShepherdViewModel.dragPayload(agent: agents[0].agent.id)

        #expect(zone.hover(payload, at: CGPoint(x: 40, y: target.frame.maxY - 3), vm: vm))
        #expect(zone.line?.row == AnyHashable(agents[2].agent.id) && zone.line?.edge == .below)
        #expect(zone.drop(payload, vm: vm))
        #expect(zone.line == nil)
        let order = vm.state.agents.filter { $0.spaceID == agents[0].space.id }.map(\.name)
        #expect(order == ["one-1", "one-2", "one-0"])
    }

    @Test func aDropOverAHeaderOrOntoAnotherSpaceIsRefused() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await twoSpaces(app)
        let zone = SidebarDropZone()
        let window = OffscreenWindow(size: Self.size, dark: true, SidebarView(vm: vm, dropZone: zone))
        defer { window.close() }
        ListPerf.settle(window)
        let payload = ShepherdViewModel.dragPayload(agent: agents[0].agent.id)

        // Above the first space row: the "This Mac" header.
        let first = try #require(rows(zone).first)
        #expect(!zone.hover(payload, at: CGPoint(x: 40, y: first.frame.minY - 4), vm: vm))
        #expect(zone.line == nil)

        let elsewhere = try #require(rows(zone).first { $0.id == AnyHashable(agents[4].agent.id) })
        #expect(!zone.hover(payload, at: CGPoint(x: 40, y: elsewhere.frame.midY), vm: vm))
        #expect(zone.line == nil)
    }
}
