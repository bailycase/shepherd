import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The Mac sidebar's thread groups on the iPhone and iPad: Needs you, Working, Done, Pinned and Recents, each thread once.
@Suite("Fleet sidebar: the Mac's groups on iPhone and iPad")
struct FleetSidebarTests {
    typealias F = FleetTests
    static let session = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    static let next = UUID(uuidString: "00000000-0000-4000-8000-0000000000bb")!

    static func agent(_ id: String, _ status: AgentStatus, active: Double? = nil) -> Agent {
        var agent = F.agent(id, status)
        agent.lastActiveAt = active
        return agent
    }

    static func hosts(_ agents: [Agent], phase: RemoteHostPhase = .connected, automations: [Automation] = []) -> [FleetHost] {
        [F.host(F.studio, "Studio", phase, agents: agents, automations: automations)]
    }

    static func groups(_ state: FleetSidebarState, _ hosts: [FleetHost]) -> FleetSidebarGroups {
        state.groups(FleetModel(hosts: hosts, digests: [:]))
    }

    static func refs(_ rows: [FleetThreadRow]) -> [String] { rows.map(\.ref.agent.rawValue) }

    /// A state that has seen `agents` go from idle to their statuses on one connection.
    static func observed(_ agents: [Agent], pins: [FleetRef] = []) -> FleetSidebarState {
        var state = FleetSidebarState(pins: pins)
        state.reconcile(hosts(agents.map { var idle = $0; idle.status = .idle; return idle }), sessions: [F.studio: session])
        state.reconcile(hosts(agents), sessions: [F.studio: session])
        return state
    }

    // MARK: Groups

    @Test func everyThreadIsInExactlyOneGroup() {
        let agents = [Self.agent("ask", .blocked), Self.agent("run", .working), Self.agent("fin", .done, active: 5),
                      Self.agent("calm", .idle), Self.agent("pinned", .working)]
        let state = Self.observed(agents, pins: [F.ref("pinned")])
        let groups = Self.groups(state, Self.hosts(agents))
        #expect(groups.needsYou.map(\.ref) == [F.ref("ask")])
        #expect(Self.refs(groups.working) == ["run"])
        #expect(Self.refs(groups.done) == ["fin"])
        #expect(groups.pinned.map(\.ref) == [F.ref("pinned")])
        #expect(Self.refs(groups.recents) == ["calm"])
        let all = groups.needsYou.map(\.ref) + groups.working.map(\.ref) + groups.done.map(\.ref) + groups.pinned.map(\.ref)
            + groups.recents.map(\.ref)
        #expect(Set(all).count == agents.count && all.count == agents.count)
    }

    @Test func aPinnedThreadStaysPinnedWhateverItsStateAndKeepsItsReason() throws {
        for status in AgentStatus.allCases {
            let agents = [Self.agent("p", status)]
            let groups = Self.groups(Self.observed(agents, pins: [F.ref("p")]), Self.hosts(agents))
            #expect(groups.pinned.map(\.ref) == [F.ref("p")], "\(status)")
            #expect(groups.needsYou.isEmpty && groups.working.isEmpty && groups.done.isEmpty && groups.recents.isEmpty, "\(status)")
            if status == .blocked {
                guard case .attention(let item) = try #require(groups.pinned.first) else { Issue.record("blocked pin lost its question"); continue }
                #expect(item.reason == "needs you")
            }
        }
    }

    @Test func pinsKeepTheOrderTheyWerePinnedIn() {
        var state = FleetSidebarState()
        for id in ["c", "a", "b"] { state.pin(F.ref(id)) }
        state.pin(F.ref("c"))
        #expect(state.pins == [F.ref("c"), F.ref("a"), F.ref("b")], "pinning again moves nothing")
        state.unpin(F.ref("c"))
        state.pin(F.ref("c"))
        #expect(state.pins == [F.ref("a"), F.ref("b"), F.ref("c")], "unpin then pin goes last, as on the Mac")
        let agents = ["a", "b", "c"].map { Self.agent($0, .idle) }
        #expect(Self.groups(state, Self.hosts(agents)).pinned.map(\.ref) == state.pins)
    }

    @Test func automationRunsAndDesignsAreNeverThreadGroupsOrPinnable() {
        let run = Self.agent("run", .working)
        let automation = Automation(id: AutomationID(rawValue: "a1"), name: "Nightly", prompt: "p", cwd: "/src", agentID: run.id)
        let state = Self.observed([run], pins: [F.ref("run")])
        let groups = Self.groups(state, Self.hosts([run], automations: [automation]))
        #expect(groups.working.isEmpty && groups.pinned.isEmpty && groups.recents.isEmpty)
        let abilities = FleetThreadAbilities(agent: run, state: ShepherdState(agents: [run], automations: [automation]),
                                             connected: true, capabilities: Set(RemoteProtocol.capabilities))
        #expect(!abilities.pin && abilities.moveSpaces.isEmpty)
    }

    // MARK: Done

    @Test func doneIsACompletionThisDeviceSawNotJustADoneStatus() {
        let agents = [Self.agent("fin", .done, active: 9)]
        var fresh = FleetSidebarState()
        fresh.reconcile(Self.hosts(agents), sessions: [F.studio: Self.session])
        #expect(Self.refs(Self.groups(fresh, Self.hosts(agents)).done) == ["fin"], "first sight of a done thread counts once")
        // Negative control: the same done thread on the same connection is not a second completion after it was seen.
        fresh.markSeen([F.ref("fin")])
        fresh.reconcile(Self.hosts(agents), sessions: [F.studio: Self.session])
        #expect(Self.groups(fresh, Self.hosts(agents)).done.isEmpty)
        #expect(Self.refs(Self.groups(fresh, Self.hosts(agents)).recents) == ["fin"])
    }

    @Test func openingAnotherThreadMarksTheOneReadSeenAndALaterTurnBringsItBack() {
        var agents = [Self.agent("a", .done, active: 1), Self.agent("b", .done, active: 2)]
        var state = Self.observed(agents)
        state.select(F.ref("a"))
        #expect(Set(Self.refs(Self.groups(state, Self.hosts(agents)).done)) == ["a", "b"], "reading keeps it in Done")
        state.select(nil)
        state.select(F.ref("a"))
        #expect(Self.refs(Self.groups(state, Self.hosts(agents)).done).contains("a"), "a page or the same thread changes nothing")
        state.select(F.ref("b"))
        #expect(Self.refs(Self.groups(state, Self.hosts(agents)).done) == ["b"])
        #expect(Self.refs(Self.groups(state, Self.hosts(agents)).recents) == ["a"])
        agents[0].status = .working
        state.reconcile(Self.hosts(agents), sessions: [F.studio: Self.session])
        agents[0].status = .done
        agents[0].lastActiveAt = 3
        state.reconcile(Self.hosts(agents), sessions: [F.studio: Self.session])
        #expect(Set(Self.refs(Self.groups(state, Self.hosts(agents)).done)) == ["a", "b"], "a new completion is unseen")
    }

    @Test func markAllSeenClearsDoneWithoutTouchingOtherGroups() {
        let agents = [Self.agent("a", .done, active: 1), Self.agent("r", .working)]
        var state = Self.observed(agents)
        state.markSeen([F.ref("a")])
        let groups = Self.groups(state, Self.hosts(agents))
        #expect(groups.done.isEmpty)
        #expect(Self.refs(groups.working) == ["r"])
    }

    @Test func aReconnectWithAMovedStampIsACompletionAndAnUnmovedOneIsNot() {
        var agents = [Self.agent("a", .done, active: 1)]
        var state = Self.observed(agents)
        state.markSeen([F.ref("a")])
        state.reconcile(Self.hosts(agents), sessions: [F.studio: Self.next])
        #expect(Self.groups(state, Self.hosts(agents)).done.isEmpty, "the same stamp on a new connection is not a completion")
        agents[0].lastActiveAt = 2
        state.reconcile(Self.hosts(agents), sessions: [F.studio: UUID()])
        #expect(Self.refs(Self.groups(state, Self.hosts(agents)).done) == ["a"])
    }

    @Test func anOfflineHostsThreadsAreNeverWorkingOrDoneButKeepTheirPins() {
        let agents = [Self.agent("run", .working), Self.agent("fin", .done, active: 1), Self.agent("pin", .idle)]
        let state = Self.observed(agents, pins: [F.ref("pin")])
        let offline = Self.hosts(agents, phase: .failed(RemoteHostFailure(kind: .unreachable, detail: "gone")))
        var after = state
        after.reconcile(offline, sessions: [:])
        let groups = Self.groups(after, offline)
        #expect(groups.working.isEmpty && groups.done.isEmpty)
        #expect(groups.pinned.map(\.ref) == [F.ref("pin")], "a pin on an offline host stays, dimmed")
        #expect(Set(Self.refs(groups.recents)) == ["run", "fin"])
    }

    // MARK: Pins' lifetime

    @Test func aPinGoesWithItsThreadOrHostButNotWhileTheHostIsOffline() {
        var state = FleetSidebarState(pins: [F.ref("a"), F.ref("b"), F.ref("x", on: F.build)])
        let offline = Self.hosts([], phase: .failed(RemoteHostFailure(kind: .unreachable, detail: "gone")))
        state.reconcile(offline + [F.host(F.build, "Build", agents: [])], sessions: [:])
        #expect(state.pins == [F.ref("a"), F.ref("b")], "the connected host lost x; the offline host keeps its pins")
        state.reconcile(Self.hosts([Self.agent("a", .idle)]), sessions: [F.studio: Self.session])
        #expect(state.pins == [F.ref("a")], "b was deleted on its connected host")
        state.reconcile([], sessions: [:])
        #expect(state.pins.isEmpty, "a forgotten host takes its pins")
    }

    // MARK: Abilities

    @Test func theMenuOffersOnlyWhatTheHostCanDo() {
        let space2 = Space(id: SpaceID(rawValue: "s2"), name: "Other", path: "/src/Other")
        let agent = Self.agent("t", .idle)
        let state = ShepherdState(spaces: [F.space, F.hidden, space2], agents: [agent])
        let all = Set(RemoteProtocol.capabilities)
        let full = FleetThreadAbilities(agent: agent, state: state, connected: true, capabilities: all)
        #expect(full.rename && full.delete && full.pin && full.review && !full.finalize)
        #expect(full.moveSpaces.map(\.id) == [F.space.id, space2.id], "never a hidden space")

        let older = FleetThreadAbilities(agent: agent, state: state, connected: true,
                                         capabilities: all.subtracting([RemoteProtocol.moveThreadCapability]))
        #expect(older.moveSpaces.isEmpty && older.rename)

        let offline = FleetThreadAbilities(agent: agent, state: state, connected: false, capabilities: all)
        #expect(!offline.rename && !offline.delete && !offline.review && offline.moveSpaces.isEmpty)
        #expect(offline.pin, "a pin is this device's, so Unpin stays while the host is offline")

        var worktree = agent
        worktree.worktreeBranch = "agent/x"
        let tree = FleetThreadAbilities(agent: worktree, state: state, connected: true, capabilities: all)
        #expect(tree.finalize && tree.moveSpaces.isEmpty, "worktree threads finalize and never move")
        let noSetup = FleetThreadAbilities(agent: worktree, state: state, connected: true,
                                           capabilities: all.subtracting([RemoteProtocol.worktreeSetupCapability]))
        #expect(!noSetup.finalize)
    }
}
