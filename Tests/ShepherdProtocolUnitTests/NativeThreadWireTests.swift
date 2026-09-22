import Foundation
import Testing
import ShepherdProtocol

@Suite("Native thread wire")
struct NativeThreadWireTests {
    static let op = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// A v1 snapshot: none of the v2 keys.
    static let v1Snapshot = #"{"piSessionID":"s","generation":"g","revision":1,"running":false,"supportedActions":[],"dialogsSupported":false,"dialogs":[],"messages":[],"provisional":[],"clipped":false}"#

    static func snapshot(adding extra: [String: Any]) throws -> NativeThreadSnapshot {
        var json = try #require(JSONSerialization.jsonObject(with: Data(v1Snapshot.utf8)) as? [String: Any])
        json.merge(extra) { $1 }
        return try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// `Tests/Extensions/native-thread-wire.json` is shared with the JS children tests: every
    /// frame must decode and re-encode to exactly the same JSON.
    @Test func goldenFramesRoundTripExactly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/native-thread-wire.json")
        let frames = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(frames.count >= 13)
        for frame in frames {
            let json = try JSONSerialization.data(withJSONObject: frame)
            let reencoded = frame["request"] != nil
                ? try NDJSON.encode(JSONDecoder().decode(RemoteRequest.self, from: json))
                : try NDJSON.encode(JSONDecoder().decode(RemoteReply.self, from: json))
            let decoded = try #require(JSONSerialization.jsonObject(with: reencoded) as? NSDictionary)
            #expect(decoded == frame as NSDictionary, "frame id \(frame["id"] ?? "?")")
        }
    }

    static let requests: [NativeThreadRequest] = [
        .snapshot(),
        .snapshot(expectedSessionID: "s", beforeEntryID: "m:3", afterRevision: 9),
        .send(expectedSessionID: "s", generation: "g", operationID: op, text: "hi", delivery: .followUp),
        .send(expectedSessionID: "s", generation: "g", operationID: op, text: "look", delivery: .steer,
              images: [NativeImage(mimeType: "image/png", data: Data([1, 2, 3]))]),
        .abort(expectedSessionID: "s", generation: "g", operationID: op),
        .answer(expectedSessionID: "s", generation: "g", operationID: op, dialogID: "d", answer: .select(value: "a")),
        .answer(expectedSessionID: "s", generation: "g", operationID: op, dialogID: "d", answer: .confirm(value: false)),
        .answer(expectedSessionID: "s", generation: "g", operationID: op, dialogID: "d", answer: .input(value: "")),
        .answer(expectedSessionID: "s", generation: "g", operationID: op, dialogID: "d", answer: .editor(value: "draft\nnext")),
        .answer(expectedSessionID: "s", generation: "g", operationID: op, dialogID: "d", answer: .cancel),
        .setModel(expectedSessionID: "s", generation: "g", operationID: op, model: "anthropic/claude"),
        .setThinking(expectedSessionID: "s", generation: "g", operationID: op, level: "off"),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .message, text: "A", mode: .steer),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .cancel),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .resume),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .pause),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .continue),
        .subagentTranscript(expectedSessionID: "s", runID: "native-1"),
        .subagentTranscript(expectedSessionID: "s", runID: "native-1", beforeEntryID: "c:9"),
    ]

    @Test(arguments: requests)
    func requestsRoundTrip(_ request: NativeThreadRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test func imagesAreOnlyReportedForSendAndOmittedWhenNil() throws {
        let image = NativeImage(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let plain = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: Self.op, text: "t", delivery: .followUp)
        let withImage = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: Self.op, text: "t", delivery: .steer, images: [image])
        #expect(plain.images.isEmpty)
        #expect(withImage.images == [image])
        #expect(NativeThreadRequest.abort(expectedSessionID: "s", generation: "g", operationID: Self.op).images.isEmpty)
        #expect((try Wire.object(plain)["send"] as? [String: Any])?["images"] == nil)
    }

    static let results: [NativeThreadResult] = [
        .accepted(operationID: op),
        .unchanged(piSessionID: "s", generation: "g", revision: 3),
        .failure(code: "stale_session", message: "refresh"),
        .snapshot(value: NativeThreadSnapshot(
            piSessionID: "s", generation: "g", revision: 4, running: true, model: "p/m", thinking: "low",
            supportedActions: ["send", "abort"], dialogsSupported: true,
            dialogs: [NativeThreadDialog(id: "d", kind: .editor, title: "Edit", options: ["a"], message: "m", placeholder: "p",
                                         prefill: "x", timeout: 5000, unavailable: "external-editor")],
            widgets: [NativeThreadWidget(namespace: "pi", key: "notify", kind: .status, title: "warning", text: "careful")],
            messages: [NativeThreadMessage(entryID: "m:0", role: "toolResult", blocks: [NativeThreadBlock(kind: .thinking, text: "hm")],
                                           toolName: "bash", toolCallID: "c", argumentsText: "{}", status: "done", isError: false,
                                           truncated: true, timestamp: 1, startedAt: 0.5, thinkingSeconds: 2)],
            olderCursor: "m:0", provisional: [NativeThreadMessage(entryID: "p", role: "user", blocks: [])], clipped: false,
            runtime: "rpc", stats: NativeThreadStats(contextTokens: 42000, contextWindow: 200000, contextPercent: 21, totalTokens: 100, cost: 0.1),
            commands: [NativeCommand(name: "fix", description: "Fix it", source: "prompt"), NativeCommand(name: "bare")],
            subagents: [ChildRun(runID: "native-1", label: "worker", state: "running", step: ChildStep(index: 1, total: 3))]
        )),
        .transcript(value: NativeSubagentTranscript(
            runID: "native-1", messages: [NativeThreadMessage(entryID: "c:1", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "task")])],
            olderCursor: "c:1", earlierCount: 72
        )),
    ]

    @Test(arguments: results)
    func resultsRoundTrip(_ result: NativeThreadResult) throws {
        #expect(try Wire.roundTrip(result) == result)
    }

    @Test func aV1SnapshotDecodesWithEveryV2FieldAbsent() throws {
        let snapshot = try Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot)
        #expect(snapshot.runtime == nil && snapshot.stats == nil && snapshot.commands == nil)
        #expect(snapshot.subagents == nil && snapshot.widgets == nil)
        #expect(!snapshot.isRPC)
    }

    @Test func absentV2FieldsStayOffTheWire() throws {
        let object = try Wire.object(Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot))
        for key in ["runtime", "stats", "commands", "subagents", "widgets", "model", "olderCursor"] {
            #expect(object[key] == nil, "\(key)")
        }
    }

    @Test(arguments: [("rpc", true), ("terminal", false)])
    func onlyAnRPCRuntimeCountsAsRPC(runtime: String, isRPC: Bool) throws {
        #expect(try Self.snapshot(adding: ["runtime": runtime]).isRPC == isRPC)
    }

    @Test func messagesDefaultToUntruncated() throws {
        let message = try Wire.decode(NativeThreadMessage.self, #"{"entryID":"e","role":"user","blocks":[],"truncated":false}"#)
        #expect(!message.truncated && message.timestamp == nil && message.startedAt == nil && message.thinkingSeconds == nil)
        #expect(NativeThreadMessage(entryID: "e", role: "user", blocks: []).truncated == false)
    }

    @Test func knownWidgetKindsDecodeWithOptionalTitle() throws {
        let snapshot = try Self.snapshot(adding: ["widgets": [
            ["namespace": "build", "key": "result", "kind": "status", "title": "Build", "text": "passed"],
            ["namespace": "review", "key": "notes", "kind": "text", "text": "**literal**"],
        ]])
        #expect(snapshot.widgets?.map(\.kind) == [.status, .text])
        #expect(snapshot.widgets?.last?.title == nil)
        #expect(try Wire.roundTrip(snapshot) == snapshot)
    }

    /// A future widget kind need not carry this version's fields; the thread must still load.
    @Test func aFutureWidgetKindDecodesAsUnknownInsteadOfFailingTheSnapshot() throws {
        let snapshot = try Self.snapshot(adding: ["widgets": [["kind": "future-chart", "text": ["not": "a string"]]]])
        #expect(snapshot.widgets?.first?.kind == .unknown)
        #expect(snapshot.piSessionID == "s")
    }

    @Test func aKnownWidgetKindMissingRequiredFieldsStillFails() {
        #expect(throws: DecodingError.self) {
            try Self.snapshot(adding: ["widgets": [["kind": "text", "text": "no namespace"]]])
        }
    }

    /// JS keys are byte strings: separators inside a part and canonically-equal Unicode must
    /// not collide.
    @Test(arguments: [
        (("a:b", "c"), ("a", "b:c")),
        (("build", "\u{e9}"), ("build", "e\u{301}")),
    ])
    func widgetIdentityIsByteExact(first: (String, String), second: (String, String)) {
        let a = NativeThreadWidget(namespace: first.0, key: first.1, kind: .text, text: "")
        let b = NativeThreadWidget(namespace: second.0, key: second.1, kind: .text, text: "")
        #expect(a.id != b.id)
    }

    @Test func wireEnumSpellingsAreStable() {
        #expect(NativeThreadDelivery.followUp.rawValue == "followUp")
        #expect(NativeThreadDelivery.steer.rawValue == "steer")
        #expect(NativeThreadBlock.Kind.unsupportedImage.rawValue == "unsupportedImage")
        #expect(NativeSubagentAction.continue.rawValue == "continue")
    }

    @Test func transcriptPagesDefaultToNoEarlierEntries() {
        let page = NativeSubagentTranscript(runID: "r", messages: [])
        #expect(page.earlierCount == 0 && page.olderCursor == nil)
    }
}
