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

    /// Two Macs of a fleet hold the same space ID. A confirmation opened on one is for that one: Organize showing the other ends it, and
    /// the answer resolves to the host that asked, which sends nothing once it is offline.
    @MainActor @Test func aConfirmationBelongsToTheHostThatOpenedIt() {
        let macA = UUID(), macB = UUID()
        let dialogs = SpaceLifecycleDialogs()
        dialogs.removal = SpaceLifecycleTarget(host: macA, space: web.id)
        dialogs.rename = .init(target: SpaceLifecycleTarget(host: macA, space: web.id), name: "acme-site")

        dialogs.keep(for: macA)
        #expect(dialogs.removal != nil && dialogs.rename != nil, "still the host Organize shows")
        // Mac A disconnects and Organize shows Mac B, which has a space with the same ID.
        dialogs.keep(for: macB)
        #expect(dialogs.removal == nil && dialogs.rename == nil)

        dialogs.removal = SpaceLifecycleTarget(host: macA, space: web.id)
        dialogs.keep(for: nil)
        #expect(dialogs.removal == nil, "no host shown")

        let hosts = [SettingsHost(id: macA, name: "Mac A", client: nil, capabilities: []),
                     SettingsHost(id: macB, name: "Mac B", client: FakeSettingsClient(), capabilities: [RemoteProtocol.spaceLifecycleCapability])]
        let asked = SpaceLifecycleDialogs.host(of: SpaceLifecycleTarget(host: macA, space: web.id), in: hosts)
        #expect(asked?.id == macA && asked?.client == nil, "never Mac B's client")
        #expect(SpaceLifecycleDialogs.host(of: SpaceLifecycleTarget(host: UUID(), space: web.id), in: hosts) == nil)
    }

    /// The store is shared by every iPad window. A's captured Remove or Rename answers nothing once B's confirmation for the same space ID
    /// replaced it, and B's answers only on B.
    @MainActor @Test func aStaleConfirmationSendsNothingToEitherMac() {
        let macA = UUID(), macB = UUID()
        let a = SpaceLifecycleTarget(host: macA, space: web.id), b = SpaceLifecycleTarget(host: macB, space: web.id)
        let dialogs = SpaceLifecycleDialogs()

        dialogs.removal = a
        dialogs.rename = .init(target: a, name: "acme-site")
        #expect(dialogs.confirmRemoval(a, shown: macA) == a && dialogs.confirmRename(a, shown: macA)?.name == "acme-site")
        #expect(dialogs.confirmRemoval(a, shown: macB) == nil, "A's confirmation while B is shown")

        dialogs.removal = b
        dialogs.rename = .init(target: b, name: "acme-shop")
        #expect(dialogs.confirmRemoval(a, shown: macA) == nil && dialogs.confirmRemoval(a, shown: macB) == nil)
        #expect(dialogs.confirmRename(a, shown: macA) == nil && dialogs.confirmRename(a, shown: macB) == nil)
        #expect(dialogs.confirmRemoval(b, shown: macA) == nil, "B's confirmation while A is shown")
        #expect(dialogs.confirmRemoval(b, shown: macB) == b && dialogs.confirmRename(b, shown: macB)?.target == b)

        dialogs.removal = nil
        #expect(dialogs.confirmRemoval(b, shown: macB) == nil, "already answered or dismissed")
    }

    /// A's bindings and actions, built by the factory Organize uses verbatim, fire late after B's confirmation replaced it (the store is
    /// shared by every iPad window): typing, dismissing, Rename and Remove touch nothing of B's, and nothing is sent. B's own still work.
    @MainActor @Test func aStaleDialogsBindingsLeaveTheNewOnesAlone() async throws {
        let macA = UUID(), macB = UUID()
        let clientA = FakeSettingsClient(), clientB = FakeSettingsClient()
        let hosts = [SettingsHost(id: macA, name: "Mac A", client: clientA, capabilities: [RemoteProtocol.spaceLifecycleCapability]),
                     SettingsHost(id: macB, name: "Mac B", client: clientB, capabilities: [RemoteProtocol.spaceLifecycleCapability])]
        let a = SpaceLifecycleTarget(host: macA, space: web.id), b = SpaceLifecycleTarget(host: macB, space: web.id)
        let dialogs = SpaceLifecycleDialogs()
        var shown: UUID? = macA
        var sent: [(RemoteSpaceLifecycle, SpaceLifecycleTarget)] = []
        func make() -> SpaceDialogBindings {
            SpaceDialogBindings.make(dialogs: dialogs, spaces: [web], shown: { shown }, send: { sent.append(($0, $1)) })
        }
        // What the send path does with each: the host the target is on, through its own client.
        func deliver() async throws {
            for (action, target) in sent { try await SpaceLifecycleDialogs.host(of: target, in: hosts)?.client?.spaceLifecycle(action, spaceID: target.space) }
            sent = []
        }

        dialogs.removal = a
        dialogs.rename = .init(target: a, name: "acme-site")
        let stale = make()
        #expect(stale.renamed?.id == web.id && stale.removed?.id == web.id)
        #expect(stale.isRenaming.wrappedValue && stale.isRemoving.wrappedValue)
        // B's confirmation replaces A's.
        dialogs.removal = b
        dialogs.rename = .init(target: b, name: "acme-shop")

        for hostShown in [macA, macB] {
            shown = hostShown
            stale.name.wrappedValue = "acme-site"
            stale.isRenaming.wrappedValue = false
            stale.isRemoving.wrappedValue = false
            stale.rename()
            stale.remove()
            #expect(dialogs.rename == .init(target: b, name: "acme-shop"), "B's draft, with \(hostShown == macA ? "A" : "B") shown")
            #expect(dialogs.removal == b, "B's confirmation, with \(hostShown == macA ? "A" : "B") shown")
        }
        try await deliver()
        #expect(clientA.requests.isEmpty && clientB.requests.isEmpty)

        // B's own edit, answer and dismiss it, and only on B.
        shown = macB
        let current = make()
        #expect(current.isRenaming.wrappedValue && current.isRemoving.wrappedValue)
        current.name.wrappedValue = "acme-store"
        #expect(dialogs.rename?.name == "acme-store")
        shown = macA
        current.rename()
        current.remove()
        #expect(sent.isEmpty, "B's answers while A is shown")
        shown = macB
        current.rename()
        current.remove()
        try await deliver()
        #expect(clientA.requests.isEmpty && clientB.requests.count == 2)
        current.isRenaming.wrappedValue = false
        current.isRemoving.wrappedValue = false
        #expect(dialogs.rename == nil && dialogs.removal == nil)
    }

    /// Forgetting the shown host while another remains: the hosts change, the dialog opened on the forgotten one ends.
    @MainActor @Test func forgettingTheShownHostEndsItsConfirmations() {
        let macA = UUID(), macB = UUID()
        func host(_ id: UUID) -> SettingsHost {
            SettingsHost(id: id, name: "Mac", client: FakeSettingsClient(), capabilities: [RemoteProtocol.hostSettingsCapability])
        }
        let dialogs = SpaceLifecycleDialogs()
        dialogs.removal = SpaceLifecycleTarget(host: macA, space: web.id)
        dialogs.rename = .init(target: SpaceLifecycleTarget(host: macA, space: web.id), name: "acme-site")

        dialogs.keep(shownIn: [host(macA), host(macB)])
        #expect(dialogs.removal != nil && dialogs.rename != nil, "A is still the host shown")
        dialogs.keep(shownIn: [host(macB)])
        #expect(dialogs.removal == nil && dialogs.rename == nil)
    }
}
