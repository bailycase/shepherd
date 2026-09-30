import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// An agent's pi started the way the app starts it (a login shell that `exec`s the launcher, which
/// `exec`s the engine, here the stub) is the process its extension connections come from, so the
/// server's real check (`SessionServer.extensionPeerCheck` left `nil`) serves it for its own agent
/// and refuses everything else, against the app's own handlers. The rule and its other cases are
/// `ExtensionIdentityTests`.
@Suite("Extension identity, app launch", .mainActorExclusive)
@MainActor
struct ExtensionIdentityFlowTests {
    /// What the stub wrote for the requests it sent as one agent: the raw reply lines.
    private struct Spoken: Decodable {
        struct Cell: Decodable {
            var listPanes: String
            var listAgents: String
            var coordinateAgent: String

            var refusedAll: Bool { [listPanes, listAgents, coordinateAgent].allSatisfy { Self.reply($0).map(Self.isRefusal) == true } }
            /// The app's own handlers answered: its panes, its agents, and "no such agent" for a
            /// target it does not have.
            var servedAll: Bool {
                guard case .panes? = Self.reply(listPanes), case .agents? = Self.reply(listAgents),
                      case .error(_, "no_such_agent", _)? = Self.reply(coordinateAgent) else { return false }
                return true
            }

            private static func reply(_ line: String) -> ExtensionReply? {
                try? NDJSON.decode(ExtensionReply.self, from: Data(line.trimmingCharacters(in: .newlines).utf8))
            }

            private static func isRefusal(_ reply: ExtensionReply) -> Bool {
                if case .error(_, "wrong_process", _) = reply { true } else { false }
            }
        }

        var own: [String: Cell]
    }

    @Test func anAgentStartedTheWayTheAppStartsItSpeaksForItselfAndNoOtherProcessDoes() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        app.scratch.useRealPeerCheck()
        let space = Fixture.space(path: app.dir.path)
        let other = AgentID()
        let config: [String: Any] = ["speak": ["label": "app", "other": other.rawValue, "gate": "speak-gate", "socket": app.scratch.socketPath]]
        try JSONSerialization.data(withJSONObject: config).write(to: app.dir.appendingPathComponent("stub-pi-startup.json"))
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let id = try await vm.startAgent(ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults), selectAfter: false)
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("speak-gate").path, contents: nil)
        let file = app.dir.appendingPathComponent("speak-app.json")
        try await eventuallyOnMain("the pi to speak") { FileManager.default.fileExists(atPath: file.path) }
        let spoken = try JSONDecoder().decode(Spoken.self, from: Data(contentsOf: file))
        #expect(spoken.own["self"]?.servedAll == true, "the pi the app started, as the agent it was started for")
        #expect(spoken.own["other"]?.refusedAll == true, "and as an agent it was not")

        let client = try ExtensionClient(path: app.scratch.socketPath)
        try client.send(.listPanes(id: 1, agentID: id))
        // A refusal is answered on the server's own queue, so blocking the main actor for it is safe.
        guard case .error(1, "wrong_process", _) = try client.readReply() else { Issue.record("this process was served"); return }
    }
}
