import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// Which threads may send work to other Macs at all (`FleetDispatch.scopeProblem`), and the ids a tool
/// call's key stands for.
@Suite("Fleet dispatch scope")
struct FleetDispatchScopeTests {
    static func state(_ edit: (inout Agent) -> Void = { _ in }) -> (ShepherdState, AgentID) {
        let space = Space(name: "acme-web", path: "/tmp/acme-web", repoKey: "github.com/acme/web")
        let pane = LeafPane(cwd: space.path, agentID: AgentID())
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var agent = Agent(id: pane.agentID!, name: "Ship", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        edit(&agent)
        return (ShepherdState(spaces: [space], tabs: [tab], agents: [agent]), agent.id)
    }

    @Test func anOrdinaryThreadMaySendWork() {
        let (state, id) = Self.state()
        #expect(FleetDispatch.scopeProblem(for: id, in: state, unattended: []) == nil)
    }

    @Test func aCoordinatorADesignAgentAndAnAutomationRunMayNot() throws {
        for (what, edit) in [("coordinator", { (agent: inout Agent) in agent.coordinatorFor = ProjectID() }),
                             ("design", { (agent: inout Agent) in agent.designID = DesignID() })] as [(String, (inout Agent) -> Void)] {
            var (state, id) = Self.state(edit)
            if what == "design" { state.designs = [Design(id: state.agents[0].designID!, name: "Checkout", agentID: id, createdAt: 1)] }
            let refusal = try #require(FleetDispatch.scopeProblem(for: id, in: state, unattended: []), "\(what) thread allowed")
            #expect(refusal.code == FleetDispatchCode.fleetScope)
        }
        let (state, id) = Self.state()
        #expect(FleetDispatch.scopeProblem(for: id, in: state, unattended: [id])?.code == FleetDispatchCode.fleetScope, "an automation run")
        #expect(FleetDispatch.scopeProblem(for: AgentID(), in: state, unattended: [])?.code == "no_such_agent")
    }

    /// A thread the person started is 0; each thread one starts, here or on another Mac, is one deeper, and one 3 deep starts none.
    @Test func depthLimitsWhatAThreadStartsWhereverItRuns() {
        let mac = UUID()
        func dispatched(agent: AgentID?, depth: Int?) -> (inout Agent) -> Void {
            { $0.dispatchedFrom = DispatchedFrom(hostID: mac, hostName: "MacBook Pro", agentID: agent, agentTitle: "Ship", dispatchID: UUID(), at: 1, depth: depth) }
        }
        let cases: [(String, (inout Agent) -> Void, Int)] = [
            ("the person's", { _ in }, 0),
            ("sent by the person with Auto", dispatched(agent: nil, depth: nil), 0),
            ("sent by an older Mac's thread", dispatched(agent: AgentID(), depth: nil), 1),
            ("sent two deep", dispatched(agent: AgentID(), depth: 2), 2),
            ("started here three deep", { $0.startedBy = StartedBy(agentID: AgentID(), agentTitle: "Ship", at: 1, depth: 3) }, 3),
            ("sent three deep", dispatched(agent: AgentID(), depth: 3), 3),
        ]
        for (what, edit, depth) in cases {
            let (state, id) = Self.state(edit)
            #expect(state.agents[0].threadDepth == depth, "\(what)")
            // Depth never closes the other fleet tools: only starting one.
            #expect(FleetDispatch.scopeProblem(for: id, in: state, unattended: []) == nil, "\(what)")
            #expect((FleetDispatch.depthProblem(for: id, in: state)?.code == FleetDispatchCode.tooDeep) == (depth >= StartedBy.maxDepth), "\(what)")
        }
    }

    @Test func legacyInboundDispatchKeepsItsRecordWithoutMoveMetadata() throws {
        let json = """
        {"record":{"id":"F94561E6-7623-4BB2-8FB2-217B427A948C","parentHostID":"69EBE0BF-797D-4DE2-9E90-A4287C84186D",
                   "kind":"agentDispatch","state":"running","title":"Check receipts","repoKey":"github.com/acme/web"},
         "expectsResult":true,"startedWorking":true,"unsent":false,"worktree":"/tmp/acme-web","acceptedAt":1200}
        """
        let entry = try JSONDecoder().decode(FleetDispatch.Inbound.self, from: Data(json.utf8))
        #expect(entry.record.title == "Check receipts")
        #expect(entry.record.state == .running)
        #expect(entry.expectsResult && entry.startedWorking && !entry.unsent)
        #expect(entry.worktree == "/tmp/acme-web" && entry.acceptedAt == 1200)
        #expect(!entry.madeRef)
    }

    @Test func aToolCallKeyStandsForOneStableIdPerThread() {
        let (one, two) = (AgentID(), AgentID())
        #expect(FleetDispatch.identifier(key: "toolu_01", agent: one) == FleetDispatch.identifier(key: "toolu_01", agent: one))
        #expect(FleetDispatch.identifier(key: "toolu_01", agent: one) != FleetDispatch.identifier(key: "toolu_02", agent: one))
        #expect(FleetDispatch.identifier(key: "toolu_01", agent: one) != FleetDispatch.identifier(key: "toolu_01", agent: two), "no thread can name another's dispatch")
        let id = UUID()
        #expect(FleetDispatch.identifier(key: id.uuidString.lowercased(), agent: one) == id, "a dispatch's own id names it")
    }

    @Test func slugsSubdirectoriesAndShortstatsAreSafe() {
        #expect(FleetDispatchGit.slug("Fix flaky payment test!") == "fix-flaky-payment-test")
        #expect(FleetDispatchGit.slug("  ../..  ") == "dispatch" && FleetDispatchGit.slug("") == "dispatch")
        #expect(FleetDispatchGit.slug(String(repeating: "word ", count: 30)).count <= 40)
        #expect(FleetDispatchGit.isSafeSubdirectory("apps/web") && !FleetDispatchGit.isSafeSubdirectory("../x") && !FleetDispatchGit.isSafeSubdirectory("/etc")
                && !FleetDispatchGit.isSafeSubdirectory("a//b") && !FleetDispatchGit.isSafeSubdirectory(".git/hooks") && !FleetDispatchGit.isSafeSubdirectory(""))
        #expect(FleetDispatchGit.isCommit(String(repeating: "a", count: 40)) && !FleetDispatchGit.isCommit("main") && !FleetDispatchGit.isCommit("--upload-pack=x"))
        let stat = FleetDispatchGit.parseShortstat(" 3 files changed, 10 insertions(+), 2 deletions(-)")
        #expect(stat.files == 3 && stat.insertions == 10 && stat.deletions == 2)
        #expect(FleetDispatchGit.parseShortstat(" 1 file changed, 4 deletions(-)") == (1, 0, 4))
        #expect(FleetDispatchGit.parseShortstat("") == (0, 0, 0))
    }
}
