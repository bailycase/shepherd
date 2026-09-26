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
        #expect(frames.count >= 24)
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
        .setThinking(expectedSessionID: "s", generation: "g", operationID: op, level: "xhigh"),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .message, text: "A", mode: .steer),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .cancel),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .resume),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .pause),
        .subagentCommand(expectedSessionID: "s", generation: "g", operationID: op, runID: "native-1", action: .continue),
        .subagentTranscript(expectedSessionID: "s", runID: "native-1"),
        .subagentTranscript(expectedSessionID: "s", runID: "native-1", beforeEntryID: "c:9"),
        .send(expectedSessionID: "s", generation: "g", operationID: op, text: "see", delivery: .followUp,
              images: [NativeImage(mimeType: "image/png", data: Data([1]), name: "checkout.png")]),
        .compact(expectedSessionID: "s", generation: "g", operationID: op),
        .compact(expectedSessionID: "s", generation: "g", operationID: op, instructions: "Keep the preview findings"),
        .send(expectedSessionID: "s", generation: "g", operationID: op, text: "taller", delivery: .followUp,
              designContext: NativeDesignContext(DesignViewRecord(
                visibleBoards: ["A.dc.html"], selectedBoards: ["A.dc.html"], selected: [DesignElementID("A.dc.html#5:1/1/0")!],
                selection: [.init(id: DesignElementID("A.dc.html#5:1/1/0")!, kind: .text, label: "Checkout funnel")]))),
    ] + queueActions.map { .queue(expectedSessionID: "s", generation: "g", operationID: op, action: $0) }

    /// Every queue action, as a request carries it.
    static let queueActions: [NativeQueueAction] = [
        .edit(id: op, text: "cover partial refunds"),
        .delete(id: op),
        .restore(ids: [op, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!], index: 1),
        .move(id: op, index: 0),
        .steer(ids: [op]),
        .unsteer(id: op),
        .clear,
        .hold(id: op, held: true),
        .setMode(mode: .oneAtATime),
        .setMode(mode: nil),
        .sendNow(ids: [op]),
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
        .failure(code: NativeThreadCode.starting, message: "pi is starting."),
        .snapshot(value: NativeThreadSnapshot(
            piSessionID: "s", generation: "g", revision: 4, running: true, model: "p/m", thinking: "low",
            thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], supportedActions: ["send", "abort"], dialogsSupported: true,
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
        .transcript(value: NativeSubagentTranscript(
            runID: "native-1", messages: [NativeThreadMessage(entryID: "c:2", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "also")], origin: .user)]
        )),
        .snapshot(value: NativeThreadSnapshot(
            piSessionID: "s", generation: "g", revision: 5, running: true, supportedActions: ["send", "queue"], dialogsSupported: true,
            dialogs: [],
            messages: [
                NativeThreadMessage(entryID: "user:1", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "a\n\nb")], timestamp: 1,
                                    origin: .queue(parts: [NativeQueuePart(id: op, text: "a", sentAt: 0.5), NativeQueuePart(text: "b", sentAt: 0.75, images: 2)]),
                                    operationID: op),
                NativeThreadMessage(entryID: "user:2", role: "user", blocks: [], origin: .steered),
                NativeThreadMessage(entryID: "user:3", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Show the counts")],
                                    origin: .designComment(id: op)),
                NativeThreadMessage(entryID: "user:4", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Pencil markup · 2 strokes · 2 notes")],
                                    origin: .designMarkup(strokes: 2, notes: 2)),
            ],
            provisional: [], clipped: false, runtime: "rpc",
            queue: NativeQueue(items: [
                NativeQueuedMessage(id: op, text: "steer", sentAt: 3, state: .steering),
                NativeQueuedMessage(id: UUID(), text: "then", images: [NativeQueuedImage(mimeType: "image/png", name: "a.png"), NativeQueuedImage(mimeType: "image/jpeg")],
                                    sentAt: 4, held: true),
            ], mode: .oneAtATime, paused: true, notice: "pi refused it.")
        )),
    ]

    /// Every context field and a compaction in history and in the live rows (v4).
    static let contextSnapshot = NativeThreadSnapshot(
        piSessionID: "s", generation: "g", revision: 6, running: false, supportedActions: ["send", "compact"], dialogsSupported: true,
        dialogs: [],
        messages: [NativeThreadMessage(entryID: "compactionSummary:5", role: "compactionSummary", blocks: [], timestamp: 5,
                                       compaction: NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000,
                                                                    summary: "## Goal\nShip it", willRetry: false))],
        provisional: [NativeThreadMessage(entryID: "compaction:9", role: "compaction", blocks: [],
                                          compaction: NativeCompaction(phase: .stopped, reason: .manual, tokensBefore: 92_000))],
        clipped: false, runtime: "rpc",
        context: NativeThreadContext(
            tokens: 42_000, window: 200_000, autoCompactAt: 183_616, autoCompact: true, keepRecent: 20_000, estimate: nil, before: 184_000,
            split: NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: 24_800, instructionFiles: ["AGENTS.md"]),
            largest: [NativeContextItem(entryID: "t:c1", kind: .file, label: "ThreadView.swift", tokens: 8_200),
                      NativeContextItem(entryID: "t:c2", kind: .command, label: "swift test", tokens: 6_100)],
            compacting: NativeCompactionRun(reason: .overflow, startedAt: 1_000, tokens: 203_000), summaryEntryID: "compactionSummary:5"))

    @Test func aContextSnapshotRoundTrips() throws {
        #expect(try Wire.roundTrip(NativeThreadResult.snapshot(value: Self.contextSnapshot)) == .snapshot(value: Self.contextSnapshot))
    }

    /// An older host sends no context: the client draws no ring. A context with nothing known
    /// yet decodes to empty parts, and omits them on the wire.
    @Test func anOlderSnapshotHasNoContextAndAnEmptyOneStaysSmall() throws {
        #expect(try Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot).context == nil)
        let empty = try Self.snapshot(adding: ["context": [String: Any]()])
        #expect(empty.context == NativeThreadContext())
        #expect((try Wire.object(empty)["context"] as? [String: Any])?.isEmpty == true)
    }

    /// Values a newer pi or host adds read as unknown rather than failing the snapshot.
    @Test func unknownReasonsPhasesAndKindsDecodeLeniently() throws {
        let snapshot = try Self.snapshot(adding: [
            "context": ["compacting": ["reason": "budget", "startedAt": 1], "largest": [["entryID": "t:x", "kind": "image", "label": "a.png", "tokens": 3]]],
            "messages": [["entryID": "e", "role": "compaction", "blocks": [], "truncated": false, "compaction": ["phase": "paused"]]],
        ])
        #expect(snapshot.context?.compacting?.reason == .unknown)
        #expect(snapshot.context?.largest.first?.kind == .tool)
        #expect(snapshot.messages.first?.compaction?.phase == .done)
        #expect(NativeCompactionReason(pi: "threshold") == .threshold && NativeCompactionReason(pi: nil) == .unknown)
    }

    /// Question records (QuestionAnswered) in history and in the live rows, one per outcome and kind.
    static let questionSnapshot = NativeThreadSnapshot(
        piSessionID: "s", generation: "g", revision: 7, running: true, supportedActions: ["send", "answer"], dialogsSupported: true,
        dialogs: [],
        messages: [
            NativeThreadMessage(entryID: "q:a", role: "question", blocks: [], timestamp: 20,
                                question: NativeQuestionRecord(kind: .select, question: "Which way?", answer: "Left (Recommended)",
                                                               outcome: .answered, askedAt: 10)),
            NativeThreadMessage(entryID: "q:b", role: "question", blocks: [], timestamp: 30,
                                question: NativeQuestionRecord(kind: .confirm, question: "Clear it?", confirmed: false,
                                                               outcome: .answered, askedAt: 25)),
            NativeThreadMessage(entryID: "q:c", role: "question", blocks: [], timestamp: 40,
                                question: NativeQuestionRecord(kind: .input, question: "Name?", outcome: .dismissed, askedAt: 35)),
        ],
        provisional: [NativeThreadMessage(entryID: "q:d", role: "question", blocks: [], timestamp: 60,
                                          question: NativeQuestionRecord(kind: .editor, question: "Edit the plan", outcome: .expired,
                                                                         askedAt: 50))],
        clipped: false, runtime: "rpc")

    @Test func questionRecordsRoundTrip() throws {
        #expect(try Wire.roundTrip(NativeThreadResult.snapshot(value: Self.questionSnapshot)) == .snapshot(value: Self.questionSnapshot))
    }

    /// A kind or an outcome a newer host adds reads as unknown, never failing the snapshot; a
    /// record missing its fields still decodes.
    @Test func questionRecordsDecodeLeniently() throws {
        let snapshot = try Self.snapshot(adding: ["messages": [
            ["entryID": "q:x", "role": "question", "blocks": [], "truncated": false,
             "question": ["kind": "multiSelect", "question": "Pick", "outcome": "retracted", "askedAt": 1]],
            ["entryID": "q:y", "role": "question", "blocks": [], "truncated": false, "question": [String: Any]()],
        ]])
        let first = try #require(snapshot.messages.first?.question)
        #expect(first.kind == nil && first.outcome == .unknown && first.question == "Pick")
        #expect(snapshot.messages.last?.question == NativeQuestionRecord(kind: nil, question: "", outcome: .unknown, askedAt: 0))
    }

    @Test(arguments: results)
    func resultsRoundTrip(_ result: NativeThreadResult) throws {
        #expect(try Wire.roundTrip(result) == result)
    }

    // MARK: Start problems

    /// Every cause, with and without an exit code, as a host answers an agent whose pi stopped
    /// before it served.
    static let startProblems: [NativeStartProblem] = NativeStartProblem.Kind.allCases.map {
        NativeStartProblem(kind: $0, exitCode: 1, lines: ["No models available."])
    } + [NativeStartProblem(kind: .resumedAsNew), NativeStartProblem(kind: .exited, exitCode: 127, lines: [])]

    @Test(arguments: startProblems)
    func aStartProblemRoundTripsOnItsSnapshot(_ problem: NativeStartProblem) throws {
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "start-problem", revision: 0, running: false, supportedActions: [],
                                            dialogsSupported: false, dialogs: [], messages: [], provisional: [], clipped: false,
                                            runtime: "rpc", startProblem: problem)
        #expect(try Wire.roundTrip(NativeThreadResult.snapshot(value: snapshot)) == .snapshot(value: snapshot))
    }

    /// An older host names no problem; a newer host's cause reads as `exited`, and missing or
    /// malformed parts never fail the snapshot.
    @Test func startProblemsDecodeLeniently() throws {
        #expect(try Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot).startProblem == nil)
        #expect((try Wire.object(Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot)))["startProblem"] == nil)
        let newer = try Self.snapshot(adding: ["startProblem": ["kind": "quotaExceeded", "exitCode": "one", "lines": 3]])
        #expect(newer.startProblem == NativeStartProblem(kind: .exited))
        #expect(try Self.snapshot(adding: ["startProblem": [String: Any]()]).startProblem == NativeStartProblem(kind: .exited))
    }

    @Test func startProblemSpellingsAreStable() {
        #expect(NativeStartProblem.Kind.allCases.map(\.rawValue) == ["notSignedIn", "extensionFailed", "engineMissing", "resumedAsNew", "exited"])
    }

    /// Hosts and clients of different versions compare these; they must never be renamed.
    @Test func availabilityCodesAreStable() {
        #expect(NativeThreadCode.starting == "native_starting")
        #expect(NativeThreadCode.unavailable == "native_unavailable")
    }

    @Test func aStartingRefusalTravelsAsARemoteError() throws {
        let reply = RemoteReply.error(id: 4, code: NativeThreadCode.starting, message: "pi is starting.")
        #expect(try Wire.roundTrip(reply) == reply)
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

    // MARK: Queue (v3)

    /// An older host has no queue: the client then sends straight to pi, as before.
    @Test func aSnapshotFromAnOlderHostHasNoQueueAndMessagesNoOrigin() throws {
        #expect(try Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot).queue == nil)
        let message = try Wire.decode(NativeThreadMessage.self, #"{"entryID":"e","role":"user","blocks":[],"truncated":false}"#)
        #expect(message.origin == nil && message.operationID == nil)
        #expect(try Wire.object(Wire.decode(NativeThreadSnapshot.self, Self.v1Snapshot))["queue"] == nil)
    }

    /// What a newer host adds (a mode, an item state, an origin) is unknown here, never a
    /// snapshot that fails to load.
    @Test func aNewerHostsQueueModeItemStateAndOriginDecodeLeniently() throws {
        let snapshot = try Self.snapshot(adding: [
            "queue": ["items": [["id": Self.op.uuidString, "text": "t", "sentAt": 1, "state": "delivering"]], "mode": "whenIdle"],
            "messages": [["entryID": "u", "role": "user", "blocks": [], "truncated": false, "origin": ["forwarded": ["from": "x"]]]],
        ])
        #expect(snapshot.queue?.mode == nil)
        #expect(snapshot.queue?.items.first?.state == .queued)
        #expect(snapshot.queue?.items.first?.held == false && snapshot.queue?.items.first?.images == [])
        #expect(snapshot.queue?.paused == false)
        #expect(snapshot.messages.first?.origin == .unknown)
    }

    @Test func queueWireSpellingsAreStable() throws {
        #expect(NativeQueueMode.oneAtATime.rawValue == "oneAtATime" && NativeQueueMode.all.rawValue == "all")
        #expect(NativeQueuedMessage.State.queued.rawValue == "queued" && NativeQueuedMessage.State.steering.rawValue == "steering")
        #expect(Wire.caseName(NativeQueueAction.clear) == "clear")
        let steered = try Wire.object(NativeThreadMessage(entryID: "e", role: "user", blocks: [], origin: .steered))
        #expect((steered["origin"] as? [String: Any])?.keys.sorted() == ["steered"])
        let user = try Wire.object(NativeThreadMessage(entryID: "e", role: "user", blocks: [], origin: .user))
        #expect((user["origin"] as? [String: Any])?.keys.sorted() == ["user"])
        let id = UUID(uuidString: "7A1C2E7B-39F5-4B0C-9A40-0E8B1F3C5D21")!
        let comment = try Wire.object(NativeThreadMessage(entryID: "e", role: "user", blocks: [], origin: .designComment(id: id)))
        #expect((comment["origin"] as? [String: Any])?["designComment"] as? [String: String] == ["id": id.uuidString])
        let markup = try Wire.object(NativeThreadMessage(entryID: "e", role: "user", blocks: [], origin: .designMarkup(strokes: 2, notes: 1)))
        #expect((markup["origin"] as? [String: Any])?["designMarkup"] as? [String: Int] == ["strokes": 2, "notes": 1])
        // An older client reads an origin it doesn't know as unknown, and shows the words.
        #expect(try Wire.decode(NativeMessageOrigin.self, #"{"designMarkup":{"strokes":2,"notes":1}}"#) == .designMarkup(strokes: 2, notes: 1))
        #expect(try Wire.decode(NativeMessageOrigin.self, #"{"designSketch":{}}"#) == .unknown)
    }

    @Test func aQueuedPartDefaultsToNoImages() throws {
        let part = try Wire.decode(NativeQueuePart.self, #"{"text":"t","sentAt":2}"#)
        #expect(part == NativeQueuePart(text: "t", sentAt: 2) && part.images == 0 && part.id == nil)
    }

    @Test func anImageNameIsOmittedWhenAbsent() throws {
        #expect(try Wire.object(NativeImage(mimeType: "image/png", data: Data([1])))["name"] == nil)
    }

    @Test func transcriptPagesDefaultToNoEarlierEntries() {
        let page = NativeSubagentTranscript(runID: "r", messages: [])
        #expect(page.earlierCount == 0 && page.olderCursor == nil)
    }
}

/// What one send's images may be, on the host (a send, an opening prompt) and before a client
/// creates a thread with them.
@Suite("Native images per send")
struct NativeImageLimitTests {
    private static let mib = 1024 * 1024

    private static func images(_ sizes: [Int], type: String = "image/png") -> [NativeImage] {
        sizes.map { NativeImage(mimeType: type, data: Data(count: $0)) }
    }

    @Test(arguments: [
        ([Int](), "image/png", true),
        ([1, 1, 1, 1], "image/png", true),
        ([mib, mib, mib, mib], "image/png", true),
        ([1, 1, 1, 1, 1], "image/png", false),
        ([2 * mib + 1], "image/png", false),
        ([2 * mib, 2 * mib, 2 * mib], "image/png", false),
        ([1], "text/plain", false),
    ])
    func oneSendTakesFourImagesOfTwoMiBAndFiveInAll(sizes: [Int], type: String, fits: Bool) {
        #expect(NativeImage.fitOneSend(Self.images(sizes, type: type)) == fits)
    }
}
