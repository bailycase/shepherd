import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

@Suite("Project host choices")
struct ProjectHostChoicesTests {
    private let build = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "build-01")
    private let studio = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "studio")
    private var options: [ProjectHostOption] { [.init(reference: .local, name: "Baily's Mac"), build, studio] }

    @Test func aNewProjectRunsOnTheOwnerOnly() {
        let choices = ProjectHostChoices(settings: LogicalProjectSettings(), options: options, ownerName: "This Mac")
        #expect(choices.current == "This Mac only")
        #expect(choices.choices.map(\.title) == ["This Mac and build-01", "This Mac and studio", "This Mac only", "Any connected host"])
        #expect(choices.selected?.policy == .selected && choices.selected?.allowedHosts == [.local])
    }

    @Test func aSelectedRemoteHostIsNamedFromTheOwnersList() {
        let settings = LogicalProjectSettings(hostPolicy: .selected, allowedHosts: [.local, build.reference])
        let choices = ProjectHostChoices(settings: settings, options: options, ownerName: "This Mac")
        #expect(choices.current == "This Mac and build-01")
        #expect(choices.selected?.allowedHosts == [.local, build.reference])
    }

    @Test func anyConnectedKeepsTheSavedHostsAndSaysSo() {
        let settings = LogicalProjectSettings(hostPolicy: .anyConnected, allowedHosts: [.local, studio.reference])
        let choices = ProjectHostChoices(settings: settings, options: options, ownerName: "This Mac")
        #expect(choices.current == "Any connected host")
        #expect(choices.selected?.allowedHosts == [.local, studio.reference], "switching to any host drops no saved reference")
    }

    @Test func aRemoteOwnersMachineCarriesItsOwnNameNotThisMac() {
        let choices = ProjectHostChoices(settings: LogicalProjectSettings(), options: [.init(reference: .local, name: "build-01")], ownerName: "build-01")
        #expect(choices.current == "build-01 only")
        #expect(choices.choices.map(\.title) == ["build-01 only", "Any connected host"])
    }

    @Test func aHostTheOwnerNoLongerKnowsIsSaidToBeUnknownNotGuessed() {
        let settings = LogicalProjectSettings(hostPolicy: .selected, allowedHosts: [.local, build.reference])
        let choices = ProjectHostChoices(settings: settings, options: [.init(reference: .local, name: "Mac")], ownerName: "This Mac")
        #expect(choices.current == "This Mac and an unknown host")
        #expect(choices.selected == nil, "an unknown binding is not one of the offered choices")
    }

    @Test func anOwnerThatDoesNotAnswerOffersOnlyWhatNeedsNoHostList() {
        let choices = ProjectHostChoices(settings: LogicalProjectSettings(), options: nil, ownerName: "This Mac")
        #expect(choices.choices.map(\.title) == ["This Mac only", "Any connected host"])
    }

    @Test func aDraftAssignsToTheOwnerUnlessAHostIsChosen() {
        var draft = AssignProjectTaskDraft()
        #expect(draft.host == nil, "the owner itself is the default, with nothing to choose")
        draft.host = build.reference
        #expect(draft.host == build.reference)
    }
}
