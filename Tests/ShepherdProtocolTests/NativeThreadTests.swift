import Foundation
import Testing
import ShepherdProtocol

@Suite("Native thread wire")
struct NativeThreadTests {
    @Test func sharedJSONFixturesRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Extensions/native-thread-wire.json"))
        let frames = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for frame in frames {
            let json = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            let encoded: Data
            switch frame["type"] as? String {
            case "helloNativeAgent", "nativeThreadResult":
                encoded = try NDJSON.encode(JSONDecoder().decode(ExtensionMessage.self, from: json))
            case "nativeThreadCommand":
                encoded = try NDJSON.encode(JSONDecoder().decode(ExtensionReply.self, from: json))
            default:
                if frame["request"] != nil {
                    encoded = try NDJSON.encode(JSONDecoder().decode(RemoteRequest.self, from: json))
                } else {
                    encoded = try NDJSON.encode(JSONDecoder().decode(RemoteReply.self, from: json))
                }
            }
            let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            #expect(decoded == frame as NSDictionary)
        }
        #expect(RemoteProtocol.capabilities.contains("native.thread.v1"))
        #expect(RemoteProtocol.capabilities.contains("native.thread.v2"))
    }

    /// v2 fields are optional on both sides: a v1 snapshot decodes with them nil, a v1 request
    /// (no `images`) round-trips byte-identically, and images never appear on the wire when nil.
    @Test func v2FieldsAreOptionalAndRoundTrip() throws {
        let old = Data(#"{"piSessionID":"s","generation":"g","revision":1,"running":false,"supportedActions":[],"dialogsSupported":false,"dialogs":[],"messages":[],"provisional":[],"clipped":false}"#.utf8)
        let legacy = try JSONDecoder().decode(NativeThreadSnapshot.self, from: old)
        #expect(legacy.runtime == nil && legacy.stats == nil && legacy.commands == nil && !legacy.isRPC)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(encoded["runtime"] == nil && encoded["stats"] == nil && encoded["commands"] == nil)

        var v2 = legacy
        v2.runtime = "rpc"
        v2.stats = NativeThreadStats(contextTokens: 1, contextWindow: nil, contextPercent: 0.5, totalTokens: nil, cost: nil)
        v2.commands = [NativeCommand(name: "a"), NativeCommand(name: "b", description: "d", source: "skill")]
        #expect(try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONEncoder().encode(v2)) == v2)
        #expect(v2.isRPC)

        let plain = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "t", delivery: .followUp)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: NDJSON.encode(plain)) as? [String: Any])
        #expect(((plainJSON["send"] as? [String: Any])?["images"]) == nil)
        #expect(plain.images.isEmpty)
        let image = NativeImage(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        let withImages = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "t", delivery: .steer, images: [image])
        #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(withImages)) == withImages)
        #expect(withImages.images == [image])
        for request in [
            NativeThreadRequest.setModel(expectedSessionID: "s", generation: "g", operationID: UUID(), model: "p/m"),
            .setThinking(expectedSessionID: "s", generation: "g", operationID: UUID(), level: "off"),
        ] {
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
            #expect(request.images.isEmpty)
        }
    }

    @Test func optionalWidgetsRoundTripAndFutureKindsStayReadable() throws {
        let old = Data(#"{"piSessionID":"s","generation":"g","revision":1,"running":false,"supportedActions":[],"dialogsSupported":false,"dialogs":[],"messages":[],"provisional":[],"clipped":false}"#.utf8)
        let legacy = try JSONDecoder().decode(NativeThreadSnapshot.self, from: old)
        #expect((legacy.widgets ?? []).isEmpty)
        var json = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["widgets"] = [
            ["namespace": "build", "key": "result", "kind": "status", "title": "Build", "text": "passed"],
            ["namespace": "review", "key": "notes", "kind": "text", "text": "**literal**\nnext"],
        ]
        let snapshot = try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(snapshot.widgets?.map(\.kind) == [.status, .text])
        #expect(snapshot.widgets?.last?.title == nil)
        #expect(try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        json["widgets"] = [["kind": "future-chart", "text": ["not": "a string"]],
                           ["namespace": "a:b", "key": "c", "kind": "text", "text": "first"],
                           ["namespace": "a", "key": "b:c", "kind": "text", "text": "second"]] as [[String: Any]]
        let future = try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(future.widgets?.first?.kind == .unknown)
        let visible = try #require(future.widgets).filter { $0.kind != .unknown }
        #expect(visible.count == 2)
        #expect(Set(visible.map(\.id)).count == 2)
        #expect(future.piSessionID == legacy.piSessionID)
        json["widgets"] = [
            ["namespace": "build", "key": "\u{e9}", "kind": "text", "text": "composed"],
            ["namespace": "build", "key": "e\u{301}", "kind": "text", "text": "decomposed"],
        ]
        let unicode = try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(Set(try #require(unicode.widgets).map(\.id)).count == 2)
    }

    /// Subagents are v2-additive: a snapshot without them decodes nil, the field stays off the
    /// wire when nil, and the new request/result arms round-trip.
    @Test func subagentArmsAreOptionalAndRoundTrip() throws {
        let old = Data(#"{"piSessionID":"s","generation":"g","revision":1,"running":false,"supportedActions":[],"dialogsSupported":false,"dialogs":[],"messages":[],"provisional":[],"clipped":false}"#.utf8)
        let legacy = try JSONDecoder().decode(NativeThreadSnapshot.self, from: old)
        #expect(legacy.subagents == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(encoded["subagents"] == nil)
        var v2 = legacy
        v2.subagents = [
            NativeSubagent(runID: "native-1", label: "worker: restyle", state: "running", startedAt: 1, needsAttention: false,
                           role: "worker", model: "p/m", context: "async", step: ChildStep(index: 1, total: 3), turns: 2, toolCalls: 3, tokens: 4,
                           lastActivity: ChildActivity(tool: "bash", preview: "swift build", at: 5), toolCallID: "call_1", task: "Restyle", sessionFile: "/tmp/s.jsonl"),
            NativeSubagent(runID: "native-2", label: "reviewer: check", state: "running", needsAttention: true, attentionText: "Which?",
                           question: ChildQuestion(text: "Which?", options: ["A", "B"])),
            NativeSubagent(runID: "native-3", label: "tests: run", state: "complete", result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118000), output: "All pass."),
            NativeSubagent(runID: "native-4", label: "docs: write", state: "failed", exitReason: "exit 1 · context limit"),
        ]
        #expect(try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONEncoder().encode(v2)) == v2)
        for request in [
            NativeThreadRequest.subagentCommand(expectedSessionID: "s", generation: "g", operationID: UUID(), runID: "native-1", action: .message, text: "A", mode: .steer),
            .subagentCommand(expectedSessionID: "s", generation: "g", operationID: UUID(), runID: "native-1", action: .cancel),
            .subagentCommand(expectedSessionID: "s", generation: "g", operationID: UUID(), runID: "native-1", action: .resume),
            .subagentTranscript(expectedSessionID: "s", runID: "native-1"),
            .subagentTranscript(expectedSessionID: "s", runID: "native-1", beforeEntryID: "c:9"),
        ] {
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
            #expect(request.images.isEmpty)
        }
        let page = NativeThreadResult.transcript(value: NativeSubagentTranscript(
            runID: "native-1", messages: [NativeThreadMessage(entryID: "c:1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "hi")])],
            olderCursor: "c:1", earlierCount: 72))
        #expect(try NDJSON.decode(NativeThreadResult.self, from: NDJSON.encode(page)) == page)
    }

    @Test func allAnswersAndDeliveriesRoundTrip() throws {
        let answers: [NativeDialogAnswer] = [.select(value: "a"), .confirm(value: false), .input(value: ""), .editor(value: "draft\nnext"), .cancel]
        for answer in answers {
            let request = NativeThreadRequest.answer(expectedSessionID: "s", generation: "g", operationID: UUID(), dialogID: "d", answer: answer)
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
        }
        for delivery in [NativeThreadDelivery.followUp, .steer] {
            let request = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "hello", delivery: delivery)
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
        }
    }
}
