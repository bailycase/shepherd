import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What a background host's agent asks of Shepherd's window (`relayWindowRequestsToApp`), and what
/// the host does with a turn's error with no app (`serveTurnErrors`). Before, `review_diff` answered
/// "no review handler" and every `project_*` tool "Project control unavailable."
@Suite("The host's window requests", .mainActorExclusive)
@MainActor
struct HostWindowRelayTests {
    private struct Host {
        let scratch: ScratchServer
        let socket: String
        let token: String
        let agent: AgentFixture
    }

    private func host() async throws -> Host {
        _ = NSApplication.shared
        let scratch = try ScratchServer()
        scratch.server.relayWindowRequestsToApp()
        let space = Fixture.space("acme-web", path: scratch.dir.path)
        let agent = Fixture.agent("web", in: space)
        try await scratch.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let socket = scratch.dir.appendingPathComponent("h.sock").path
        let tokenURL = scratch.dir.appendingPathComponent("remote-token")
        try scratch.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Host(scratch: scratch, socket: socket, token: token, agent: agent)
    }

    private func ask(_ client: ExtensionClient, _ message: ExtensionMessage) async throws -> ExtensionReply {
        try client.send(message)
        nonisolated(unsafe) let client = client
        return try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
    }

    @Test func reviewDiffMarksTheAppsChangesTabAndSaysSoWithTheWindowClosed() async throws {
        let h = try await host()
        defer { h.scratch.stop() }
        let id = h.agent.agent.id
        let pi = try ExtensionClient(path: h.scratch.socketPath)
        try pi.send(.helloAgent(agentID: id))

        guard case .reviewResult(1, let closed) = try await ask(pi, .requestReview(id: 1, agentID: id, cwd: nil, reference: nil)) else {
            Issue.record("review_diff not served with no app"); return
        }
        #expect(closed == SessionServer.reviewWindowClosed)

        let (vm, hosts, _, _, clientDir, _) = try await LocalClientTests.app(socket: h.socket, token: h.token, host: h.scratch)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        guard case .reviewResult(2, let ready) = try await ask(pi, .requestReview(id: 2, agentID: id, cwd: nil, reference: nil)) else {
            Issue.record("review_diff not relayed to the app"); return
        }
        #expect(ready.hasPrefix("Review ready in the side pane's Changes tab"))
        #expect(vm.subagentInspector.news[.local(id)]?.contains(.changes) == true, "the Changes tab wears its dot")
    }

    /// A paired device's Update this Mac reaches the app, where Sparkle runs; with no app the host
    /// says to open Shepherd. The app's update asks the host before it reserves or restarts (A21).
    @Test func aPairedDevicesUpdateGoesToTheAppWhichAsksTheHost() async throws {
        let h = try await host()
        defer { h.scratch.stop() }
        let phone = RemoteHostClient(localSocket: h.socket)
        // A paired iPhone draws no window: it never lists the app relay.
        _ = try await phone.connect(host: "", port: 0, token: h.token, clientName: "iPhone",
                                    capabilities: RemoteProtocol.clientCapabilities.filter { $0 != RemoteProtocol.appRelayCapability })
        defer { phone.disconnect() }
        #expect(phone.capabilities.contains(RemoteProtocol.hostUpdateCapability))
        #expect(try await phone.hostUpdate(.status).error == SessionServer.hostUpdateWindowClosed)

        let (vm, hosts, _, _, clientDir, _) = try await LocalClientTests.app(socket: h.socket, token: h.token, host: h.scratch)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        let relayed = try await phone.hostUpdate(.status)
        #expect(relayed.error != SessionServer.hostUpdateWindowClosed, "answered by the app's updater")
        let own = await AppUpdater.shared.remoteUpdate(.status, authorized: { @Sendable in true })
        #expect(relayed == own)

        // The gate: one reservation at a time, released by the app.
        let gate = HostUpdateGate.host { [weak vm] in (try? vm?.remoteHosts.thisMacHost()) ?? nil }
        #expect(await gate.blockReason() == nil)
        #expect(await gate.reserve())
        #expect(await gate.reserve() == false)
        gate.release()
        var again = false
        for _ in 0..<500 where !again {
            again = await gate.reserve()
            if !again { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(again, "the host released the reservation")
        gate.release()
    }

    @Test func projectToolsChangeTheHostAndRemoveSpaceAsksTheAppsWindow() async throws {
        let h = try await host()
        defer { h.scratch.stop() }
        let id = h.agent.agent.id
        let pi = try ExtensionClient(path: h.scratch.socketPath)
        try pi.send(.helloAgent(agentID: id))
        let folder = h.scratch.dir.appendingPathComponent("acme-api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard case .projectResult(1, let space?, true) = try await ask(pi, .registerProject(id: 1, agentID: id, path: folder.path, name: "acme-api")) else {
            Issue.record("project_register not served"); return
        }
        #expect(h.scratch.server.state.spaces.contains { $0.id == space.id && $0.name == "acme-api" })

        guard case .error(2, let code, let message) = try await ask(pi, .deleteProject(id: 2, agentID: id, projectID: space.id)) else {
            Issue.record("project_delete with no app should refuse"); return
        }
        #expect(code == "unavailable" && message == SessionServer.spaceDeleteWindowClosed)

        let (vm, hosts, _, _, clientDir, _) = try await LocalClientTests.app(socket: h.socket, token: h.token, host: h.scratch)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        guard case .projectResult(3, let asked?, false) = try await ask(pi, .deleteProject(id: 3, agentID: id, projectID: space.id)) else {
            Issue.record("project_delete not relayed to the app"); return
        }
        #expect(asked.id == space.id)
        #expect(vm.spaceDeleteTarget == space.id && vm.spaceDeleteRequested, "the app shows Remove space")
        #expect(h.scratch.server.state.spaces.contains { $0.id == space.id }, "nothing is removed until the user confirms")
    }

    @Test func aFailedRefreshOnTheHostReadsExpiredInSignIn() async throws {
        let h = try await host()
        defer { h.scratch.stop() }
        var fixture = h.agent
        fixture.agent.model = "anthropic/claude-opus-4-5"
        try await h.scratch.server.putState(Fixture.state(spaces: [fixture.space], agents: [fixture]))
        let piAuth = PiAuthStore(pi: h.scratch.server.pi)
        HostStores(mcp: MCPStore(dependencies: .app(pi: h.scratch.server.pi, openURL: { _ in }, copy: { _ in })),
                   subagents: { SubagentDefinitionsModel(pi: h.scratch.server.pi) }, piAuth: piAuth,
                   yourPi: YourPiModel(pi: h.scratch.server.pi), remoteSignIns: RemoteSignIns()).serveTurnErrors(on: h.scratch.server)
        let failure = TurnFailure(message: "Token refresh failed (HTTP 400): {\"error\":\"invalid_grant\"}")
        h.scratch.server.onAgentStatus?(fixture.agent.id, .done, failure)
        #expect(piAuth.expired == ["anthropic"])
        #expect(h.scratch.server.onAgentProviderError != nil, "a limit rotates accounts on the host")
    }
}
