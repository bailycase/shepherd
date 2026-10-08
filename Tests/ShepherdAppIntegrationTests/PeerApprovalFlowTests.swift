import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Peer approval flow", .integrationTimeLimit)
struct PeerApprovalFlowTests {
    @Test func crossThreadMessagesReachTheTargetWithoutAnApprovalSheet() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.messagingWithoutApproval() }
        }
    }

    @Test func settingsHasNoAgentToAgentPermissionsRow() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.checkingSettings() } }
    }

    private final class Connection: @unchecked Sendable {
        let client: ExtensionClient
        init(path: String) throws { client = try ExtensionClient(path: path) }
        func send(_ message: ExtensionMessage) throws { try client.send(message) }
        func close() { client.closeConnection() }
        func reply() async throws -> ExtensionReply {
            try await Task.detached { try self.client.readReply(timeout: .seconds(20)) }.value
        }
    }

    @MainActor
    static func messagingWithoutApproval() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.defaults.set("never", forKey: "shepherd.pi.agentMessages")
        let space = Fixture.space("service", path: app.dir.path)
        let lead = Fixture.agent("lead", in: space, order: 0)
        let worker = Fixture.agent("worker", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [lead, worker]))
        let leadClient = try Connection(path: app.scratch.socketPath)
        let workerClient = try Connection(path: app.scratch.socketPath)
        defer { leadClient.close(); workerClient.close() }
        for (client, agent) in [(leadClient, lead.agent), (workerClient, worker.agent)] {
            try client.send(.helloAgent(agentID: agent.id))
            try client.send(.coordinateAgent(id: 0, agentID: agent.id, targetAgentID: agent.id, request: .init(operation: .status)))
            guard case .error(0, "self_control", _) = try await client.reply() else { Issue.record("registration barrier failed"); return }
        }
        let window = OffscreenWindow(size: CGSize(width: 900, height: 640), dark: true,
                                     Color.nw.bgWindow.modifier(AppDialogs(vm: vm)))
        defer { window.close() }
        for id in 1...2 {
            try leadClient.send(.sendToAgent(id: id, agentID: lead.agent.id, targetAgentID: worker.agent.id, text: "run the tests"))
            #expect(try await leadClient.reply() == .ok(id: id))
            #expect(try await workerClient.reply() == .message(id: 0, text: AgentMessageFraming.framed(from: "lead", "run the tests"), delivery: .task))
            window.layout()
            #expect(window.controls().allSatisfy { !["Deny", "Allow once", "Allow for this thread"].contains($0.label ?? "") })
        }
    }

    /// The real Extensions page has no peer permission row.
    @MainActor
    static func checkingSettings() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let window = OffscreenWindow(size: CGSize(width: 900, height: 1400), dark: true,
                                     ScrollView { ExtensionsSettings(settings: app.settings).padding(32) }
                                         .background(Color.nw.bgWindow))
        defer { window.close() }
        window.layout()
        let labels = window.controls().compactMap(\.label)
        #expect(labels.contains("Terminals and agent tools") && labels.contains("Diff review tool"))
        #expect(!labels.contains("Agent-to-agent messages") && !labels.contains("Allow interactive threads"))
        #expect(!SettingsSection.extensions.items.contains("Agent-to-agent messages"))
    }

}
