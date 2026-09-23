import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Hovering a sidebar header shows its keycap and `+` in place: nothing it holds may change
/// size, or every row beneath it jumps.
@Suite("Sidebar hover", .mainActorExclusive)
@MainActor
struct SidebarHoverTests {
    private func size(_ view: some View) -> CGSize {
        NSHostingView(rootView: view.environment(\.colorScheme, .dark)).fittingSize
    }

    /// The machine header's `+` is taller than its label; it floats over the count's slot
    /// instead of joining the row. A disconnected host's header has no `+` at all.
    @Test(arguments: [true, false])
    func hoveringAMachineHeaderKeepsItsSize(connected: Bool) {
        func header(hovering: Bool) -> some View {
            NWSidebarSection("Horizon", detail: .count(5), hoverHint: "⌃⇧2", toggle: {}, hovering: hovering) {
                if connected { SidebarPlus(help: "New Space on Horizon") {} }
            }
            .frame(width: AppLayout.sidebarDefaultWidth)
        }
        #expect(size(header(hovering: true)) == size(header(hovering: false)))
    }

    /// The count and the `+` share one slot, so the worktree count and the name keep their room.
    @Test(arguments: [(count: 3, blocked: 0, worktrees: 0), (count: 12, blocked: 2, worktrees: 1)])
    func hoveringASpaceRowKeepsItsTrailingSlot(count: Int, blocked: Int, worktrees: Int) {
        let row = SpaceRow(name: "homelab-infra", collapsed: false, count: count, blocked: blocked,
                           worktrees: worktrees, onToggle: {}, onNewAgent: {})
        let rest = size(HStack(spacing: NW.Space.m) { row.trailing(hovering: false) })
        let hovered = size(HStack(spacing: NW.Space.m) { row.trailing(hovering: true) })
        #expect(hovered == rest)
    }
}
