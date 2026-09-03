import Testing
import Foundation
@testable import ShepherdCore

@Suite("PaneNode tree operations")
struct PaneNodeTests {
    func referenceTree() -> (PaneNode, LeafPane, LeafPane) {
        let left = LeafPane(cwd: "/tmp/left")
        let right = LeafPane(cwd: "/tmp/right")
        let tree = PaneNode.split(axis: .vertical, ratio: 1.85 / 2.85, first: .leaf(left), second: .leaf(right))
        return (tree, left, right)
    }

    @Test func leavesEnumeratesInOrder() {
        let (tree, left, right) = referenceTree()
        #expect(tree.leaves.map(\.id) == [left.id, right.id])
        #expect(tree.firstLeaf.id == left.id)
    }

    @Test func splittingReplacesLeafWithSplit() throws {
        let (tree, left, _) = referenceTree()
        let newPane = LeafPane(cwd: "/tmp/new")
        let split = try #require(tree.splitting(pane: left.id, axis: .horizontal, newPane: newPane))
        #expect(split.leaves.count == 3)
        #expect(split.contains(newPane.id))
        guard case .split(_, _, let first, _) = split,
              case .split(let axis, let ratio, let inner1, let inner2) = first else {
            Issue.record("expected nested split as first child")
            return
        }
        #expect(axis == .horizontal)
        #expect(ratio == 0.5)
        #expect(inner1 == .leaf(left))
        #expect(inner2 == .leaf(newPane))
    }

    @Test func splittingUnknownPaneReturnsNil() {
        let (tree, _, _) = referenceTree()
        #expect(tree.splitting(pane: PaneID(), axis: .vertical, newPane: LeafPane(cwd: "/x")) == nil)
    }

    @Test func closingCollapsesToSibling() {
        let (tree, left, right) = referenceTree()
        #expect(tree.closing(pane: left.id) == .leaf(right))
        #expect(tree.closing(pane: right.id) == .leaf(left))
    }

    @Test func closingOnlyLeafReturnsNil() {
        let solo = LeafPane(cwd: "/tmp")
        #expect(PaneNode.leaf(solo).closing(pane: solo.id) == nil)
    }

    @Test func closingDeepLeafPreservesOuterStructure() throws {
        let (tree, left, _) = referenceTree()
        let newPane = LeafPane(cwd: "/tmp/new")
        let split = try #require(tree.splitting(pane: left.id, axis: .horizontal, newPane: newPane))
        let closed = try #require(split.closing(pane: newPane.id))
        #expect(closed == tree)
    }

    @Test func closingUnknownPaneReturnsSelf() {
        let (tree, _, _) = referenceTree()
        #expect(tree.closing(pane: PaneID()) == tree)
    }

    @Test func updatingRatioTargetsDeepestSplit() throws {
        let (tree, left, right) = referenceTree()
        let updated = tree.updatingRatio(ofSplitContaining: right.id, to: 0.25)
        guard case .split(_, let ratio, _, _) = updated else {
            Issue.record("expected split root")
            return
        }
        #expect(ratio == 0.25)

        let newPane = LeafPane(cwd: "/tmp/new")
        let nested = try #require(tree.splitting(pane: left.id, axis: .horizontal, newPane: newPane))
        let deepUpdated = nested.updatingRatio(ofSplitContaining: newPane.id, to: 0.7)
        guard case .split(_, let outerRatio, let first, _) = deepUpdated,
              case .split(_, let innerRatio, _, _) = first else {
            Issue.record("expected nested split")
            return
        }
        #expect(outerRatio == 1.85 / 2.85)
        #expect(innerRatio == 0.7)
    }

    @Test func updatingLeafTransformsOnlyTarget() throws {
        let (tree, left, right) = referenceTree()
        let sessionID = SessionID()
        let updated = tree.updatingLeaf(left.id) { $0.sessionID = sessionID }
        #expect(updated.leaf(withID: left.id)?.sessionID == sessionID)
        #expect(updated.leaf(withID: right.id)?.sessionID == nil)
        #expect(tree.updatingLeaf(PaneID()) { $0.sessionID = sessionID } == tree)
    }

    @Test func codableRoundTrip() throws {
        let (tree, left, _) = referenceTree()
        let nested = try #require(tree.splitting(pane: left.id, axis: .horizontal, newPane: LeafPane(cwd: "/tmp/new")))
        let data = try JSONEncoder().encode(nested)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == nested)
    }

    @Test func oldLeafJSONDecodesWithoutReviewFlag() throws {
        let data = Data(#"{"type":"leaf","pane":{"id":"p1","cwd":"/tmp"}}"#.utf8)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == .leaf(LeafPane(id: PaneID(rawValue: "p1"), cwd: "/tmp")))
    }
}
