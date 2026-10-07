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

/// An agent's call on another thread under Settings ▸ Pi ▸ Agent-to-agent messages = Ask me, end
/// to end: the call arrives on the real extension socket, the app opens `PeerApprovalDialog`
/// from what the server asks, and each button is pressed the way VoiceOver presses
/// (`ControlPress`). What each press did is read where it lands: the asking agent's reply and what
/// the target's own connection is handed. SwiftUI draws the accessibility tree only for a process
/// an assistive client is attached to, so each scenario runs in a process of its own.
@Suite("Peer approval flow", .integrationTimeLimit)
struct PeerApprovalFlowTests {
    @Test func allowOnceDoesTheCallOnceAndTheNextOneAsksAgain() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.allowingOnce() } }
    }

    @Test func allowForThisThreadDoesTheCallAndTheNextOnesWithoutAsking() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.allowingForTheThread() } }
    }

    @Test func denyAnswersTheAgentAndTheTargetIsHandedNothing() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.denying() } }
    }

    @Test func noAnswerDeniesAndTheDialogGoesAway() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.timingOut() } }
    }

    @Test func callsQueueOneDialogAtATimeAndEachButtonAnswersItsOwnCall() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.queueing() } }
    }

    @Test func everyKindOfCallDrawsTheSameThreeControlsAtAHittableSize() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.drawingEveryKind() } }
    }

    @Test func theChoiceInSettingsIsAPopupThatDimsWhenAgentToolsAreOff() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.pressingTheSettingsRow() } }
    }

    // MARK: - The scene

    /// A server and view model with a lead and a worker, each on its own panes connection, and the
    /// dialog drawn from the view model's queue in a window that never leaves the off-screen position.
    @MainActor
    final class Scene {
        let app: AppHarness
        let vm: ShepherdViewModel
        let lead: AgentFixture
        let worker: AgentFixture
        let leadClient: Connection
        let workerClient: Connection
        let window: OffscreenWindow

        init() async throws {
            AccessibilityNode.enable()
            app = try AppHarness()
            let space = Fixture.space("billing-service", path: app.dir.path)
            lead = Fixture.agent("Coordinate the release", in: space, order: 0)
            worker = Fixture.agent("Flaky integration tests", in: space, order: 1)
            vm = try await app.start(with: Fixture.state(spaces: [space], agents: [lead, worker]))
            leadClient = try Connection(path: app.scratch.socketPath)
            workerClient = try Connection(path: app.scratch.socketPath)
            // A self-directed status request is always refused: the barrier that proves a registration landed.
            for (client, agent) in [(leadClient, lead.agent), (workerClient, worker.agent)] {
                try client.send(.helloAgent(agentID: agent.id))
                try client.send(.coordinateAgent(id: 0, agentID: agent.id, targetAgentID: agent.id, request: .init(operation: .status)))
                let barrier = try await client.reply()
                guard case .error(0, "self_control", _) = barrier else { throw BarrierFailure(reply: barrier) }
            }
            window = OffscreenWindow(size: CGSize(width: NWDialogMetrics.width, height: 640), dark: true,
                                     ApprovalHost(vm: vm).background(Color.nw.bgWindow))
        }

        func stop() {
            window.close()
            leadClient.close()
            workerClient.close()
            app.stop()
        }

        func send(_ message: ExtensionMessage) throws { try leadClient.send(message) }

        func message(_ text: String, id: Int) -> ExtensionMessage {
            .sendToAgent(id: id, agentID: lead.agent.id, targetAgentID: worker.agent.id, text: text)
        }

        /// Waits for the dialog of the call at the head of the queue to be drawn.
        func awaitDialog(for text: String? = nil) async throws {
            try await eventuallyOnMain("the dialog to open") {
                guard let shown = vm.peerApprovalItem else { return false }
                if let text, case .send(_, let sent, _) = shown.action { return sent == text }
                return true
            }
            window.layout()
        }

        /// The first thing the worker's connection is handed after a probe: what a call that was
        /// refused never produced, since the server hands calls over in order.
        func workerIsHandedNothingBeforeTheProbe() async throws {
            #expect(app.server.pushMessage(toAgent: worker.agent.id, text: "probe"))
            #expect(try await workerClient.reply() == .message(id: 0, text: "probe", delivery: .task))
        }
    }

    /// An agent's panes connection. Its reads block, so they run off the main actor, which answers the server.
    final class Connection: @unchecked Sendable {
        private let client: ExtensionClient

        init(path: String) throws { client = try ExtensionClient(path: path) }

        func send(_ message: ExtensionMessage) throws { try client.send(message) }

        func reply(timeout: Duration = .seconds(20)) async throws -> ExtensionReply {
            try await Task.detached { try self.client.readReply(timeout: timeout) }.value
        }

        func close() { client.closeConnection() }
    }

    /// A registration barrier that was answered with something other than its refusal.
    struct BarrierFailure: Error, CustomStringConvertible {
        let reply: ExtensionReply
        var description: String { "the registration barrier was answered \(reply)" }
    }

    /// The dialog for the call at the head of the queue, as `AppDialogs` presents it.
    struct ApprovalHost: View {
        let vm: ShepherdViewModel

        var body: some View {
            if let prompt = vm.peerApprovalItem {
                PeerApprovalDialog(presentation: vm.peerApprovalPresentation(prompt)) { vm.answerPeerApproval(prompt.requestID, $0) }
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Scenarios

    @MainActor
    static func allowingOnce() async throws {
        let s = try await Scene()
        defer { s.stop() }
        try s.send(s.message("Rerun the flaky test with -count=20.", id: 1))
        try await s.awaitDialog()

        let pressed = try s.window.press("Allow once")

        #expect(pressed.label == "Allow once" && pressed.isEnabled)
        #expect(try await s.leadClient.reply() == .ok(id: 1))
        #expect(try await s.workerClient.reply()
                == .message(id: 0, text: AgentMessageFraming.framed(from: "Coordinate the release", "Rerun the flaky test with -count=20."), delivery: .task))
        #expect(s.vm.peerApprovals.isEmpty && s.window.controls().isEmpty, "the dialog is gone")

        try s.send(s.message("And again.", id: 2))
        try await s.awaitDialog(for: "And again.")
        #expect(s.vm.peerApprovals.count == 1, "a second call asks again")
        try s.window.press("Deny")
        _ = try await s.leadClient.reply()
    }

    @MainActor
    static func allowingForTheThread() async throws {
        let s = try await Scene()
        defer { s.stop() }
        try s.send(s.message("First.", id: 1))
        try await s.awaitDialog()

        try s.window.press("Allow for this thread")

        #expect(try await s.leadClient.reply() == .ok(id: 1))
        _ = try await s.workerClient.reply()
        try s.send(s.message("Second.", id: 2))
        #expect(try await s.leadClient.reply() == .ok(id: 2), "no dialog: the answer came without one")
        #expect(s.vm.peerApprovals.isEmpty)
        guard case .message(0, let text, _) = try await s.workerClient.reply() else { Issue.record("not delivered"); return }
        #expect(text.hasSuffix("] Second."))
    }

    @MainActor
    static func denying() async throws {
        let s = try await Scene()
        defer { s.stop() }
        try s.send(s.message("Please start the migration.", id: 1))
        try await s.awaitDialog()

        let pressed = try s.window.press("Deny")

        #expect(pressed.label == "Deny" && pressed.isEnabled)
        #expect(try await s.leadClient.reply() == .error(id: 1, code: "not_approved", message: AgentMessageGate.deniedMessage))
        try await s.workerIsHandedNothingBeforeTheProbe()
        #expect(s.vm.peerApprovals.isEmpty && s.window.controls().isEmpty)
    }

    @MainActor
    static func timingOut() async throws {
        let s = try await Scene()
        defer { s.stop() }
        s.app.server.setAgentApprovalTimeout(0.3)
        try s.send(s.message("Anyone there?", id: 1))
        try await s.awaitDialog()
        #expect(s.window.controls().contains { $0.label == "Allow once" })

        #expect(try await s.leadClient.reply() == .error(id: 1, code: "not_approved", message: AgentMessageGate.timedOutMessage))

        try await eventuallyOnMain("the dialog to close") { s.vm.peerApprovals.isEmpty && s.window.controls().isEmpty }
        try await s.workerIsHandedNothingBeforeTheProbe()
    }

    @MainActor
    static func queueing() async throws {
        let s = try await Scene()
        defer { s.stop() }
        try s.send(s.message("First call.", id: 1))
        try s.send(.coordinateAgent(id: 2, agentID: s.lead.agent.id, targetAgentID: s.worker.agent.id, request: .init(operation: .interrupt)))
        try await eventuallyOnMain("both calls to wait") { s.vm.peerApprovals.count == 2 }
        s.window.layout()

        let first = try #require(s.vm.peerApprovalItem)
        #expect(s.vm.peerApprovalPresentation(first).status == "1 more waiting")
        #expect(s.vm.peerApprovalPresentation(first).title == "Message another thread")
        try s.window.press("Allow once")
        #expect(try await s.leadClient.reply() == .ok(id: 1))

        try await eventuallyOnMain("the second call's dialog") { s.vm.peerApprovalItem?.action == .interrupt(targetAgentID: s.worker.agent.id) }
        let second = try #require(s.vm.peerApprovalItem)
        #expect(s.vm.peerApprovalPresentation(second).title == "Interrupt another thread" && s.vm.peerApprovalPresentation(second).status == nil)
        try s.window.press("Deny")
        #expect(try await s.leadClient.reply()
                == .agentResult(id: 2, result: .init(text: AgentMessageGate.deniedMessage, code: "not_approved")))
        #expect(s.vm.peerApprovals.isEmpty)
        // The first was done, and the interrupt that was denied never reached the worker.
        guard case .message(0, _, _) = try await s.workerClient.reply() else { Issue.record("the first call was not delivered"); return }
        try await s.workerIsHandedNothingBeforeTheProbe()
    }

    /// Every kind of call, from the extension's own message to the dialog it opens: the same three
    /// buttons, enabled, at least as big as a pointer needs, and Deny answers each.
    @MainActor
    static func drawingEveryKind() async throws {
        let s = try await Scene()
        defer { s.stop() }
        let lead = s.lead.agent.id, worker = s.worker.agent.id
        let calls: [(ExtensionMessage, String)] = [
            (.sendToAgent(id: 1, agentID: lead, targetAgentID: worker, text: "hi"), "Message another thread"),
            (.sendToAgent(id: 2, agentID: lead, targetAgentID: worker, text: "fyi", delivery: .report), "Message another thread"),
            (.coordinateAgent(id: 3, agentID: lead, targetAgentID: worker, request: .init(operation: .steer, text: "use the new API")), "Steer another thread"),
            (.coordinateAgent(id: 4, agentID: lead, targetAgentID: worker, request: .init(operation: .interrupt)), "Interrupt another thread"),
            (.coordinateAgent(id: 5, agentID: lead, targetAgentID: worker, request: .init(operation: .read)), "Read another thread"),
            (.spawnAgent(id: 6, agentID: lead, cwd: s.app.dir.path, prompt: "fix the build"), "Start a new thread"),
        ]
        for (message, title) in calls {
            try s.send(message)
            try await eventuallyOnMain("the dialog for \(title)") { s.vm.peerApprovalItem.map { s.vm.peerApprovalPresentation($0).title } == title }
            s.window.layout()

            let controls = s.window.controls()
            #expect(controls.compactMap(\.label).sorted() == ["Allow for this thread", "Allow once", "Deny"], "\(title): \(controls)")
            #expect(controls.allSatisfy { $0.role == ControlRole.button && $0.isEnabled }, "\(title): \(controls)")
            #expect(ControlPress.undersized(controls, minimum: .desktop).isEmpty, "\(title): \(ControlPress.undersized(controls, minimum: .desktop))")

            try s.window.press("Deny")
            _ = try await s.leadClient.reply()
        }
        #expect(s.vm.peerApprovals.isEmpty)
    }

    /// Settings ▸ Extensions' row: a popup that says its value, which a switch for the agent tools turns off and on.
    @MainActor
    static func pressingTheSettingsRow() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let settings = app.settings
        let window = OffscreenWindow(size: CGSize(width: 900, height: 1400), dark: true,
                                     ScrollView { ExtensionsSettings(settings: settings).padding(32) }
                                         .background(Color.nw.bgWindow))
        defer { window.close() }
        window.layout()

        // The row's popup is the first menu button after the agent tools' switch: a popup in Settings has
        // no accessibility label in this tree (every one of them), so it is found by its place. Its menu
        // is not pressed: AppKit tracks a menu in a modal loop, which a test must not start.
        func popup() throws -> Control {
            let controls = window.controls()
            let anchor = try #require(controls.firstIndex { $0.label == "Terminals and agent tools" }, "\(controls)")
            return try #require(controls[(anchor + 1)...].first { $0.role == ControlRole.menuButton }, "\(controls)")
        }
        let before = try popup()
        let rows = window.controls().filter { $0.role == ControlRole.checkBox }.compactMap(\.label)
        #expect(rows.contains("Terminals and agent tools") && rows.contains("Diff review tool"), "the row sits between the switches")
        #expect(before.isEnabled, "\(before)")

        settings.piPanesExtension = false
        window.layout()
        #expect(try !popup().isEnabled, "no agent has the tools, so there is nothing to choose")
        settings.piPanesExtension = true
        window.layout()
        #expect(try popup().isEnabled)
    }
}
