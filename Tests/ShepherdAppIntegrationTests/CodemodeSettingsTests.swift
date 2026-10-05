import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Codemode settings launch", .mainActorExclusive)
@MainActor
struct CodemodeSettingsTests {
    @Test func pressingCodemodeChangesFutureLaunchesWithoutRestartingLiveAgents() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressAndLaunch() }
        }
    }

    private static func pressAndLaunch() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let settings = AppSettings.shared
        #expect(settings.codemode)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 1400), dark: true,
                                     AgentSettings(pi: app.server.pi, settings: settings))
        defer { window.close() }
        for expected in [true, false, true] {
            if settings.codemode != expected {
                let control = try window.press("Codemode", role: ControlRole.checkBox)
                #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty)
            }
            let id = try await vm.startAgent(NewAgentConfig(spaceID: space.id, workingDirectory: app.dir.path,
                                                           model: "anthropic/claude-opus-4-5", thinking: .medium, initialPrompt: "hello"), selectAfter: false)
            let agent = try #require(vm.state.agents.first { $0.id == id })
            try await eventuallyOnMain("the new agent launch") { PiHomeLaunchTests.launch(of: agent.effectivePiSessionID) != nil }
            let data = try Data(contentsOf: app.server.pi.files.settings)
            let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(PiCodemode.projectOverride(in: saved) == expected)
            #expect((saved["extensions"] as? [String])?.contains("-builtin:codemode") == true)
            #expect(AppSettings().codemode == expected)
        }
        let live = await app.server.listSessions().filter(\.isAlive)
        #expect(live.count == 3, "a toggle does not kill or restart an existing agent")
    }
}
