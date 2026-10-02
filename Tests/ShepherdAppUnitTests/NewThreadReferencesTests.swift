import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// Design pieces on the New thread page (docs/designs.md › Design references): where they can go,
/// what a thread started from them is called, how a draft keeps them, and what the @ picker says
/// for a project on another host.
@Suite("New thread references")
@MainActor
struct NewThreadReferencesTests {
    private static func piece(_ board: String?, label: String, revision: UInt64? = 3) -> NativeAttachedReference {
        let reference = DesignReference(designID: DesignID(rawValue: "checkout"), board: board.flatMap { DesignPath($0) }, revision: revision)!
        return NativeAttachedReference(reference: reference, label: label)
    }

    @Test(arguments: [
        (0, UUID?.none, false), (2, UUID?.none, false), (0, UUID(), false), (1, UUID(), true), (5, UUID(), true),
    ])
    func designsGoToThisMacsProjectsOnly(count: Int, host: UUID?, refused: Bool) {
        let refusal = NewThreadPlaces.referencesRefusal(count: count, host: host)
        #expect((refusal != nil) == refused)
        #expect(refusal.map { $0.hasPrefix(NewThreadPlaces.referencesNote) } ?? true)
    }

    @Test func aThreadStartedFromDesignsAloneIsNamedForTheFirstPiece() {
        let board = Self.piece("A.dc.html", label: "Checkout funnel dashboard › A · Funnel first")
        let element = Self.piece("A.dc.html", label: "Checkout funnel dashboard › A · Funnel first › card “Checkout funnel”")
        #expect(NewThreadState.pieceName([board, element]) == "A · Funnel first")
        #expect(NewThreadState.pieceName([element]) == "card “Checkout funnel”")
        #expect(NewThreadState.pieceName([]) == "Design")
    }

    @Test func aDraftKeepsEachPieceOnceAndAtMostFive() {
        var pieces: [NativeAttachedReference] = []
        let first = pieces.attach(Self.piece("A.dc.html", label: "A", revision: 3))
        let again = pieces.attach(Self.piece("A.dc.html", label: "A", revision: 4))
        #expect(first && again)
        #expect(pieces.count == 1 && pieces[0].reference.revision == 4, "the same piece again takes the first one's place")
        for name in ["B", "C", "D", "E"] {
            let added = pieces.attach(Self.piece("\(name).dc.html", label: name))
            #expect(added)
        }
        #expect(pieces.count == DesignReferenceRecord.maxPerMessage)
        let sixth = pieces.attach(Self.piece("F.dc.html", label: "F"))
        #expect(!sixth, "a sixth is refused")
        #expect(pieces.count == 5)
        let replaced = pieces.attach(Self.piece("C.dc.html", label: "C", revision: 9))
        #expect(replaced, "a piece already there is still replaced when the list is full")
    }

    @Test func theMentionPickerOpensOnANoteForAProjectOnAnotherHostAndReadsNothing() {
        var state = MentionPickerState()
        let note = NewThreadPlaces.referencesNote
        state.update(draft: "Match @", catalog: nil, stage: .loading, unavailable: note)
        #expect(state.isOpen && state.content.empty == .unavailable(note))
        #expect(state.content.rows.isEmpty && state.highlightedRow == nil, "nothing to choose, so ↩ takes nothing")
        // Back on this Mac's project the same draft reads and lists.
        state.update(draft: "Match @", catalog: DesignMentionCatalog(), stage: .rows)
        #expect(state.content.empty == .noDesigns)
    }
}
