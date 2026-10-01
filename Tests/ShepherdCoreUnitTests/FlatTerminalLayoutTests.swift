import Foundation
import Testing
import ShepherdCore

/// Terminals are tabs only: a layout's terminals are every leaf beside the thread, and a layout
/// that split them (older builds' Split right and Split down) flattens into one tab each.
@Suite("Flat terminal layouts")
struct FlatTerminalLayoutTests {
    let thread = LeafPane(id: PaneID(rawValue: "thread"), cwd: "/work", agentID: AgentID())
    let first = LeafPane(id: PaneID(rawValue: "first"), sessionID: SessionID(), cwd: "/work/a", title: "build")
    let second = LeafPane(id: PaneID(rawValue: "second"), cwd: "/work/b")
    let third = LeafPane(id: PaneID(rawValue: "third"), cwd: "/work/c", title: "logs")
    let fourth = LeafPane(id: PaneID(rawValue: "fourth"), cwd: "/work/d")

    private func split(_ axis: SplitAxis, _ a: PaneNode, _ b: PaneNode, ratio: Double = 0.5) -> PaneNode {
        .split(axis: axis, ratio: ratio, first: a, second: b)
    }

    /// What + made: each new tab splits the thread, so the newest sits closest to it.
    private var threeTabs: PaneNode {
        let withFirst = PaneNode.leaf(thread).splitting(pane: thread.id, axis: .horizontal, newPane: first)!
        let withSecond = withFirst.splitting(pane: thread.id, axis: .horizontal, newPane: second)!
        return withSecond.splitting(pane: thread.id, axis: .horizontal, newPane: third)!
    }

    @Test func terminalsAreTheLeavesBesideTheThreadOldestFirst() {
        #expect(threeTabs.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id, third.id])
        #expect(PaneNode.leaf(thread).terminals(besideThread: thread.id).isEmpty)
    }

    @Test func aLayoutWithoutTheThreadHasNoTerminalsBesideIt() {
        #expect(threeTabs.terminals(besideThread: PaneID(rawValue: "elsewhere")).isEmpty)
    }

    @Test func aThreadOnTheFarSideOfTheRootStillFindsTheSameTerminals() {
        let mirrored = split(.horizontal, .leaf(first), split(.horizontal, .leaf(second), .leaf(thread)))
        #expect(mirrored.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id])
    }

    @Test func aLayoutOfSingleTerminalTabsNeedsNoFlattening() {
        #expect(!threeTabs.hasSplitTerminals(besideThread: thread.id))
        #expect(threeTabs.flatteningTerminals(besideThread: thread.id) == threeTabs)
        #expect(PaneNode.leaf(thread).flatteningTerminals(besideThread: thread.id) == .leaf(thread))
    }

    @Test func aTabSplitRightBecomesTwoTabsKeepingTheirOrder() {
        let old = split(.horizontal, split(.vertical, .leaf(first), .leaf(second)), .leaf(thread))
        #expect(old.hasSplitTerminals(besideThread: thread.id))
        let flat = old.flatteningTerminals(besideThread: thread.id)
        #expect(flat.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id])
        #expect(!flat.hasSplitTerminals(besideThread: thread.id))
        #expect(flat.leaves.count == 3)
    }

    @Test func nestedSplitsFlattenDepthFirstAndTheTabsAroundThemKeepTheirPlace() {
        // tab one: (first | (second / third)), tab two: fourth.
        let firstTab = split(.vertical, .leaf(first), split(.horizontal, .leaf(second), .leaf(third)))
        let old = split(.horizontal, split(.horizontal, .leaf(thread), .leaf(fourth)), firstTab)
        let flat = old.flatteningTerminals(besideThread: thread.id)
        #expect(flat.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id, third.id, fourth.id])
        #expect(!flat.hasSplitTerminals(besideThread: thread.id))
    }

    @Test func everyTerminalKeepsItsSessionFolderAndTitle() {
        let old = split(.horizontal, split(.vertical, .leaf(first), .leaf(third)), .leaf(thread))
        let flat = old.flatteningTerminals(besideThread: thread.id)
        #expect(flat.leaf(withID: first.id) == first)
        #expect(flat.leaf(withID: third.id) == third)
        #expect(flat.leaf(withID: thread.id) == thread)
    }

    @Test func theThreadStaysWhereTheTabsHangFrom() {
        let old = split(.vertical, split(.horizontal, .leaf(first), .leaf(second)), split(.vertical, .leaf(thread), .leaf(third)))
        let flat = old.flatteningTerminals(besideThread: thread.id)
        #expect(flat.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id, third.id])
        #expect(flat.firstLeaf == thread, "the thread is the deepest, first leaf of the flat layout")
    }

    @Test func flatteningIsIdempotent() {
        let old = split(.horizontal, split(.vertical, .leaf(first), split(.vertical, .leaf(second), .leaf(third))), .leaf(thread))
        let once = old.flatteningTerminals(besideThread: thread.id)
        #expect(once.flatteningTerminals(besideThread: thread.id) == once)
    }

    @Test func aLayoutThatDoesNotHoldTheThreadIsReturnedAsItIs() {
        let old = split(.vertical, .leaf(first), split(.vertical, .leaf(second), .leaf(third)))
        #expect(old.flatteningTerminals(besideThread: PaneID(rawValue: "elsewhere")) == old)
        #expect(!old.hasSplitTerminals(besideThread: PaneID(rawValue: "elsewhere")))
    }
}
