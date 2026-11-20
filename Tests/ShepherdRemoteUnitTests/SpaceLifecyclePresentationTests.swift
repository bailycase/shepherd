import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

struct SpaceLifecyclePresentationTests {
    private let web = Space(name: "acme-web", path: "/Users/demo/acme-web")
    private let api = Space(name: "acme-api", path: "/Users/demo/acme-api")
    private let docs = Space(name: "acme-docs", path: "/Users/demo/acme-docs", sidebarHidden: true)
    private let reserved = Space(name: "No space", path: "/Users/demo", hidden: true, holdsThreads: true)

    @Test func theListIsTheHostsOrderWithoutItsReservedSpaces() {
        let state = ShepherdState(spaces: [api, reserved, web, docs])
        #expect(SpaceLifecyclePresentation.spaces(in: state).map(\.name) == ["acme-api", "acme-web", "acme-docs"])
    }

    @Test func aNameIsTrimmedAndAnEmptyOrUnchangedOneIsNotSent() {
        #expect(SpaceLifecyclePresentation.renamed("  acme-site \n", from: "acme-web") == "acme-site")
        #expect(SpaceLifecyclePresentation.renamed("   ", from: "acme-web") == nil)
        #expect(SpaceLifecyclePresentation.renamed(" acme-web ", from: "acme-web") == nil)
    }

    /// Each step names the target the host's `move(before:)` takes, and the first and last cannot go further.
    @Test func moveUpAndDownNameTheTargetTheHostTakes() {
        let spaces = [web, api, docs]
        #expect(SpaceLifecyclePresentation.moveUp(web.id, in: spaces) == nil)
        #expect(SpaceLifecyclePresentation.moveUp(api.id, in: spaces) == .move(before: web.id))
        #expect(SpaceLifecyclePresentation.moveUp(docs.id, in: spaces) == .move(before: api.id))
        #expect(SpaceLifecyclePresentation.moveDown(web.id, in: spaces) == .move(before: docs.id))
        #expect(SpaceLifecyclePresentation.moveDown(api.id, in: spaces) == .move(before: nil))
        #expect(SpaceLifecyclePresentation.moveDown(docs.id, in: spaces) == nil)
        #expect(SpaceLifecyclePresentation.moveUp(SpaceID(), in: spaces) == nil)
        // Applied as the host does, the order is the one asked for.
        #expect(spaces.moving(web.id, before: docs.id)?.map(\.name) == ["acme-api", "acme-web", "acme-docs"])
        #expect(spaces.moving(api.id, before: nil)?.map(\.name) == ["acme-web", "acme-docs", "acme-api"])
    }

    @Test func removingSaysWhatItStopsAndWhatItKeepsAsTheMacDoes() {
        let one = SpaceLifecyclePresentation.removeMessage(name: "acme-web", threads: 1)
        #expect(one.hasPrefix("Removes acme-web from the sidebar and stops its 1 agent. "))
        #expect(SpaceLifecyclePresentation.removeMessage(name: "acme-web", threads: 3).contains("stops its 3 agents."))
        #expect(one.contains("The local folder and all its files are kept."))
        let thread = Agent(name: "fix login", spaceID: web.id, tabID: TabID(), paneID: PaneID())
        let state = ShepherdState(spaces: [web, api], agents: [thread])
        #expect(SpaceLifecyclePresentation.threads(in: state, of: web) == 1)
        #expect(SpaceLifecyclePresentation.threads(in: state, of: api) == 0)
    }

    @Test func aHiddenSpaceOffersToShowAndAShownOneToHide() {
        #expect(SpaceLifecyclePresentation.toggleTitle(of: web) == "Hide from Sidebar")
        #expect(SpaceLifecyclePresentation.toggleTitle(of: docs) == "Show in Sidebar")
    }
}
