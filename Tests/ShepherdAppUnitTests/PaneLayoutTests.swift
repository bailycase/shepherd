import CoreGraphics
import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// The split tree flattens to absolute rects; every leaf stays a direct child of one ZStack so
/// changing the tree moves surfaces instead of remounting them.
@Suite("Pane tree geometry")
struct PaneTreeGeometryTests {
    private let first = LeafPane(cwd: "/tmp/first")
    private let second = LeafPane(cwd: "/tmp/second")

    private func rect(of pane: LeafPane, in geometry: PaneTreeGeometry) throws -> CGRect {
        try #require(geometry.leaves.first { $0.pane.id == pane.id }).rect
    }

    @Test func aSingleLeafFillsTheContainer() throws {
        let geometry = paneTreeGeometry(for: .leaf(first), in: CGSize(width: 800, height: 600))
        #expect(try rect(of: first, in: geometry) == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(geometry.separators.isEmpty)
    }

    /// A vertical split makes columns; the 1pt divider comes out of the first child's share.
    @Test func aVerticalSplitMakesColumnsAroundAOnePointDivider() throws {
        let geometry = paneTreeGeometry(for: .split(axis: .vertical, ratio: 0.5, first: .leaf(first), second: .leaf(second)),
                                        in: CGSize(width: 801, height: 600))
        #expect(try rect(of: first, in: geometry) == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(geometry.separators.map(\.rect) == [CGRect(x: 400, y: 0, width: 1, height: 600)])
        #expect(try rect(of: second, in: geometry) == CGRect(x: 401, y: 0, width: 400, height: 600))
    }

    @Test func aHorizontalSplitMakesRowsAroundAOnePointDivider() throws {
        let geometry = paneTreeGeometry(for: .split(axis: .horizontal, ratio: 0.25, first: .leaf(first), second: .leaf(second)),
                                        in: CGSize(width: 800, height: 401))
        #expect(try rect(of: first, in: geometry) == CGRect(x: 0, y: 0, width: 800, height: 100))
        #expect(geometry.separators.map(\.rect) == [CGRect(x: 0, y: 100, width: 800, height: 1)])
        #expect(try rect(of: second, in: geometry) == CGRect(x: 0, y: 101, width: 800, height: 300))
    }

    @Test func nestedSplitsComposeWithinTheirParentRect() throws {
        let right = LeafPane(cwd: "/tmp/right")
        let left = PaneNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
        let geometry = paneTreeGeometry(for: .split(axis: .vertical, ratio: 0.5, first: left, second: .leaf(right)),
                                        in: CGSize(width: 801, height: 601))

        #expect(try rect(of: first, in: geometry) == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(try rect(of: second, in: geometry) == CGRect(x: 0, y: 301, width: 400, height: 300))
        #expect(try rect(of: right, in: geometry) == CGRect(x: 401, y: 0, width: 400, height: 601))
        #expect(geometry.separators.map(\.rect).contains(CGRect(x: 0, y: 300, width: 400, height: 1)))
    }

    /// A divider drag previews through `liveRatios` without rewriting the tree.
    @Test func aLiveRatioOverridesTheStoredOneForItsSplit() throws {
        let tree = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(first), second: .leaf(second))
        let root = PaneSplitPath(components: [])
        let geometry = paneTreeGeometry(for: tree, in: CGSize(width: 1001, height: 10), liveRatios: [root: 0.8])
        #expect(try rect(of: first, in: geometry).width == 800)
        #expect(try rect(of: second, in: geometry).width == 200)
    }

    /// Each divider is addressed by its path from the root (false = first, true = second).
    @Test func dividersAreIdentifiedByTheirPathInTheTree() {
        let nested = PaneNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
        let tree = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(cwd: "/tmp")), second: nested)
        let geometry = paneTreeGeometry(for: tree, in: CGSize(width: 100, height: 100))
        #expect(geometry.separators.map(\.id) == [PaneSplitPath(components: []), PaneSplitPath(components: [true])])
        #expect(geometry.separators.map(\.axis) == [.vertical, .horizontal])
    }

    @Test func aZeroSizedContainerProducesOnlyEmptyRects() {
        let geometry = paneTreeGeometry(for: .split(axis: .vertical, ratio: 0.5, first: .leaf(first), second: .leaf(second)), in: .zero)
        #expect(geometry.leaves.allSatisfy { $0.rect == .zero })
        #expect(geometry.separators.allSatisfy { $0.rect == .zero })
    }

    @Test func leavesComeOutInTreeOrder() {
        let third = LeafPane(cwd: "/tmp/third")
        let tree = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(first),
                                  second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(second), second: .leaf(third)))
        let geometry = paneTreeGeometry(for: tree, in: CGSize(width: 100, height: 100))
        #expect(geometry.leaves.map(\.pane.id) == [first.id, second.id, third.id])
    }
}

/// Returning to an agent lands on the pane you were last working in there.
@Suite("Pane focus memory")
struct PaneFocusMemoryTests {
    private struct Layout {
        let tab = TabID()
        let pi = LeafPane(cwd: "/tmp", agentID: AgentID())
        let shell = LeafPane(cwd: "/tmp")
        var node: PaneNode { .split(axis: .vertical, ratio: 0.65, first: .leaf(pi), second: .leaf(shell)) }
    }

    @Test func aFreshLayoutFocusesTheAgentsOwnPane() {
        let layout = Layout()
        #expect(PaneFocusMemory().focus(enteringTab: layout.tab, layout: layout.node, fallback: layout.pi.id) == layout.pi.id)
    }

    @Test func theLastFocusedPaneWinsOverTheAgentPane() {
        let layout = Layout()
        var memory = PaneFocusMemory()
        memory.record(pane: layout.shell.id, inTab: layout.tab)
        #expect(memory.focus(enteringTab: layout.tab, layout: layout.node, fallback: layout.pi.id) == layout.shell.id)
    }

    /// A remembered pane that no longer exists is only ever a hint, never a target.
    @Test func aRememberedPaneThatIsGoneFallsBackToTheAgentPane() {
        let layout = Layout()
        var memory = PaneFocusMemory()
        memory.record(pane: layout.shell.id, inTab: layout.tab)
        #expect(memory.focus(enteringTab: layout.tab, layout: .leaf(layout.pi), fallback: layout.pi.id) == layout.pi.id)
    }

    @Test func withNoUsableFallbackFocusLandsOnTheFirstLeaf() {
        let layout = Layout()
        #expect(PaneFocusMemory().focus(enteringTab: layout.tab, layout: layout.node, fallback: PaneID()) == layout.pi.id)
        #expect(PaneFocusMemory().focus(enteringTab: layout.tab, layout: layout.node, fallback: nil) == layout.pi.id)
    }

    @Test func eachLayoutRemembersItsOwnPane() {
        let a = Layout()
        let b = Layout()
        var memory = PaneFocusMemory()
        memory.record(pane: a.shell.id, inTab: a.tab)
        memory.record(pane: b.pi.id, inTab: b.tab)
        #expect(memory.focus(enteringTab: a.tab, layout: a.node, fallback: a.pi.id) == a.shell.id)
        #expect(memory.focus(enteringTab: b.tab, layout: b.node, fallback: b.pi.id) == b.pi.id)
    }

    @Test func pruningForgetsLayoutsThatNoLongerExist() {
        let a = Layout()
        let b = Layout()
        var memory = PaneFocusMemory()
        memory.record(pane: a.shell.id, inTab: a.tab)
        memory.record(pane: b.shell.id, inTab: b.tab)

        memory.prune(liveTabs: [b.tab])

        #expect(memory.remembered(forTab: a.tab) == nil)
        #expect(memory.remembered(forTab: b.tab) == b.shell.id)
    }
}

/// Only an agent's own primary pane runs its pi thread; every other pane is a terminal.
@Suite("Primary agent pane")
struct PrimaryAgentPaneTests {
    private let space = Fixture.space("scratch")
    private let id = AgentID()

    @Test func onlyTheAgentsRecordedPaneInItsOwnLayoutIsPrimary() {
        let primary = LeafPane(cwd: "/tmp", agentID: id)
        let auxiliary = LeafPane(cwd: "/tmp", agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .vertical, ratio: 0.4, first: .leaf(auxiliary), second: .leaf(primary)))
        let agent = Agent(id: id, name: "fixture", spaceID: space.id, tabID: tab.id, paneID: primary.id)

        #expect(primaryAgent(in: tab, pane: primary, agents: [agent]) == agent)
        #expect(primaryAgent(in: tab, pane: auxiliary, agents: [agent]) == nil)
        #expect(primaryAgent(in: Tab(spaceID: space.id, order: 1, layout: .leaf(primary)), pane: primary, agents: [agent]) == nil)
    }

    @Test func reviewPanesInspectorTabsGlobalTabsAndUnboundAgentsAreNeverPrimary() {
        let pane = LeafPane(cwd: "/tmp", agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var agent = Agent(id: id, name: "fixture", spaceID: space.id, tabID: tab.id, paneID: pane.id)

        var review = pane
        review.isReview = true
        #expect(primaryAgent(in: tab, pane: review, agents: [agent]) == nil)

        var inspector = tab
        inspector.inspectorFor = id
        #expect(primaryAgent(in: inspector, pane: pane, agents: [agent]) == nil)

        var global = tab
        global.spaceID = nil
        #expect(primaryAgent(in: global, pane: pane, agents: [agent]) == nil)

        agent.paneID = nil
        #expect(primaryAgent(in: tab, pane: pane, agents: [agent]) == nil)
    }
}

/// Replay into a fresh surface is a snapshot plus the output after its watermark: chunks at or
/// below it are already in the snapshot and must not be fed twice.
@Suite("Attach replay watermark")
@MainActor
struct AttachReplayWatermarkTests {
    private typealias Buffered = TerminalSessionStore.PaneSession.BufferedOutput

    @Test func onlyOutputAfterTheWatermarkIsFedAfterTheSnapshot() {
        let buffered = [10, 11, 12, 13].map { Buffered(data: Data("chunk \($0)".utf8), sequence: UInt64($0)) }
        let fresh = TerminalSessionStore.PaneSession.output(after: 11, from: buffered)
        #expect(fresh.map(\.sequence) == [12, 13])
        #expect(fresh.map { String(decoding: $0.data, as: UTF8.self) } == ["chunk 12", "chunk 13"])
    }

    @Test func aWatermarkPastEverythingFeedsNothing() {
        let buffered = [Buffered(data: Data("x".utf8), sequence: 3)]
        #expect(TerminalSessionStore.PaneSession.output(after: 3, from: buffered).isEmpty)
    }
}
