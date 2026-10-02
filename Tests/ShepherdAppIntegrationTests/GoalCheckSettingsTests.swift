import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Goal-check privacy settings", .integrationTimeLimit)
struct GoalCheckSettingsTests {
    @Test func thePrivacySwitchChangesRealAgentLaunchesWithoutChangingRunningAgents() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressAndLaunch() }
        }
    }

    @Test func theExperimentsGoalsSwitchChangesALiveControllerWithoutRestartingItsThread() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressExperiment() }
        }
    }

    @MainActor
    private static func pressExperiment() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let file = app.dir.appendingPathComponent("goal.json")
        let goal = NativeGoal(id: "00000000-0000-0000-0000-000000000001", text: "Tests pass", state: .working)
        try Data("null".utf8).write(to: file)
        let info = try await app.server.createSession(params: CreateSessionParams(cwd: app.dir.path, command: StubPi.command,
            env: ["STUB_PI_GOAL_FILE": file.path, "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "0"], runtime: .rpc))
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, piSession: info.id)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let before = try await app.readyThread(agent.agent.id)
        #expect(!app.settings.goalsEnabled && before.goal == nil && !before.supportedActions.contains("goal"))
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 900), dark: true,
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: app.settings, openInstructions: {}))
        defer { window.close() }
        func toggle() -> AccessibilityNode? {
            window.elements().first { $0.label == "Goals" && ($0.role == "AXCheckBox" || $0.role == "AXSwitch") }
        }
        try await eventuallyOnMain("the Goals experiment switch to attach") { toggle() != nil }
        try window.press("Goals", role: #require(toggle()?.role))
        try await eventuallyOnMain("Goals to turn on") { app.settings.goalsEnabled }
        func snapshot() async throws -> NativeThreadSnapshot? {
            if case .snapshot(let value) = try await app.server.nativeThread(agentID: agent.agent.id, request: .snapshot()) { return value }
            return nil
        }
        try await eventuallyAsync("the enabled controller to become available") {
            let value = try await snapshot()
            return value?.goal == nil && value?.supportedActions.contains("goal") == true
        }
        // Publish after enablement; disabled bootstrap correctly pauses an already active goal.
        try JSONEncoder().encode(goal).write(to: file, options: .atomic)
        var active: NativeThreadSnapshot?
        try await eventuallyAsync("the live controller to publish its active goal") {
            active = try await snapshot()
            return active?.goal?.id == goal.id && active?.goal?.state == .working
        }
        try await eventuallyOnMain("the active goal to keep its idle pi thread in Working") {
            vm.sidebarLists.working.map(\.id) == [.local(agent.agent.id)]
        }
        #expect(active?.running == false)
        #expect(vm.sidebarLists.done.isEmpty && vm.sidebarLists.recents.isEmpty)
        #expect(vm.sidebarLists.working.first?.hasGoal == true)
        let sidebar = OffscreenWindow(size: CGSize(width: 232, height: 650), dark: true, SidebarView(vm: vm))
        defer { sidebar.close() }
        let label = "\(agent.agent.name), running, goal"
        try await eventuallyOnMain("the active goal sidebar row") {
            sidebar.layout()
            return sidebar.controls().contains { $0.label == label }
        }
        try sidebar.press(label)
        #expect(vm.selectedAgentID == agent.agent.id)
        try window.press("Goals", role: #require(toggle()?.role))
        try await eventuallyAsync("off to hide the card and reject controls") {
            let value = try await snapshot()
            return value?.goal == nil && value?.supportedActions.contains("goal") == false
        }
        #expect(!AppSettings(store: app.defaults).goalsEnabled)
        try window.press("Goals", role: #require(toggle()?.role))
        var paused: NativeThreadSnapshot?
        try await eventuallyAsync("re-enable to show the same goal paused") {
            paused = try await snapshot()
            return paused?.goal?.state == .paused
        }
        #expect(paused?.goal?.id == goal.id && paused?.generation == before.generation)
        #expect(AppSettings(store: app.defaults).goalsEnabled)
        #expect((await app.server.listSessions()).filter(\.isAlive).count == 1)
        #expect(paused?.running == false, "turning Goals back on never starts work")
        try await eventuallyOnMain("the paused goal to leave Working") { vm.sidebarLists.working.isEmpty }
    }

    @MainActor
    private static func pressAndLaunch() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        // TerminalSessionStore reads the app's settings. This exit process has scratch defaults.
        let settings = AppSettings.shared
        #expect(!settings.goalCrossProviderEvaluation)
        let label = "Allow cross-provider goal checks"
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 950), dark: true,
                                     AgentSettings(pi: app.server.pi, settings: settings))
        defer { window.close() }
        func toggle() -> AccessibilityNode? {
            window.elements().first { $0.label == label && ($0.role == "AXCheckBox" || $0.role == "AXSwitch") }
        }
        try await eventuallyOnMain("the goal privacy toggle to attach") { toggle() != nil }

        func launch() async throws -> StubPi.Launch {
            let id = try await vm.startAgent(NewAgentConfig(spaceID: space.id, workingDirectory: app.dir.path,
                                                           model: "anthropic/claude-opus-4-5", thinking: .medium, initialPrompt: "hello"),
                                             selectAfter: false)
            let agent = try #require(vm.state.agents.first { $0.id == id })
            let sessionID = agent.effectivePiSessionID
            try await eventuallyOnMain("the stub to record the new agent") { PiHomeLaunchTests.launch(of: sessionID) != nil }
            return try #require(PiHomeLaunchTests.launch(of: sessionID))
        }

        let defaultLaunch = try await launch()
        #expect(defaultLaunch.env["SHEPHERD_GOAL_MODELS"] == "")
        try window.press(label, role: #require(toggle()?.role))
        try await eventuallyOnMain("cross-provider consent to be granted") { settings.goalCrossProviderEvaluation }
        let optedIn = try await launch()
        #expect(optedIn.env["SHEPHERD_GOAL_MODELS"]
                == "anthropic/claude-haiku-4-5,openai/gpt-5.1-codex-mini,google/gemini-2.5-flash")
        try window.press(label, role: #require(toggle()?.role))
        try await eventuallyOnMain("cross-provider consent to be withdrawn") { !settings.goalCrossProviderEvaluation }
        let optedOut = try await launch()
        #expect(optedOut.env["SHEPHERD_GOAL_MODELS"] == "")
        #expect(HostSettingsMapping.settings(from: settings, shepherdVersion: nil, piVersion: nil).goalCrossProviderEvaluation == false)
        #expect(!AppSettings().goalCrossProviderEvaluation, "the opt-out persists")
        let live = await app.server.listSessions().filter(\.isAlive)
        #expect(live.count == 3, "changing policy neither kills nor restarts running agents")
    }
}
