import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A design's agent is no thread (docs/designs.md › Design agents and ordinary threads): the
/// palette lists no subagent of it, and a banner's Review never opens a thread's Changes pane for
/// it, whether the Design tool is on or off.
@Suite("Design isolation in the app", .mainActorExclusive)
@MainActor
struct DesignIsolationFlowTests {
    private func start(_ app: AppHarness, designToolOn: Bool) async throws -> (ShepherdViewModel, thread: Agent, drawer: Agent) {
        app.settings.designToolEnabled = designToolOn
        let space = Fixture.space(path: app.dir.path)
        let thread = Fixture.agent("Fix login bug", in: space)
        var drawer = Fixture.agent("Landing hero", in: space, order: 1)
        let design = Design(name: "Landing hero", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        var state = Fixture.state(spaces: [space], agents: [thread, drawer])
        state.designs = [design]
        let vm = try await app.start(with: state)
        return (vm, thread.agent, drawer.agent)
    }

    @Test(arguments: [false, true])
    func thePaletteListsOnlyAThreadsSubagents(designToolOn: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, thread, drawer) = try await start(app, designToolOn: designToolOn)

        vm.applyAgentChildren(thread.id, [ChildRun(runID: "scout", label: "scout", state: "running")])
        vm.applyAgentChildren(drawer.id, [ChildRun(runID: "painter", label: "painter", state: "running")])

        let parents = vm.paletteItems.compactMap { item -> AgentID? in
            if case .child(let agentID, _) = item.kind { return agentID }
            return nil
        }
        #expect(parents == [thread.id])
    }

    @Test(arguments: [false, true])
    func aBannersReviewNeverOpensChangesForADesignsAgent(designToolOn: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, thread, drawer) = try await start(app, designToolOn: designToolOn)

        vm.respond(to: BannerResponse(target: .agent(drawer.id), action: .review, text: nil, question: nil))
        #expect(!vm.subagentInspector.open.contains(.local(drawer.id)))

        vm.respond(to: BannerResponse(target: .agent(thread.id), action: .review, text: nil, question: nil))
        #expect(vm.subagentInspector.open.contains(.local(thread.id)), "a thread's Review still opens its Changes")
    }
}
