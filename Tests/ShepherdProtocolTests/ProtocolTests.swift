import Testing
import Foundation
import ShepherdCore
@testable import ShepherdProtocol

@Suite("Wire protocol")
struct ProtocolTests {
    /// The status extension's wire shape is frozen — the app must decode what
    /// `Extensions/shepherd-status.ts` sends, byte for byte. The extension uses
    /// `JSON.stringify` (insertion order: type, agentID, status); the decoder
    /// must not care about key order.
    @Test func extensionMessageDecodesCanonicalExtensionOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(#"{"type":"setAgentStatus","agentID":"a1b2c3","status":"working"}"#.utf8)
        let decoded = try NDJSON.decode(ExtensionMessage.self, from: wire)
        #expect(decoded == .setAgentStatus(agentID: agentID, status: .working))
    }

    @Test func extensionMessageEncodesWithSortedKeys() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let message = ExtensionMessage.setAgentStatus(agentID: agentID, status: .working)
        let data = try NDJSON.encode(message)
        let json = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(json == #"{"agentID":"a1b2c3","status":"working","type":"setAgentStatus"}"#)
    }

    /// Same contract for the namer: the app must decode what
    /// `Extensions/shepherd-namer.ts` sends via `JSON.stringify`.
    @Test func extensionMessageDecodesCanonicalNamerOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(#"{"type":"setAgentName","agentID":"a1b2c3","name":"Fix plan mode over SSH"}"#.utf8)
        let decoded = try NDJSON.decode(ExtensionMessage.self, from: wire)
        #expect(decoded == .setAgentName(agentID: agentID, name: "Fix plan mode over SSH"))
    }

    /// The status extension writes this by hand on every session_start.
    @Test func extensionMessageDecodesCanonicalSessionOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(#"{"type":"setAgentSession","agentID":"a1b2c3","piSessionID":"sess-9"}"#.utf8)
        let decoded = try NDJSON.decode(ExtensionMessage.self, from: wire)
        #expect(decoded == .setAgentSession(agentID: agentID, piSessionID: "sess-9"))
    }

    @Test func extensionMessageRoundTrips() throws {
        let messages: [ExtensionMessage] = [
            .setAgentStatus(agentID: AgentID(), status: .idle),
            .setAgentStatus(agentID: AgentID(), status: .working),
            .setAgentStatus(agentID: AgentID(), status: .blocked),
            .setAgentStatus(agentID: AgentID(), status: .done),
            .setAgentName(agentID: AgentID(), name: "Add worktree cleanup"),
            .setAgentSession(agentID: AgentID(), piSessionID: "01a026dd-ce9a-7ea2-b1bb-195d958cca0c"),
            .setAgentName(agentID: AgentID(), name: "Title with \"quotes\" and ünicode"),
            .notify(agentID: AgentID(), title: "CI passed", body: "PR #42 is green"),
            .notify(agentID: AgentID(), title: "Done", body: ""),
            .createAutomation(id: 9, name: "pr-watch", prompt: "watch it", cwd: "/tmp/repo", enabled: true, start: false),
            .listAutomations(id: 10),
            .updateAutomation(id: 11, automationID: AutomationID(), name: "renamed", prompt: nil, cwd: nil, enabled: false),
            .updateAutomation(id: 12, automationID: AutomationID(), name: nil, prompt: nil, cwd: nil, enabled: nil),
            .deleteAutomation(id: 13, automationID: AutomationID()),
            .startAutomation(id: 14, automationID: AutomationID()),
            .stopAutomation(id: 15, automationID: AutomationID()),
            .listAgents(id: 16, agentID: AgentID()),
            .sendToAgent(id: 17, agentID: AgentID(), targetAgentID: AgentID(), text: "CI is green"),
            .spawnAgent(id: 18, agentID: AgentID(), cwd: "/tmp/repo", prompt: "Fix the tests."),
            .helloAgent(agentID: AgentID()),
        ]
        for message in messages {
            let line = try NDJSON.encode(message)
            #expect(line.last == 0x0A)
            let decoded = try NDJSON.decode(ExtensionMessage.self, from: line.dropLast())
            #expect(decoded == message)
        }
    }

    /// The notify tool writes by hand (`JSON.stringify`), so the app must
    /// decode its exact shape — including an omitted body.
    @Test func extensionMessageDecodesCanonicalNotifyOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(#"{"type":"notify","agentID":"a1b2c3","title":"CI passed","body":"PR #42 is green"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: wire)
            == .notify(agentID: agentID, title: "CI passed", body: "PR #42 is green"))

        let noBody = Data(#"{"type":"notify","agentID":"a1b2c3","title":"Done"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: noBody)
            == .notify(agentID: agentID, title: "Done", body: ""))
    }

    @Test func agentPeerRepliesRoundTrip() throws {
        let peer = AgentPeerInfo(id: AgentID(), name: "worker", status: "working", cwd: "/tmp", isSelf: false)
        let own = AgentPeerInfo(id: AgentID(), name: "me", status: "idle", cwd: "/tmp", isSelf: true)
        for reply in [ExtensionReply.agents(id: 1, agents: [peer, own]), .agents(id: 2, agents: [])] {
            let line = try NDJSON.encode(reply)
            #expect(try NDJSON.decode(ExtensionReply.self, from: line.dropLast()) == reply)
        }

        // The extension writes this by hand.
        let wire = Data(#"{"type":"sendToAgent","id":3,"agentID":"a1","targetAgentID":"a2","text":"done"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: wire)
            == .sendToAgent(id: 3, agentID: AgentID(rawValue: "a1"), targetAgentID: AgentID(rawValue: "a2"), text: "done"))

        // Registration + pushed message frames (both hand-read by the
        // extension, so the exact shapes are contract).
        let hello = Data(#"{"type":"helloAgent","agentID":"a1"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: hello)
            == .helloAgent(agentID: AgentID(rawValue: "a1")))
        let push = ExtensionReply.message(id: 0, text: "[from: worker] done")
        let line = try NDJSON.encode(push)
        #expect(try NDJSON.decode(ExtensionReply.self, from: line.dropLast()) == push)
    }

    @Test func automationRepliesRoundTrip() throws {
        let info = AutomationInfo(
            id: AutomationID(), name: "pr-watch", prompt: "watch", cwd: "/tmp/repo",
            enabled: true, agentStatus: "working"
        )
        let stopped = AutomationInfo(
            id: AutomationID(), name: "nightly", prompt: "check", cwd: "/tmp",
            enabled: false, agentStatus: nil
        )
        for reply in [ExtensionReply.automations(id: 1, automations: [info, stopped]),
                      .automations(id: 2, automations: [])] {
            let line = try NDJSON.encode(reply)
            #expect(try NDJSON.decode(ExtensionReply.self, from: line.dropLast()) == reply)
        }

        // The extension reads this JSON by hand — update tools omit nils.
        let wire = Data(#"{"type":"updateAutomation","id":3,"automationID":"au1","enabled":false}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: wire)
            == .updateAutomation(id: 3, automationID: AutomationID(rawValue: "au1"), name: nil, prompt: nil, cwd: nil, enabled: false))
    }

    /// The automation skill writes this JSON by hand from any pi session, so
    /// the app must decode its exact shape — optionals omitted default on.
    @Test func extensionMessageDecodesCanonicalAutomationOutput() throws {
        let wire = Data(#"{"type":"createAutomation","id":1,"name":"pr-watch #4821","prompt":"Watch the PR.","cwd":"/tmp/repo"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: wire)
            == .createAutomation(id: 1, name: "pr-watch #4821", prompt: "Watch the PR.", cwd: "/tmp/repo", enabled: true, start: true))
    }

    /// Same contract for the subagents bridge: the app must decode what
    /// `Extensions/shepherd-subagents.ts` sends via `JSON.stringify`,
    /// including rows with every optional omitted.
    @Test func extensionMessageDecodesCanonicalChildrenOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(
            #"{"type":"setAgentChildren","agentID":"a1b2c3","children":[{"runID":"run-1","childIndex":0,"label":"src/workers","state":"running","startedAt":1724464000000,"currentTool":"bash","needsAttention":true,"attentionText":"update the two burst assertions?","asyncDir":"/tmp/async/run-1"},{"runID":"run-2","label":"scout","state":"complete","needsAttention":false}]}"#
                .utf8
        )
        let decoded = try NDJSON.decode(ExtensionMessage.self, from: wire)
        guard case .setAgentChildren(let decodedAgent, let children) = decoded else {
            Issue.record("expected setAgentChildren, got \(decoded)")
            return
        }
        #expect(decodedAgent == agentID)
        #expect(children.count == 2)
        #expect(children[0].runID == "run-1")
        #expect(children[0].childIndex == 0)
        #expect(children[0].label == "src/workers")
        #expect(children[0].needsAttention)
        #expect(!children[0].isTerminal)
        #expect(children[1].childIndex == nil)
        #expect(children[1].isTerminal)
    }

    @Test func childrenMessagesRoundTrip() throws {
        let messages: [ExtensionMessage] = [
            .setAgentChildren(agentID: AgentID(), children: []),
            .setAgentChildren(agentID: AgentID(), children: [
                ChildRun(runID: "r1", childIndex: 2, label: "src/jobs", state: "failed",
                         startedAt: 1, endedAt: 2, currentTool: "read",
                         needsAttention: true, attentionText: "boom", asyncDir: "/tmp/a"),
                ChildRun(runID: "r2", label: "reviewer", state: "queued"),
            ]),
        ]
        for message in messages {
            let line = try NDJSON.encode(message)
            #expect(try NDJSON.decode(ExtensionMessage.self, from: line.dropLast()) == message)
        }
    }

    /// Pane control is request/reply, so both directions must survive the
    /// wire: the extension's requests and the app's answers.
    @Test func paneMessagesRoundTrip() throws {
        let agentID = AgentID()
        let paneID = PaneID()
        let messages: [ExtensionMessage] = [
            .listPanes(id: 1, agentID: agentID),
            .openPane(id: 2, agentID: agentID, axis: .horizontal, cwd: "/tmp", relativeTo: paneID, command: "npm run dev"),
            .openPane(id: 3, agentID: agentID, axis: .vertical, cwd: nil, relativeTo: nil, command: nil),
            .closePane(id: 4, agentID: agentID, paneID: paneID),
            .focusPane(id: 5, agentID: agentID, paneID: paneID),
            .sendPaneInput(id: 6, agentID: agentID, paneID: paneID, text: "echo hi", submit: true),
            .sendPaneInput(id: 7, agentID: agentID, paneID: paneID, text: "y", submit: false),
            .readPane(id: 8, agentID: agentID, paneID: paneID),
            .requestReview(id: 9, agentID: agentID, cwd: "/tmp/repo", reference: "master..HEAD"),
            .requestReview(id: 10, agentID: agentID, cwd: nil, reference: nil),
        ]
        for message in messages {
            let line = try NDJSON.encode(message)
            #expect(try NDJSON.decode(ExtensionMessage.self, from: line.dropLast()) == message)
        }
    }

    @Test func paneRepliesRoundTrip() throws {
        let paneID = PaneID()
        let pane = PaneInfo(id: paneID, cwd: "/tmp", isAgentPane: false, isFocused: true, isAlive: true)
        let replies: [ExtensionReply] = [
            .ok(id: 1),
            .error(id: 2, code: "no_such_pane", message: "pane is not in this agent's layout"),
            .panes(id: 3, panes: [pane]),
            .paneOpened(id: 4, pane: pane),
            .paneContent(id: 5, paneID: paneID, lines: ["$ npm run dev", "listening on :3000"]),
            .paneContent(id: 6, paneID: paneID, lines: []),
            .reviewResult(id: 7, text: "Looks good.\n\nSummary: ready to merge."),
        ]
        for reply in replies {
            let line = try NDJSON.encode(reply)
            #expect(try NDJSON.decode(ExtensionReply.self, from: line.dropLast()) == reply)
        }
    }

    /// The extension writes these by hand, so the app must decode the exact
    /// shape `Extensions/shepherd-panes.ts` sends — including omitted optionals.
    @Test func paneRequestDecodesCanonicalExtensionOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(#"{"type":"openPane","id":7,"agentID":"a1b2c3","axis":"vertical"}"#.utf8)
        let decoded = try NDJSON.decode(ExtensionMessage.self, from: wire)
        #expect(decoded == .openPane(id: 7, agentID: agentID, axis: .vertical, cwd: nil, relativeTo: nil, command: nil))

        // `submit` defaults to true when the extension leaves it off.
        let inputWire = Data(#"{"type":"sendPaneInput","id":8,"agentID":"a1b2c3","paneID":"p1","text":"ls"}"#.utf8)
        let input = try NDJSON.decode(ExtensionMessage.self, from: inputWire)
        #expect(input == .sendPaneInput(id: 8, agentID: agentID, paneID: PaneID(rawValue: "p1"), text: "ls", submit: true))
    }

    @Test func reviewRequestDecodesCanonicalExtensionOutput() throws {
        let agentID = AgentID(rawValue: "a1b2c3")
        let wire = Data(
            #"{"type":"requestReview","id":3,"agentID":"a1b2c3","cwd":"/x","reference":"HEAD~2"}"#.utf8
        )
        #expect(try NDJSON.decode(ExtensionMessage.self, from: wire)
            == .requestReview(id: 3, agentID: agentID, cwd: "/x", reference: "HEAD~2"))

        let omitted = Data(#"{"type":"requestReview","id":4,"agentID":"a1b2c3"}"#.utf8)
        #expect(try NDJSON.decode(ExtensionMessage.self, from: omitted)
            == .requestReview(id: 4, agentID: agentID, cwd: nil, reference: nil))
    }

    @Test func lineBufferSplitsPartialChunks() throws {
        var buffer = LineBuffer()
        let first = try NDJSON.encode(ExtensionMessage.setAgentStatus(agentID: AgentID(), status: .idle))
        let second = try NDJSON.encode(ExtensionMessage.setAgentStatus(agentID: AgentID(), status: .done))
        let stream = first + second

        let mid = stream.count / 2
        var lines = try buffer.append(Data(stream.prefix(mid)))
        lines += try buffer.append(Data(stream.suffix(stream.count - mid)))
        #expect(lines.count == 2)

        let statuses = try lines.map { line -> AgentStatus in
            guard case .setAgentStatus(_, let status) = try NDJSON.decode(ExtensionMessage.self, from: line) else {
                throw NSError(domain: "test", code: 1)
            }
            return status
        }
        #expect(statuses == [.idle, .done])
    }

    @Test func lineBufferHandlesManyMessagesInOneChunk() throws {
        var buffer = LineBuffer()
        var stream = Data()
        for _ in 0..<50 {
            stream += try NDJSON.encode(ExtensionMessage.setAgentStatus(agentID: AgentID(), status: .working))
        }
        let lines = try buffer.append(stream)
        #expect(lines.count == 50)
        #expect(try buffer.append(Data()).isEmpty)
    }

    @Test func lineBufferAcceptsPayloadAtTheLimit() throws {
        var buffer = LineBuffer()
        let payload = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes)
        #expect(try buffer.append(payload).isEmpty)
        #expect(try buffer.append(Data([0x0A])) == [payload])
    }

    @Test func lineBufferRejectsAnUnterminatedPayloadOverTheLimit() throws {
        var buffer = LineBuffer()
        let oversized = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes + 1)
        #expect(throws: LineBufferError.payloadTooLarge(
            bytes: NDJSON.maxPayloadBytes + 1,
            terminated: false
        )) {
            try buffer.append(oversized)
        }
        #expect(try buffer.append(Data("ok\n".utf8)) == [Data("ok".utf8)])
    }

    @Test func lineBufferRejectsACompletePayloadOverTheLimit() throws {
        var buffer = LineBuffer()
        var oversized = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes + 1)
        oversized.append(0x0A)
        #expect(throws: LineBufferError.payloadTooLarge(
            bytes: NDJSON.maxPayloadBytes + 1,
            terminated: true
        )) {
            try buffer.append(oversized)
        }
        #expect(try buffer.append(Data("ok\n".utf8)) == [Data("ok".utf8)])
    }

    @Test func pathsLiveInShepherdSupportDirectory() {
        let socket = ShepherdPaths.socketURL()
        #expect(socket.lastPathComponent == "shepherd.sock")
        #expect(socket.deletingLastPathComponent().lastPathComponent == "Shepherd")
        let state = ShepherdPaths.stateURL()
        #expect(state.lastPathComponent == "state.json")
        #expect(state.deletingLastPathComponent() == ShepherdPaths.supportDirectory())
    }
}
