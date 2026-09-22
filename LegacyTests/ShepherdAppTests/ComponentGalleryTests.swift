import SwiftUI
import Testing
import ShepherdCore
import ShepherdDesign
import ShepherdProtocol
@testable import ShepherdApp

@Suite("Component gallery", .serialized)
@MainActor
struct ComponentGalleryTests {
    @Test(arguments: [false, true])
    func galleryRendersInBothAppearances(dark: Bool) async throws {
        try await renderScreenshot(ComponentGallery(), size: CGSize(width: 1440, height: 1320),
                                   name: "components-\(dark ? "dark" : "light")", dark: dark)
    }

    @Test(arguments: [false, true])
    func paletteRendersTheSpecBoard(dark: Bool) async throws {
        let agent = AgentID()
        let items: [PaletteItem] = [
            .init(id: "1", kind: .action("newAgent"), section: .commands, title: "New agent", subtitle: "in Shepherd/", shortcut: "⌘N", icon: "plus"),
            .init(id: "2", kind: .action("o"), section: .commands, title: "New agent with options…", shortcut: "⇧⌘T", icon: "slider.horizontal.3"),
            .init(id: "3", kind: .action("s"), section: .commands, title: "New space…", shortcut: "⇧⌘N", icon: "square.stack"),
            .init(id: "4", kind: .action("r"), section: .commands, title: "New space on horizon…", subtitle: "remote", icon: "dot.radiowaves.left.and.right"),
            .init(id: "5", kind: .action("sh"), section: .commands, title: "New shell", shortcut: "⌘T", icon: "terminal"),
            .init(id: "6", kind: .action("rename"), section: .thisThread, title: "Rename", subtitle: "Investigate SwiftUI live preview capabilities", shortcut: "⌘R", icon: "pencil"),
            .init(id: "7", kind: .action("d"), section: .thisThread, title: "Review diff", subtitle: "working tree", icon: "plus.forwardslash.minus"),
            .init(id: "8", kind: .action("p"), section: .thisThread, title: "Review PR changes", subtitle: "PR #24", icon: "arrow.triangle.pull"),
            .init(id: "9", kind: .child(agentID: agent, child: ChildRun(runID: "a", label: "claude-header-path", state: "complete")), section: .subagents,
                  title: "claude-header-path", subtitle: "Fix Pi gpt-6-astra selection · done", icon: "arrow.turn.down.right"),
            .init(id: "10", kind: .child(agentID: agent, child: ChildRun(runID: "b", label: "worker", state: "running")), section: .subagents,
                  title: "worker", subtitle: "Investigate SwiftUI live preview · running 37m", icon: "arrow.turn.down.right"),
        ]
        let board = ZStack(alignment: .top) {
            Tokens.bgSurface
            Tokens.scrim
            PaletteCard(items: items, run: { _ in }, close: {}).padding(.top, Metrics.paletteTop)
        }
        try await renderScreenshot(board, size: CGSize(width: 1000, height: 700), name: "palette-\(dark ? "dark" : "light")", dark: dark)
    }
}
