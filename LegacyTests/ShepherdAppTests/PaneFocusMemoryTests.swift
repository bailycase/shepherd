import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// Switching to an agent must restore the pane you were last working in
/// there. Previously every selection snapped focus back to the agent's pi
/// pane, so ⌘1–9 lost the side shell you were typing in.
@Suite("Pane focus memory")
struct PaneFocusMemoryTests {
    /// An agent layout: pi pane on the left, side shell on the right.
    private func makeLayout() -> (tab: TabID, pi: LeafPane, shell: LeafPane, layout: PaneNode) {
        let pi = LeafPane(cwd: "/tmp", agentID: AgentID())
        let shell = LeafPane(cwd: "/tmp")
        return (
            TabID(),
            pi,
            shell,
            .split(axis: .vertical, ratio: 0.65, first: .leaf(pi), second: .leaf(shell))
        )
    }

    @Test func restoresTheLastFocusedPaneRatherThanTheAgentPane() {
        let (tab, pi, shell, layout) = makeLayout()
        var memory = PaneFocusMemory()

        // Fresh layout: no memory yet, so the agent's own pane wins.
        #expect(memory.focus(enteringTab: tab, layout: layout, fallback: pi.id) == pi.id)

        // User clicks into the side shell, then switches away and back.
        memory.record(pane: shell.id, inTab: tab)
        #expect(memory.focus(enteringTab: tab, layout: layout, fallback: pi.id) == shell.id)
    }

    /// A remembered pane that no longer exists (closed, or a layout rebuilt by
    /// a restore) must never be focused.
    @Test func ignoresARememberedPaneThatIsGone() {
        let (tab, pi, shell, layout) = makeLayout()
        var memory = PaneFocusMemory()
        memory.record(pane: shell.id, inTab: tab)

        // The shell pane is closed; only the pi pane remains.
        let collapsed = PaneNode.leaf(pi)
        #expect(memory.focus(enteringTab: tab, layout: collapsed, fallback: pi.id) == pi.id)

        // With no usable fallback either, focus lands on the first leaf.
        #expect(memory.focus(enteringTab: tab, layout: collapsed, fallback: PaneID()) == pi.id)
    }

    /// Each layout remembers its own pane; switching between agents must not
    /// leak focus from one into the other.
    @Test func remembersEachLayoutIndependently() {
        let a = makeLayout()
        let b = makeLayout()
        var memory = PaneFocusMemory()

        memory.record(pane: a.shell.id, inTab: a.tab)
        memory.record(pane: b.pi.id, inTab: b.tab)

        #expect(memory.focus(enteringTab: a.tab, layout: a.layout, fallback: a.pi.id) == a.shell.id)
        #expect(memory.focus(enteringTab: b.tab, layout: b.layout, fallback: b.pi.id) == b.pi.id)
    }

    /// Retired agents must not leave entries behind forever.
    @Test func pruningForgetsLayoutsThatNoLongerExist() {
        let a = makeLayout()
        let b = makeLayout()
        var memory = PaneFocusMemory()
        memory.record(pane: a.shell.id, inTab: a.tab)
        memory.record(pane: b.shell.id, inTab: b.tab)

        memory.prune(liveTabs: [b.tab])

        #expect(memory.remembered(forTab: a.tab) == nil)
        #expect(memory.remembered(forTab: b.tab) == b.shell.id)
    }
}
