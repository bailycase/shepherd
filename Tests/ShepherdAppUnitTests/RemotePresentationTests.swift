import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// What a remote agent's pane draws, and the values its layout reads (`RemoteLayoutModel`).
@Suite("Remote presentation")
@MainActor
struct RemotePresentationTests {
    /// A host with one agent, whose layout is its thread beside one terminal, and another agent.
    @MainActor
    private struct Hosted {
        let connection = RemoteHostStore.Connection(config: .init(name: "build-01", host: "127.0.0.1", port: 7459, token: "fixture"))
        let thread: LeafPane
        let terminal = LeafPane(sessionID: SessionID(), cwd: "/srv/acme-web")
        let tab: Tab
        let utility: Tab
        let agentID = AgentID()
        let otherID = AgentID()
        var state: ShepherdState

        init() {
            let space = Space(name: "acme-web", path: "/srv/acme-web")
            thread = LeafPane(cwd: "/srv/acme-web", agentID: agentID)
            tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .horizontal, ratio: 0.6, first: .leaf(thread), second: .leaf(terminal)))
            let agent = Agent(id: agentID, name: "Checkout funnel", spaceID: space.id, tabID: tab.id, paneID: thread.id, status: .idle)
            let otherPane = LeafPane(cwd: "/srv/acme-web", agentID: otherID)
            let otherTab = Tab(spaceID: space.id, order: 1, layout: .leaf(otherPane))
            let other = Agent(id: otherID, name: "Search index", spaceID: space.id, tabID: otherTab.id, paneID: otherPane.id,
                              status: .idle)
            utility = Tab(spaceID: space.id, order: 2, layout: .leaf(LeafPane(sessionID: SessionID(), cwd: "/srv")), inspectorFor: agentID)
            state = ShepherdState(spaces: [space], tabs: [tab, otherTab, utility], agents: [agent, other])
        }

        var ref: RemoteAgentRef { RemoteAgentRef(hostID: connection.id, agentID: agentID) }

        mutating func edit(_ id: AgentID, _ change: (inout Agent) -> Void) {
            if let index = state.agents.firstIndex(where: { $0.id == id }) { change(&state.agents[index]) }
        }

        func host(_ phase: RemoteHostStore.Phase = .connected, lastSeen: Date? = nil, terminalTransport: UUID? = nil) -> RemoteLayoutModel.Host {
            .init(connection: connection, name: "build-01", phase: phase, lastSeen: lastSeen, state: state,
                  supportsChanges: true, terminalTransport: terminalTransport)
        }

        func presentation(_ host: RemoteLayoutModel.Host? = nil, _ screen: RemoteLayoutModel.Screen = .init()) -> RemotePresentation {
            RemoteLayoutModel.presentation(ref: ref, host: host ?? self.host(), screen: screen)
        }

        func model(_ host: RemoteLayoutModel.Host? = nil, _ screen: RemoteLayoutModel.Screen = .init()) throws -> RemoteLayoutModel {
            guard case .layout(let model) = presentation(host, screen) else { throw NotALayout() }
            return model
        }
    }

    private struct NotALayout: Error {}

    private func panel(shown: Bool, maximized: Bool) -> (TabID) -> TerminalPanels.Panel {
        { _ in TerminalPanels.Panel(shown: shown, chosenTab: nil, maximized: maximized) }
    }

    // MARK: The pane while its host is away

    @Test(arguments: [
        (RemoteHostStore.Phase.connecting, "connecting to build-01…"),
        (.failed(RemoteHostFailure(kind: .tokenRefused, detail: "refused")), "build-01 refused the token. Edit the host to paste its current token."),
        (.disconnected, "build-01 disconnected"),
    ])
    func aHostNeverSeenGivesItsPlaceholder(phase: RemoteHostStore.Phase, text: String) {
        let hosted = Hosted()
        #expect(hosted.presentation(hosted.host(phase)) == .placeholder(text, phase: phase.kind))
    }

    @Test func aRetryingHostSeenBeforeGivesTheAwayBanner() {
        let hosted = Hosted()
        let seen = Date(timeIntervalSince1970: 1_000)
        for phase in [RemoteHostStore.Phase.connecting, .failed(RemoteHostFailure(kind: .lost, detail: "dropped"))] {
            #expect(hosted.presentation(hosted.host(phase, lastSeen: seen))
                == .away(host: "build-01", hostID: hosted.connection.id, lastSeen: seen, phase: phase.kind))
        }
        // A refused token never retries, so it keeps its own placeholder.
        let refused = RemoteHostStore.Phase.failed(RemoteHostFailure(kind: .tokenRefused, detail: "refused"))
        guard case .placeholder = hosted.presentation(hosted.host(refused, lastSeen: seen)) else {
            Issue.record("a refused token shows the banner")
            return
        }
    }

    @Test func aConnectedHostWithoutTheAgentGivesTheNoLayoutPlaceholder() {
        var hosted = Hosted()
        let agentID = hosted.agentID
        hosted.state.agents.removeAll { $0.id == agentID }
        #expect(hosted.presentation(hosted.host()) == .placeholder("agent has no layout on build-01", phase: .connected))
    }

    @Test func thePanesCrossFadeFollowsThePhase() throws {
        let hosted = Hosted()
        #expect(try RemotePresentation.layout(hosted.model()).kind == .connected)
        #expect(RemotePresentation.placeholder("x", phase: .connecting).kind == .connecting)
        #expect(RemotePresentation.away(host: "h", hostID: UUID(), lastSeen: Date(), phase: .failed(.lost)).kind == .failed(.lost))
    }

    // MARK: The thread and its layout

    @Test func theThreadIsTheAgentsPrimaryPane() throws {
        let hosted = Hosted()
        let model = try hosted.model()
        #expect(model.thread == .init(paneID: hosted.thread.id, agentName: "Checkout funnel", cwd: "/srv/acme-web"))
        #expect(model.tab == hosted.tab)
        #expect(model.hostName == "build-01" && model.connection === hosted.connection)
        #expect(model.supportsChanges)
    }

    @Test func aHostsUtilityTabHasNoThread() throws {
        let hosted = Hosted()
        var screen = RemoteLayoutModel.Screen()
        screen.inspecting = true
        screen.inspectorTab = hosted.utility.id
        screen.inspectingRunID = "run-1"
        screen.sideTab = .changes
        screen.review = nil
        let model = try hosted.model(nil, screen)
        #expect(model.tab == hosted.utility)
        #expect(model.thread == nil)
        #expect(model.inspectingRunID == nil && model.sideTab == nil && model.review == nil)
    }

    @Test func anInspectedAgentWithoutAUtilityTabShowsItsOwnLayout() throws {
        let hosted = Hosted()
        var screen = RemoteLayoutModel.Screen()
        screen.inspecting = true
        #expect(try hosted.model(nil, screen).tab == hosted.tab)
    }

    @Test func anAgentThatDrawsADesignGivesTheDesign() {
        let hosted = Hosted()
        let design = DesignID()
        var screen = RemoteLayoutModel.Screen()
        screen.drawnDesign = design
        #expect(hosted.presentation(nil, screen) == .design(RemoteDesignRef(hostID: hosted.connection.id, designID: design), agent: hosted.ref,
                                                            name: "Checkout funnel", threadPaneID: hosted.thread.id))
        screen.inspecting = true
        guard case .layout = hosted.presentation(nil, screen) else {
            Issue.record("an inspected agent shows its utility tab, not its design")
            return
        }
    }

    // MARK: What a layout on screen reads

    @Test func aHiddenModelStaysALayoutWithNoFocusStartReviewOrFoldedState() throws {
        let hosted = Hosted()
        var screen = RemoteLayoutModel.Screen()
        screen.isVisible = false
        screen.focusedPaneID = hosted.thread.id
        screen.panel = panel(shown: true, maximized: true)
        let host = hosted.host(.connecting, lastSeen: Date(), terminalTransport: UUID())
        let model = try hosted.model(host, screen)
        #expect(!model.isVisible)
        #expect(model.focusedPaneID == nil)
        #expect(model.terminalStart == nil)
        #expect(model.hostReviewTarget == nil)
        #expect(model.foldedState == nil)
    }

    @Test(arguments: [
        (visible: true, shown: true, maximized: true, folded: true),
        (visible: false, shown: true, maximized: true, folded: false),
        (visible: true, shown: false, maximized: true, folded: false),
        (visible: true, shown: true, maximized: false, folded: false),
    ])
    func theFoldedStateIsSetOnlyWhileVisibleShownAndMaximized(visible: Bool, shown: Bool, maximized: Bool, folded: Bool) throws {
        var hosted = Hosted()
        hosted.edit(hosted.agentID) { $0.status = .working }
        var screen = RemoteLayoutModel.Screen()
        screen.isVisible = visible
        screen.panel = panel(shown: shown, maximized: maximized)
        #expect(try hosted.model(nil, screen).foldedState == (folded ? .running : nil))
    }

    @Test func aCoveredModelOnScreenHasNoFocus() throws {
        let hosted = Hosted()
        var screen = RemoteLayoutModel.Screen()
        screen.focusedPaneID = hosted.thread.id
        #expect(try hosted.model(nil, screen).focusedPaneID == hosted.thread.id)
        screen.covered = true
        #expect(try hosted.model(nil, screen).focusedPaneID == nil)
    }

    @Test func aModelOnScreenTargetsItsAgentsHostReview() throws {
        let hosted = Hosted()
        #expect(try hosted.model().hostReviewTarget == hosted.ref)
    }

    @Test(arguments: [
        (settings: false, visible: true, starts: true),
        (settings: true, visible: true, starts: false),
        (settings: false, visible: false, starts: false),
    ])
    func aTerminalStartsOnlyOnScreenAndPastSettings(settings: Bool, visible: Bool, starts: Bool) throws {
        let hosted = Hosted()
        let transport = UUID()
        var screen = RemoteLayoutModel.Screen()
        screen.isVisible = visible
        screen.settingsShown = settings
        #expect(try hosted.model(hosted.host(terminalTransport: transport), screen).terminalStart == (starts ? transport : nil))
    }

    @Test func aHostWithoutTerminalStartGivesNoTransport() throws {
        let hosted = Hosted()
        #expect(try hosted.model(hosted.host(terminalTransport: nil)).terminalStart == nil)
    }

    // MARK: Equality

    @Test func aPushAboutAnotherAgentLeavesTheModelEqual() throws {
        var hosted = Hosted()
        let before = try hosted.model()
        hosted.edit(hosted.otherID) { $0.status = .working; $0.name = "Search index v2" }
        #expect(try hosted.model() == before)
    }

    @Test func theAgentsOwnNameStatusInFoldedLineAndPanelChangeTheModel() throws {
        var hosted = Hosted()
        let before = try hosted.model()
        hosted.edit(hosted.agentID) { $0.name = "Checkout funnel v2" }
        #expect(try hosted.model() != before)

        // The status shows only in the folded line, so it reaches the model only there.
        hosted.edit(hosted.agentID) { $0.name = "Checkout funnel"; $0.status = .working }
        #expect(try hosted.model() == before)
        var screen = RemoteLayoutModel.Screen()
        screen.panel = panel(shown: true, maximized: true)
        let folded = try hosted.model(nil, screen)
        hosted.edit(hosted.agentID) { $0.status = .done }
        #expect(try hosted.model(nil, screen) != folded)
    }

    @Test func aModelComparesItsConnectionReviewAndReferencesByIdentity() throws {
        let hosted = Hosted()
        let model = try hosted.model()
        let other = RemoteHostStore.Connection(config: hosted.connection.config)
        let moved = RemoteLayoutModel.Host(connection: other, name: "build-01", phase: .connected, lastSeen: nil, state: hosted.state,
                                           supportsChanges: true)
        #expect(try hosted.model(moved) != model)
    }
}
