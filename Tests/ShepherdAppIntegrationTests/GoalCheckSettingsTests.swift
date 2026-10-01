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
        try #require(toggle()?.press() == true, "the native Toggle takes VoiceOver's press")
        try await eventuallyOnMain("cross-provider consent to be granted") { settings.goalCrossProviderEvaluation }
        let optedIn = try await launch()
        #expect(optedIn.env["SHEPHERD_GOAL_MODELS"]
                == "anthropic/claude-haiku-4-5,openai/gpt-5.1-codex-mini,google/gemini-2.5-flash")
        try #require(toggle()?.press() == true)
        try await eventuallyOnMain("cross-provider consent to be withdrawn") { !settings.goalCrossProviderEvaluation }
        let optedOut = try await launch()
        #expect(optedOut.env["SHEPHERD_GOAL_MODELS"] == "")
        #expect(HostSettingsMapping.settings(from: settings, shepherdVersion: nil, piVersion: nil).goalCrossProviderEvaluation == false)
        #expect(!AppSettings().goalCrossProviderEvaluation, "the opt-out persists")
        let live = await app.server.listSessions().filter(\.isAlive)
        #expect(live.count == 3, "changing policy neither kills nor restarts running agents")
    }
}
