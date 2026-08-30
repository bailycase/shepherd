import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp

/// Keyboard navigation scrolls the sidebar to whatever this returns, so a
/// wrong (or stale) target either scrolls to nothing or yanks the tree while
/// a shell or a remote agent owns the workspace.
@Suite("Sidebar reveal target")
@MainActor
struct SidebarRevealTests {
    private let root = Space(name: "root", path: "/tmp/root")
    private let child = Space(name: "child", path: "/tmp/root/child")
    private let hidden = Space(name: "automations", path: "/tmp/auto", hidden: true)

    private func target(
        agent: AgentID? = nil,
        space: SpaceID?,
        shell: Bool = false,
        remote: Bool = false,
        collapsed: Set<SpaceID> = []
    ) -> AnyHashable? {
        ShepherdViewModel.sidebarRevealTarget(
            selectedAgentID: agent,
            selectedSpaceID: space,
            shellSelected: shell,
            remoteSelected: remote,
            spaces: [root, child, hidden],
            collapsed: collapsed
        )
    }

    /// ⌘1–9 and ⌘↑/↓ select an agent: its own row is what must come into view.
    @Test func selectedAgentRowIsTheTarget() {
        let agent = AgentID()
        #expect(target(agent: agent, space: child.id) == AnyHashable(agent))
    }

    /// A space row selection (and ⌃⇧1 back to a space with no agent) targets
    /// the space header row.
    @Test func spaceRowIsTheTargetWithoutAnAgent() {
        #expect(target(space: root.id) == AnyHashable(root.id))
    }

    /// A collapsed space hides its agent rows; the header is the only row left.
    @Test func collapsedSpaceFallsBackToItsHeader() {
        let agent = AgentID()
        #expect(target(agent: agent, space: root.id, collapsed: [root.id]) == AnyHashable(root.id))
    }

    /// A collapsed parent hides the nested space entirely — nothing to reveal.
    /// Selection never leaves the tree in this shape (it opens the ancestors
    /// first, below); only a manual collapse after selecting can.
    @Test func spaceUnderACollapsedParentHasNoTarget() {
        #expect(target(agent: AgentID(), space: child.id, collapsed: [root.id]) == nil)
    }

    /// Shell and remote selections own the workspace; the local tree must not
    /// scroll under them.
    @Test func shellAndRemoteSelectionsSuppressScrolling() {
        #expect(target(agent: AgentID(), space: root.id, shell: true) == nil)
        #expect(target(agent: AgentID(), space: root.id, remote: true) == nil)
    }

    /// Hidden spaces (the reserved automations space) render no row.
    @Test func hiddenSpacesAndUnknownSelectionsHaveNoTarget() {
        #expect(target(agent: AgentID(), space: hidden.id) == nil)
        #expect(target(space: SpaceID()) == nil)
        #expect(target(space: nil) == nil)
    }

    // MARK: Ancestors

    /// The disclosures a selection must open are the space's ancestors in the
    /// path-containment forest, nearest first.
    @Test func ancestorsFollowPathContainment() {
        let grandchild = Space(name: "deep", path: "/tmp/root/child/deep")
        let spaces = [root, child, grandchild]
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: grandchild.id, in: spaces) == [child.id, root.id])
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: child.id, in: spaces) == [root.id])
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: root.id, in: spaces).isEmpty)
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: SpaceID(), in: spaces).isEmpty)
    }
}

/// Selecting locally has to make the selected row exist before anything can
/// scroll to it: a collapsed THIS MAC root hides the whole local tree, and a
/// collapsed ancestor hides a nested space's row.
@Suite("Local selection reveal", .serialized)
@MainActor
struct LocalSelectionRevealTests {
    private struct Fixture {
        let dir: URL
        let vm: ShepherdViewModel
        let root: Space
        let child: Space
        let agent: Agent

        @MainActor init() {
            dir = URL(
                fileURLWithPath: "/tmp/shepherd-reveal-\(UInt32.random(in: 0..<1_000_000))",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Never started: these tests only exercise view-model selection.
            let server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            let defaults = UserDefaults(suiteName: "shepherd.reveal.\(UUID().uuidString)")!
            vm = ShepherdViewModel(server: server, sidebarDefaults: defaults)
            root = Space(name: "root", path: "/tmp/reveal-root")
            child = Space(name: "child", path: "/tmp/reveal-root/child")
            let tab = Tab(spaceID: child.id, order: 0, layout: .leaf(LeafPane(cwd: child.path)))
            agent = Agent(name: "nested", spaceID: child.id, tabID: tab.id)
            vm.state = ShepherdState(spaces: [root, child], tabs: [tab], agents: [agent])
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// F1: with hosts present the local tree can be collapsed away entirely;
    /// a local agent selection (⌘1–9, ⌘↑/↓, palette, menu) must bring it back.
    @Test func selectingAnAgentOpensTheLocalMachineRoot() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.localMachineCollapsed = true
        fixture.vm.selectAgent(fixture.agent.id)
        #expect(fixture.vm.localMachineCollapsed == false)
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.agent.id))
    }

    /// F3: a nested space picked from the palette or the Space menu while its
    /// parent is collapsed must end up with a visible row.
    @Test func selectingANestedSpaceOpensItsAncestors() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.collapsedSpaces = [fixture.root.id]
        fixture.vm.selectSpace(fixture.child.id)
        #expect(fixture.vm.collapsedSpaces.contains(fixture.root.id) == false)
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.child.id))
    }

    /// Same for an agent nested under a collapsed parent space.
    @Test func selectingANestedAgentOpensItsAncestors() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.collapsedSpaces = [fixture.root.id]
        fixture.vm.localMachineCollapsed = true
        fixture.vm.selectAgent(fixture.agent.id)
        #expect(fixture.vm.collapsedSpaces.isEmpty)
        #expect(fixture.vm.localMachineCollapsed == false)
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.agent.id))
    }

    /// The selected space's own disclosure is left alone — its header row is
    /// still on screen and is what gets revealed.
    @Test func theSelectedSpacesOwnDisclosureIsPreserved() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.collapsedSpaces = [fixture.root.id, fixture.child.id]
        fixture.vm.selectAgent(fixture.agent.id)
        #expect(fixture.vm.collapsedSpaces == [fixture.child.id])
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.child.id))
    }

    /// ⌃⇧1 returns to the local machine; the tree it returns to must be open.
    @Test func machineJumpBackToLocalOpensTheLocalTree() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.selectAgent(fixture.agent.id)
        fixture.vm.localMachineCollapsed = true
        fixture.vm.collapsedSpaces = [fixture.root.id]
        fixture.vm.jumpToMachine(1)
        #expect(fixture.vm.localMachineCollapsed == false)
        #expect(fixture.vm.collapsedSpaces.isEmpty)
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.agent.id))
    }

    /// The scroll trigger is a counter: re-selecting the same row (⌘3 twice
    /// after scrolling the sidebar away by hand) must still scroll back.
    @Test func reselectingTheSameRowStillRequestsAReveal() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.vm.selectAgent(fixture.agent.id)
        let before = fixture.vm.sidebarRevealRequest
        fixture.vm.selectAgent(fixture.agent.id)
        #expect(fixture.vm.sidebarRevealRequest > before)
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(fixture.agent.id))
    }

    /// A remote selection targets its own row in the unified tree; the ref
    /// type can never collide with a local agent or space id.
    @Test func remoteSelectionTargetsItsRow() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let ref = RemoteAgentRef(hostID: UUID(), agentID: AgentID())
        fixture.vm.selectedRemoteAgent = ref
        #expect(fixture.vm.sidebarRevealTarget == AnyHashable(ref))
        #expect(fixture.vm.sidebarRevealTarget != AnyHashable(ref.agentID))
    }
}
