import Foundation
import Testing
import ShepherdCore

@Suite("PaneNode binary split tree")
struct PaneNodeTests {
    let left = Fixture.leaf("/tmp/left")
    let right = Fixture.leaf("/tmp/right")
    let added = Fixture.leaf("/tmp/added")

    /// `left | right`, with a non-default ratio so tests can tell which split was touched.
    var pair: PaneNode { .split(axis: .vertical, ratio: 0.65, first: .leaf(left), second: .leaf(right)) }

    /// `(left / added) | right`
    var nested: PaneNode {
        .split(
            axis: .vertical, ratio: 0.65,
            first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(added)),
            second: .leaf(right)
        )
    }

    @Test func leavesAreEnumeratedDepthFirstLeftToRight() {
        #expect(nested.leaves.map(\.id) == [left.id, added.id, right.id])
        #expect(nested.firstLeaf == left)
    }

    @Test func lookupFindsOnlyLeavesInTheTree() {
        #expect(nested.contains(added.id))
        #expect(nested.leaf(withID: right.id) == right)
        #expect(!pair.contains(added.id))
        #expect(pair.leaf(withID: added.id) == nil)
    }

    @Test func splittingALeafNestsItFirstWithTheNewPaneSecondAtHalfRatio() {
        #expect(pair.splitting(pane: left.id, axis: .horizontal, newPane: added) == nested)
    }

    @Test func splittingHonoursAnExplicitRatio() {
        let split = PaneNode.leaf(left).splitting(pane: left.id, axis: .vertical, newPane: added, ratio: 0.3)
        #expect(split == .split(axis: .vertical, ratio: 0.3, first: .leaf(left), second: .leaf(added)))
    }

    @Test func splittingAnUnknownPaneReturnsNil() {
        #expect(pair.splitting(pane: PaneID(), axis: .vertical, newPane: added) == nil)
    }

    @Test func closingALeafCollapsesItsParentIntoTheSibling() {
        #expect(pair.closing(pane: left.id) == .leaf(right))
        #expect(pair.closing(pane: right.id) == .leaf(left))
    }

    @Test func closingADeepLeafKeepsTheOuterSplitAndItsRatio() {
        #expect(nested.closing(pane: added.id) == pair)
    }

    @Test func closingTheOnlyLeafReturnsNil() {
        #expect(PaneNode.leaf(left).closing(pane: left.id) == nil)
    }

    @Test func closingAnUnknownPaneIsANoOp() {
        #expect(nested.closing(pane: PaneID()) == nested)
    }

    @Test func ratioUpdateTargetsTheDeepestSplitContainingThePane() {
        let updated = nested.updatingRatio(ofSplitContaining: added.id, to: 0.7)
        #expect(updated == .split(
            axis: .vertical, ratio: 0.65,
            first: .split(axis: .horizontal, ratio: 0.7, first: .leaf(left), second: .leaf(added)),
            second: .leaf(right)
        ))
    }

    @Test func ratioUpdateForATopLevelLeafChangesTheRoot() {
        let updated = nested.updatingRatio(ofSplitContaining: right.id, to: 0.25)
        guard case .split(_, let ratio, let first, _) = updated else { Issue.record("expected split"); return }
        #expect(ratio == 0.25)
        #expect(first == nested.closing(pane: right.id))
    }

    @Test func ratioUpdateOnALoneLeafOrUnknownPaneIsANoOp() {
        #expect(PaneNode.leaf(left).updatingRatio(ofSplitContaining: left.id, to: 0.2) == .leaf(left))
        #expect(nested.updatingRatio(ofSplitContaining: PaneID(), to: 0.2) == nested)
    }

    @Test func updatingALeafTransformsOnlyThatLeaf() {
        let session = SessionID()
        let updated = nested.updatingLeaf(added.id) { $0.sessionID = session }
        #expect(updated.leaf(withID: added.id)?.sessionID == session)
        #expect(updated.leaves.filter { $0.sessionID != nil }.count == 1)
        #expect(nested.updatingLeaf(PaneID()) { $0.sessionID = session } == nested)
    }

    @Test func codableRoundTripPreservesStructure() throws {
        let review = nested.updatingLeaf(right.id) { $0.isReview = true; $0.sessionID = SessionID() }
        #expect(try Fixture.roundTrip(review) == review)
    }

    @Test func wireShapeUsesATypeDiscriminator() throws {
        let object = try Fixture.encodeObject(pair)
        #expect(object["type"] as? String == "split")
        #expect(object["axis"] as? String == "vertical")
        #expect((object["first"] as? [String: Any])?["type"] as? String == "leaf")
    }

    @Test func leavesWithoutOptionalKeysDecodeAsPlainPanes() throws {
        let decoded = try Fixture.decode(PaneNode.self, #"{"type":"leaf","pane":{"id":"p1","cwd":"/tmp"}}"#)
        #expect(decoded == .leaf(LeafPane(id: PaneID(rawValue: "p1"), cwd: "/tmp")))
    }

    @Test func anUnknownNodeTypeFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try Fixture.decode(PaneNode.self, #"{"type":"grid","pane":{"id":"p1","cwd":"/tmp"}}"#)
        }
    }
}
