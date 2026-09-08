import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// The server owns PTYs but not layouts, so pane requests are forwarded to the
/// GUI and only the request id is correlated here. These cover that routing:
/// the request arrives intact, the answer comes back on the same connection
/// carrying the same id, and a workspace that cannot serve the request still
/// answers rather than leaving the agent hanging.
@Suite("Pane control routing", .serialized)
struct PaneControlTests {
    private struct Harness {
        let dir: URL
        let socketPath: String
        let server: SessionServer

        init() throws {
            dir = try makeScratchDirectory()
            socketPath = dir.appendingPathComponent("d.sock").path
            server = SessionServer(
                socketPath: socketPath,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func routesRequestsToTheHandlerAndRepliesWithTheSameID() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let agentID = AgentID()
        let paneID = PaneID()
        let seen = Locked<[PaneRequest]>([])
        h.server.onPaneRequest = { request, respond in
            seen.withValue { $0.append(request) }
            switch request {
            case .list:
                respond(.panes([
                    PaneInfo(id: paneID, cwd: "/tmp", isAgentPane: true, isFocused: true, isAlive: true)
                ]))
            case .read:
                respond(.content(paneID: paneID, lines: ["listening on :3000"]))
            default:
                respond(.ok)
            }
        }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }

        try client.send(.listPanes(id: 41, agentID: agentID))
        let listed = try client.readReply()
        guard case .panes(let id, let panes) = listed else {
            Issue.record("expected panes reply, got \(listed)")
            return
        }
        #expect(id == 41)
        #expect(panes.count == 1)
        #expect(panes.first?.isAgentPane == true)

        try client.send(.readPane(id: 42, agentID: agentID, paneID: paneID))
        let content = try client.readReply()
        #expect(content == .paneContent(id: 42, paneID: paneID, lines: ["listening on :3000"]))

        // The handler must receive the request faithfully, including its
        // optional fields.
        try client.send(.openPane(
            id: 43, agentID: agentID, axis: .horizontal, cwd: "/tmp/work", relativeTo: paneID, command: "npm test"
        ))
        #expect(try client.readReply() == .ok(id: 43))

        try await waitUntil { seen.current.count == 3 }
        guard case .open(let openAgent, let axis, let cwd, let relativeTo, let command) = seen.current[2] else {
            Issue.record("expected an open request, got \(seen.current[2])")
            return
        }
        #expect(openAgent == agentID)
        #expect(axis == .horizontal)
        #expect(cwd == "/tmp/work")
        #expect(relativeTo == paneID)
        #expect(command == "npm test")
    }

    /// A handler failure must reach the agent as an error reply, not silence.
    @Test func handlerFailuresBecomeErrorReplies() throws {
        let h = try Harness()
        defer { h.tearDown() }

        h.server.onPaneRequest = { _, respond in
            respond(.failed(code: "not_closable", message: "an agent cannot close its own pi pane"))
        }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }

        try client.send(.closePane(id: 7, agentID: AgentID(), paneID: PaneID()))
        #expect(try client.readReply() == .error(
            id: 7, code: "not_closable", message: "an agent cannot close its own pi pane"
        ))
    }

    /// With no workspace attached (headless server), pane requests are still
    /// answered so the extension's request cannot hang until its timeout.
    @Test func repliesEvenWithNoHandlerInstalled() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }

        try client.send(.listPanes(id: 9, agentID: AgentID()))
        let reply = try client.readReply()
        guard case .error(let id, let code, _) = reply else {
            Issue.record("expected an error reply, got \(reply)")
            return
        }
        #expect(id == 9)
        #expect(code == "unsupported")
    }

    @Test func routesReviewRequestsAndReturnsTheSubmittedText() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let agentID = AgentID()
        let received = Locked<[ReviewRequest]>([])
        h.server.onReviewRequest = { request, respond in
            received.withValue { $0.append(request) }
            respond(.submitted(text: "Summary: ready to merge."))
        }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }
        try client.send(.requestReview(id: 51, agentID: agentID, cwd: "/tmp/repo", reference: "HEAD~2"))
        #expect(try client.readReply() == .reviewResult(id: 51, text: "Summary: ready to merge."))

        try await waitUntil { received.current.count == 1 }
        guard case .start(let requestAgent, let cwd, let reference) = received.current.first else {
            Issue.record("expected a review request")
            return
        }
        #expect(requestAgent == agentID)
        #expect(cwd == "/tmp/repo")
        #expect(reference == "HEAD~2")
    }

    @Test func reviewRequestsWithoutAHandlerReturnAnError() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }
        try client.send(.requestReview(id: 52, agentID: AgentID(), cwd: nil, reference: nil))
        #expect(try client.readReply() == .error(id: 52, code: "unsupported", message: "no review handler"))
    }

    @Test func oversizedReplyFallsBackToCorrelatedError() throws {
        let h = try Harness()
        defer { h.tearDown() }

        h.server.onPaneRequest = { _, respond in
            respond(.content(
                paneID: PaneID(),
                lines: [String(repeating: "x", count: NDJSON.maxPayloadBytes)]
            ))
        }

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }
        try client.send(.readPane(id: 17, agentID: AgentID(), paneID: PaneID()))
        #expect(try client.readReply() == .error(
            id: 17,
            code: "reply_too_large",
            message: "reply exceeds the maximum payload size"
        ))
    }

    @Test func nearLimitReplySurvivesSmallReceiveBuffer() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let paneID = PaneID()
        let line = String(repeating: "x", count: NDJSON.maxPayloadBytes - 256 * 1_024)
        h.server.onPaneRequest = { _, respond in
            respond(.content(paneID: paneID, lines: [line]))
        }

        let client = try ExtensionClient(path: h.socketPath, receiveBufferSize: 16 * 1_024)
        defer { client.closeConnection() }
        try client.send(.readPane(id: 18, agentID: AgentID(), paneID: paneID))
        let reply = try client.readReply(timeout: .seconds(30))
        guard case .paneContent(let id, let returnedPaneID, let lines) = reply else {
            Issue.record("expected pane content reply, got \(reply)")
            return
        }
        #expect(id == 18)
        #expect(returnedPaneID == paneID)
        #expect(lines == [line])
    }
}
