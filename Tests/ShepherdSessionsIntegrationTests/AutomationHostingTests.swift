import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport

/// Automations served by `SessionServer` with no app (`headlessAutomationHosting`): an enabled
/// automation's run starts at launch, Stop deletes it, the `automation_*` requests are answered,
/// and a triggered run starts its thread on a worktree. `startNewAgent` is the start under all of them.
@Suite("Automations hosted by the server", .mainActorExclusive)
@MainActor
struct AutomationHostingTests {
    /// The iPhone and iPad Automations screens' requests (`RemoteHostClient.automation`), served
    /// with no app: create, run, read its runs, stop, turn off, delete.
    @Test func aRemoteClientManagesAutomationsWithoutTheApp() async throws {
        try StubPi.installAsEngine()
        let remote = try RemoteHost()
        defer { remote.stop() }
        serve(remote.host)
        let client = try await remote.typed()
        defer { client.disconnect() }
        let id = AutomationID()
        let draft = RemoteAutomationDraft(name: "watch CI", prompt: "Watch CI", cwd: remote.host.dir.path, enabled: true)
        try await client.automation(id, request: .create(draft: draft))
        try await client.automation(id, request: .run)
        let run = try #require(remote.server.state.automations.first?.agentID)
        try await eventually("the run in its log") { @Sendable in (try? await client.automationRuns(id))?.first?.agentID == run }
        try await client.automation(id, request: .stop)
        try await eventuallyOnMain("the run to stop") { !remote.server.state.agents.contains { $0.id == run } }
        try await client.automation(id, request: .setEnabled(enabled: false))
        #expect(remote.server.state.automations.first?.enabled == false)
        try await client.automation(id, request: .delete)
        #expect(remote.server.state.automations.isEmpty)
    }

    private func serve(_ h: ScratchServer) {
        // The host's MCP, as `ShepherdHost` resolves it from the app's servers and Keychain.
        let mcp: AgentSpawn.MCP = { _, _, _, _, _ in MCPLaunch(extensions: MCPLaunch.builtIns, environment: ["MCP_SECRET": "acme-token"]) }
        let hosting = h.server.headlessAutomationHosting(launch: { AgentLaunchSettings() }, mcp: mcp, defaults: {
            AutomationHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                       worktreeFetchBeforeCreate: false, projectsEnabled: false)
        })
        h.server.serveAutomations(hosting)
    }

    private func paneSession(_ agent: Agent, on h: ScratchServer) -> SessionID? {
        h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: agent.paneID!)?.sessionID
    }

    private func launch(of id: AgentID) -> StubPi.Launch? {
        StubPi.launches().last { $0.env["SHEPHERD_AGENT_ID"] == id.rawValue }
    }

    @Test func aNewAgentStartsBoundToItsPane() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        let config = NewAgentConfig(spaceID: space.id, workingDirectory: h.dir.path, model: "stub/model-a", thinking: .low,
                                    initialPrompt: "Check the build")
        let id = try await h.server.startNewAgent(config, launch: AgentLaunchSettings(), defaultServiceTier: .standard)
        let agent = try #require(h.server.state.agents.first { $0.id == id })
        #expect(agent.spaceID == space.id && agent.name == "Check the build")
        let session = try #require(paneSession(agent, on: h))
        #expect(await h.server.sessionInfo(sessionID: session)?.isAlive == true)
        try await eventuallyOnMain("the stub to record the launch") { launch(of: id) != nil }
    }

    @Test func anEnabledAutomationRunsAtLaunchAndStopDeletesIt() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let automation = Automation(name: "watch CI", prompt: "Watch CI", cwd: h.dir.path, enabled: true)
        try await h.server.addAutomation(automation)
        serve(h)
        await h.server.autoStartAutomations()

        let run = try #require(h.server.state.automations.first?.agentID)
        let agent = try #require(h.server.state.agents.first { $0.id == run })
        #expect(agent.name == "watch CI")
        #expect(h.server.state.spaces.first { $0.id == agent.spaceID }?.holdsAutomations == true)
        #expect(paneSession(agent, on: h) != nil)
        try await eventuallyOnMain("the run's pi to launch") { launch(of: run) != nil }
        #expect(launch(of: run)?.env["SHEPHERD_AUTOMATION"] == "1", "a run can't create automations")
        #expect(launch(of: run)?.env["MCP_SECRET"] == "acme-token", "a run's pi gets the host's MCP")

        try h.server.stopAutomation(automation.id)
        try await eventuallyOnMain("the run to go") {
            !h.server.state.agents.contains { $0.id == run } && h.server.state.automations.first?.agentID == nil
        }
    }

    @Test func automationRequestsAreAnsweredWithoutTheApp() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        serve(h)
        let handler = try #require(h.server.onAutomationRequest)
        func ask(_ request: AutomationRequest) async -> AutomationOutcome {
            await withCheckedContinuation { done in handler(request) { done.resume(returning: $0) } }
        }
        let automation = Automation(name: "nightly triage", prompt: "Triage", cwd: h.dir.path, enabled: true)
        #expect(await ask(.create(automation: automation, start: true)) == .ok)
        let run = try #require(h.server.state.automations.first?.agentID)
        guard case .automations(let infos) = await ask(.list) else { Issue.record("expected a list"); return }
        #expect(infos.map(\.name) == ["nightly triage"] && infos.first?.agentStatus != nil)
        #expect(await ask(.start(automationID: automation.id)) != .ok, "a live run refuses a second")
        #expect(await ask(.delete(automationID: automation.id)) == .ok)
        try await eventuallyOnMain("the automation and its run to go") {
            h.server.state.automations.isEmpty && !h.server.state.agents.contains { $0.id == run }
        }
    }

    @Test func aTriggeredRunStartsItsThreadOnAWorktree() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let repo = try makeScratchRepo()
        let space = Space(name: "acme-app", path: repo.path)
        try await h.server.addSpace(space)
        let automation = Automation(name: "issue loop", prompt: "Implement it.", cwd: repo.path,
                                    trigger: .github([GitHubTrigger(events: [.issueLabeled], labels: ["shepherd"])]))
        try await h.server.addAutomation(automation)
        serve(h)

        // Run now on a triggered automation: one event-less run.
        try await h.server.startAutomation(automation.id)
        let run = try #require(h.server.state.agents.first { $0.automationOrigin?.automationID == automation.id })
        #expect(run.spaceID == space.id)
        #expect(run.worktreeBranch?.hasPrefix("automation/issue-loop-") == true)
        let path = try #require(run.worktreePath)
        #expect(FileManager.default.fileExists(atPath: path) && path != repo.path)
        try await eventuallyOnMain("the run's pi to launch") { launch(of: run.id) != nil }
        #expect(launch(of: run.id)?.env["SHEPHERD_AUTOMATION"] == "1")
    }
}
