import Foundation
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The @ picker before it has rows (docs/design/design-tool-references.md › The @ picker): it opens
/// at once, says "Loading designs…" while this Mac's designs are read, says "Couldn't load
/// designs." when the read failed, lists nothing to choose in either, and once the rows arrive
/// shows them for the draft as it stands then.
@Suite("Mention picker loading")
@MainActor
struct MentionPickerLoadingTests {
    private static let catalog = DesignReferenceThreadTests.catalog

    @Test func atSignOpensThePickerAtOnceSayingItIsLoading() {
        var state = MentionPickerState()
        #expect(state.opens(for: "Match the funnel in @"))
        state.update(draft: "Match the funnel in @", catalog: nil, stage: .loading)
        #expect(state.isOpen && state.content.empty == .loading)
        #expect(state.content.sections.isEmpty && state.content.rows.isEmpty, "nothing to choose")
        #expect(state.highlighted == nil && state.highlightedRow == nil, "↩ has no row to take")
    }

    @Test func aPickerWithNoCatalogYetDefaultsToLoading() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil)
        #expect(state.content.empty == .loading)
    }

    @Test func theRowsReplaceLoadingWhenTheyArrive() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil, stage: .loading)
        state.update(draft: "@", catalog: Self.catalog, stage: .rows)
        #expect(state.content.empty == nil)
        #expect(state.content.rows.map(\.title) == ["Checkout funnel dashboard", "Events explorer"])
        #expect(state.highlighted == state.content.rows.first?.id, "the first design is highlighted")
    }

    @Test func noDesignsIsSaidOnlyOnceTheReadFoundNone() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil, stage: .loading)
        #expect(state.content.empty == .loading, "not 'No designs yet' while they are still being read")
        state.update(draft: "@", catalog: DesignMentionCatalog(), stage: .rows)
        #expect(state.content.empty == .noDesigns)
    }

    @Test func aQueryThatMatchesNothingIsSaidOnlyOnceTheReadIsDone() {
        var state = MentionPickerState()
        state.update(draft: "@pricng", catalog: nil, stage: .loading)
        #expect(state.content.empty == .loading)
        state.update(draft: "@pricng", catalog: Self.catalog, stage: .rows)
        #expect(state.content.empty == .nothingMatches(query: "pricng", searched: MentionPickerContent.searched))
    }

    @Test func aFailedReadSaysSoWithItsReasonAndListsNothing() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil, stage: .failed(reason: "Reading this Mac’s designs took too long."))
        #expect(state.content.empty == .failed(reason: "Reading this Mac’s designs took too long."))
        #expect(state.content.rows.isEmpty && state.highlightedRow == nil)
        #expect(state.isOpen, "Esc and typing still work: the picker is open")
    }

    @Test func wordsTypedWhileLoadingFilterTheRowsOnceTheyArrive() {
        var state = MentionPickerState()
        state.update(draft: "Match @fun", catalog: nil, stage: .loading)
        state.update(draft: "Match @funn", catalog: nil, stage: .loading)
        #expect(state.content.empty == .loading)

        state.update(draft: "Match @funn", catalog: Self.catalog, stage: .rows)
        #expect(state.content.rows.map(\.title) == ["Checkout funnel dashboard", "A · Funnel first", "card “Checkout funnel”"])
        #expect(state.content.rows.allSatisfy { $0.matched == ["funn"] })
    }

    @Test func theRowsThatArriveAreDerivedForTheDraftAsItIsNotAsItWasWhenAsked() {
        // The read was asked for at "@fun"; by the time it answers the draft is "@event".
        var state = MentionPickerState()
        state.update(draft: "@fun", catalog: nil, stage: .loading)
        state.update(draft: "@event", catalog: Self.catalog, stage: .rows)
        #expect(state.content.rows.map(\.title) == ["Events explorer"])
    }

    @Test func returnOverLoadingChoosesNothing() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil, stage: .loading)
        let row = NWMentionRow(id: "ghost", kind: .design, title: "Ghost", trailing: .drill)
        #expect(state.choose(row) == nil, "a row the content doesn't hold is never chosen")
        #expect(state.isOpen, "and the picker stays")
    }

    @Test func aPickerDismissedWhileLoadingStaysClosedForThatDraftAndLoadsAgainForAnother() {
        var state = MentionPickerState()
        state.update(draft: "@fun", catalog: nil, stage: .loading)
        state.dismissed = "@fun"
        state.close()
        #expect(!state.opens(for: "@fun"), "Esc closed it for the draft as typed")
        state.update(draft: "@fun", catalog: nil, stage: .loading)
        #expect(!state.isOpen)
        #expect(state.opens(for: "@funn"))
    }

    @Test func closingThePickerForgetsWhatItWasSaying() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: nil, stage: .failed(reason: "took too long"))
        state.close()
        #expect(!state.isOpen && state.content == MentionPickerContent())
    }
}
