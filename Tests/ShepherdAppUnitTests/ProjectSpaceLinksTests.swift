import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// Project settings' Spaces tab (ProjectLead-SettingsSpacesV2) resolves each link against its own destination. The same SpaceID, the
/// same name and the same path on two machines are three different ways to be wrong if any of them stands in for the pair.
@Suite("Project space links")
struct ProjectSpaceLinksTests {
    private let shared = SpaceID(rawValue: UUID().uuidString.lowercased())
    private let build = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "build-01")
    private let studio = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "studio")

    private func space(_ id: SpaceID, _ name: String, _ path: String, hidden: Bool = false) -> Space {
        Space(id: id, name: name, path: path, hidden: hidden)
    }

    private func options(build buildSpaces: [Space]?, studio studioSpaces: [Space]? = []) -> [ProjectHostOption] {
        [ProjectHostOption(reference: .local, name: "This Mac"),
         ProjectHostOption(reference: build.reference, name: build.name, spaces: buildSpaces),
         ProjectHostOption(reference: studio.reference, name: studio.name, spaces: studioSpaces)]
    }

    @Test func aRemoteLinkIsNamedFromItsOwnHostNotFromTheOwnersSpaceWithTheSameID() {
        let mine = space(shared, "payments", "/Users/me/payments")
        let theirs = space(shared, "payments-api", "/srv/payments")
        let links = [ProjectSpaceLink(spaceID: shared, linkedAt: 1), ProjectSpaceLink(spaceID: shared, linkedAt: 2, host: build.reference)]
        let rows = ProjectSpaceLinks.rows(links: links, ownerSpaces: [mine], options: options(build: [theirs]), ownerName: "This Mac", abbreviatesHome: false)
        #expect(rows.map(\.name) == ["payments", "payments-api"])
        #expect(rows.map(\.detail) == ["/Users/me/payments · This Mac", "/srv/payments · build-01"])
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count, "equal SpaceIDs are two rows")
    }

    @Test func removeNamesItsHostSoEqualNamesStayDistinctControls() {
        let links = [ProjectSpaceLink(spaceID: shared, linkedAt: 1), ProjectSpaceLink(spaceID: shared, linkedAt: 2, host: build.reference)]
        let same = space(shared, "web", "/code/web")
        let rows = ProjectSpaceLinks.rows(links: links, ownerSpaces: [same], options: options(build: [same]), ownerName: "This Mac", abbreviatesHome: false)
        #expect(rows.map(\.removeLabel) == ["Remove web", "Remove web on build-01"])
        #expect(rows.map(\.link.destination) == [.local, build.reference], "each row removes the link it was drawn from")
        #expect(rows[0].link.host == nil && rows[1].link.host == build.reference)
    }

    @Test func aRemoteLinkNeverFallsBackToTheOwnersSpaceWhenItsHostDoesNotListIt() {
        let mine = space(shared, "payments", "/Users/me/payments")
        let link = ProjectSpaceLink(spaceID: shared, linkedAt: 1, host: build.reference)
        let silent = ProjectSpaceLinks.rows(links: [link], ownerSpaces: [mine], options: options(build: nil), ownerName: "This Mac", abbreviatesHome: false)
        #expect(silent[0].name == "A space on build-01, which does not list its spaces" && silent[0].detail == "build-01")
        let gone = ProjectSpaceLinks.rows(links: [link], ownerSpaces: [mine], options: options(build: []), ownerName: "This Mac", abbreviatesHome: false)
        #expect(gone[0].name == "A space that is no longer on build-01")
        let unknown = ProjectSpaceLinks.rows(links: [link], ownerSpaces: [mine], options: nil, ownerName: "This Mac", abbreviatesHome: false)
        #expect(unknown[0].name == "A space on a host that is not connected" && unknown[0].hostName == "an unknown host")
    }

    @Test func aPathOnAnotherMachineIsNeverShortenedWithThisMacsHome() {
        let home = NSHomeDirectory()
        let local = space(SpaceID(rawValue: "a"), "web", home + "/code/web")
        let remote = space(SpaceID(rawValue: "b"), "web", home + "/code/web")
        let links = [ProjectSpaceLink(spaceID: local.id, linkedAt: 1), ProjectSpaceLink(spaceID: remote.id, linkedAt: 2, host: build.reference)]
        let rows = ProjectSpaceLinks.rows(links: links, ownerSpaces: [local], options: options(build: [remote]), ownerName: "This Mac", abbreviatesHome: true)
        #expect(rows[0].detail == "~/code/web · This Mac")
        #expect(rows[1].detail == home + "/code/web · build-01")
    }

    @Test func addOffersEachHostsSpacesKeyedByDestinationAndSkipsOnlyTheLinkedPair() {
        let mine = space(shared, "web", "/Users/me/web")
        let theirs = space(shared, "web", "/srv/web")
        let hidden = space(SpaceID(rawValue: "hid"), "hidden", "/srv/hidden", hidden: true)
        let links = [ProjectSpaceLink(spaceID: shared, linkedAt: 1)]
        let choices = ProjectSpaceLinks.addChoices(links: links, ownerSpaces: [mine], options: options(build: [theirs, hidden], studio: nil), ownerName: "This Mac")
        // The local pair is linked, so only the build-01 Space with the same ID and name is offered. studio lists none, so offers none.
        #expect(choices.map(\.title) == ["web on build-01"])
        #expect(choices.map(\.host) == [build.reference])
        #expect(choices.map(\.space.id) == [shared])
    }

    @Test func aLocalChoiceLinksWithNoHostSoItIsStoredAsEverLocalLinkWas() {
        let mine = space(SpaceID(rawValue: "m"), "web", "/Users/me/web")
        let choices = ProjectSpaceLinks.addChoices(links: [], ownerSpaces: [mine], options: options(build: []), ownerName: "This Mac")
        #expect(choices.map(\.title) == ["web"] && choices.map(\.host) == [nil])
    }

    @Test func aRemoteOwnersOwnMachineIsLocalAndCarriesItsOwnName() {
        let owner = space(shared, "api", "/srv/api")
        let link = ProjectSpaceLink(spaceID: shared, linkedAt: 1)
        let rows = ProjectSpaceLinks.rows(links: [link], ownerSpaces: [owner], options: [ProjectHostOption(reference: .local, name: "build-01")],
                                          ownerName: "build-01", abbreviatesHome: false)
        #expect(rows[0].detail == "/srv/api · build-01" && rows[0].removeLabel == "Remove api")
    }
}
