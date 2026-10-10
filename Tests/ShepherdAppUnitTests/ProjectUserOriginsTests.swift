import Foundation
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// Consecutive user messages are one turn, so a Project turn can hold the owner's words and a person's. Each message is classified by the
/// operation it carries, never by its text.
@Suite("Project user turn origins")
struct ProjectUserOriginsTests {
    private let assigned = UUID()
    private let wake = UUID()
    private let person = UUID()

    private func message(_ text: String, _ operation: UUID?, images: Int = 0, references: [DesignReferenceRecord]? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: UUID().uuidString, role: "user",
                            blocks: [NativeThreadBlock(kind: .text, text: text)]
                                + Array(repeating: NativeThreadBlock(kind: .unsupportedImage, text: ""), count: images),
                            operationID: operation, designReferences: references)
    }

    private func turn(_ messages: NativeThreadMessage...) -> NativeTurn { NativeTurn(id: "t", isUser: true, messages: messages) }

    @Test func anAssignmentAndAPersonsFollowUpInOneTurnKeepBothOrigins() throws {
        let origins = ProjectUserOrigins(assignment: [assigned])
        let reference = DesignReferenceRecord(ref: "design:board")
        let mixed = turn(message("Build the widget", assigned), message("use blue", person, images: 1, references: [reference]))
        let segments = origins.segments(mixed)
        #expect(segments.count == 2)
        #expect(segments[0] == .assignment("Build the widget"))
        guard case .person(let kept) = segments[1] else { Issue.record("the follow-up lost its bubble"); return }
        #expect(kept.id == "t", "the row's identity is untouched")
        #expect(kept.bubbles.map(\.text) == ["use blue"])
        #expect(kept.bubbles.map(\.images) == [1])
        #expect(kept.bubbles[0].references == [reference])
    }

    @Test func aPersonsWordsBeforeTheAssignmentStayABubbleAndTheOrderIsKept() {
        let origins = ProjectUserOrigins(assignment: [assigned])
        let segments = origins.segments(turn(message("first", person), message("task", assigned), message("second", nil)))
        #expect(segments.count == 3)
        #expect(segments[1] == .assignment("task"))
    }

    @Test func aTurnOfOnlyTheAssignmentIsPlainAndWordsLookingLikeOneAreStillAPerson() {
        let origins = ProjectUserOrigins(assignment: [assigned])
        #expect(origins.segments(turn(message("Build the widget", assigned))) == [.assignment("Build the widget")])
        // Same words, another operation: matched by identity, never by text.
        let lookalike = turn(message("Build the widget", person))
        #expect(origins.segments(lookalike) == [.person(lookalike)])
    }

    @Test func coordinatorWakeUpsDropOutOfAMixedTurnAndHideAPureOne() {
        let origins = ProjectUserOrigins(runtime: [wake])
        let mixed = turn(message("worker finished", wake), message("what now?", person))
        #expect(!origins.hides(mixed))
        let segments = origins.segments(mixed)
        guard segments.count == 1, case .person(let kept) = segments[0] else { Issue.record("expected one bubble"); return }
        #expect(kept.bubbles.map(\.text) == ["what now?"])
        #expect(origins.hides(turn(message("a", wake), message("b", wake))))
    }

    @Test func anOrdinaryThreadHasNoOriginsAndKeepsItsTurnWhole() {
        let ordinary = turn(message("one", nil), message("two", UUID()))
        #expect(ProjectUserOrigins().segments(ordinary) == [.person(ordinary)])
        #expect(!ProjectUserOrigins().hides(ordinary))
    }
}
