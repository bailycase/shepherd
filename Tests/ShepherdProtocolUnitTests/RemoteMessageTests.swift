import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

enum RemoteSamples {
    static let op = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let agent = AgentID(rawValue: "agent")
    static let session = SessionID(rawValue: "session")
    static let space = SpaceID(rawValue: "space")
    static let pane = PaneID(rawValue: "pane")
    static let tab = TabID(rawValue: "tab")
    static let split = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(cwd: "/a")), second: .leaf(LeafPane(cwd: "/b")))
    static let finalize = RemoteFinalizeOptions(
        base: "main", title: "fix", body: "details", autoCommit: false, deleteLocalBranch: true,
        autoMergePR: true, mergeMethod: "squash"
    )

    static let state: ShepherdState = {
        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }()

    static let agentQueries: [RemoteAgentQuery] = [
        .deleteKeepingWorktree,
        .worktreeInfo,
        .worktreeSetup(action: .check),
        .worktreeSetup(action: .applyIdentity(name: "O'Neil", email: "test@example.invalid")),
        .worktreeSetup(action: .installCommandLineTools),
        .worktreeSetup(action: .enableDeleteBranchOnMerge),
        .worktreeSetup(action: .enableAutoMerge),
        .worktreeSetup(action: .loginShell),
        .worktreeCommitCount(base: "release"),
        .worktreeDescription(base: "release", title: "fix"),
        .deleteWorktree(operationID: op, confirmedWarning: "dirty", fingerprint: "hash"),
        .deleteWorktree(operationID: op, confirmedWarning: nil),
        .finalizeWorktree(operationID: op, options: finalize),
        .worktreeStatus(operationID: op),
        .review(pullRequest: true),
        .reviewPane(paneID: pane, pullRequest: false),
        .reviewPane(paneID: pane),
        .finishReview(paneID: pane, text: "feedback"),
        .finishReview(paneID: pane, text: nil),
        .children,
        .inspectorPane(tabID: tab, action: .split(paneID: pane, axis: .horizontal)),
        .inspectorPane(tabID: tab, action: .close(paneID: pane)),
        .inspectorPane(tabID: tab, action: .resize(split: split, ratio: 0.6)),
        .search(query: "prompt"),
    ]

    static let agentResults: [RemoteAgentResult] = [
        .ok,
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: "3 uncommitted files", defaults: finalize,
                                         generateDescription: true, fingerprint: "abc")),
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: nil, defaults: finalize)),
        .worktreeSetup(RemoteWorktreeSetup(
            repoPath: "/host/repo",
            checks: ["git": .pass("installed"), "identity": .fail("missing"), "remote": .checking, "gh": .pending],
            repoSettings: ["allowAutoMerge": .disabled, "deleteBranchOnMerge": .unavailable("admin required"),
                           "a": .enabled, "b": .unknown, "c": .checking]
        )),
        .worktreeCommitCount(23),
        .worktreeCommitCount(nil),
        .worktreeDescription(body: "## Summary\nHost changes"),
        .worktreeOperation(RemoteWorktreeOperation(id: op, finished: true, error: "failed", progress: ["push failed"], prURL: nil)),
        .worktreeOperation(RemoteWorktreeOperation(id: op, prURL: "https://example.invalid/pr/1")),
        .review(files: Data("[]".utf8), reference: "origin/main"),
        .children([ChildRun(runID: "run", label: "child", state: "running")]),
        .inspector(tab),
        .inspectorFocus(pane),
        .search(snippet: "matched text"),
        .search(snippet: nil),
    ]

    static let automation = AutomationID(rawValue: "automation")
    static let draft = RemoteAutomationDraft(name: "Nightly \"dry\" run", prompt: "Run every migration\nReport", cwd: "/host/repo",
                                             enabled: false)
    static let automationRequests: [RemoteAutomationRequest] = [
        .setEnabled(enabled: true), .setEnabled(enabled: false), .run, .stop, .runs,
        .create(draft: draft), .update(draft: draft), .delete,
    ]
    static let runs: [AutomationRun] = [
        AutomationRun(id: op, startedAt: 1_700_000_000, settledAt: 1_700_000_043, endedAt: 1_700_000_100, result: .finished),
        AutomationRun(id: op, startedAt: 1_700_000_200, result: .needsYou, agentID: agent),
        AutomationRun(id: op, startedAt: 1_700_000_300, endedAt: 1_700_000_400, result: .interrupted),
    ]
    static let automationResults: [RemoteAutomationResult] = [.ok, .runs([]), .runs(runs)]
}

@Suite("Remote requests")
struct RemoteRequestTests {
    typealias S = RemoteSamples

    /// Exhaustive on purpose: a new case fails to compile here until it is named, then
    /// `samplesCoverEveryCase` fails until it has a sample.
    static func caseName(_ request: RemoteRequest) -> String {
        switch request {
        case .nativeThread, .hello, .stateFetch, .attach, .detach, .input, .resize, .paste, .openPane,
             .closePane, .resizePaneSplit, .listDir, .listModels, .addSpace, .createAgent, .upload,
             .creationOptions, .agentQuery, .agentAction, .automation:
            return Wire.caseName(request)
        }
    }
    static let caseCount = 20

    static let samples: [RemoteRequest] = [
        .nativeThread(id: 80, agentID: S.agent, request: .snapshot(expectedSessionID: "s", beforeEntryID: "m:3", afterRevision: 9)),
        .hello(id: 2, token: "", clientName: "Baily's MacBook \"Pro\"", protocolVersion: 99),
        .hello(id: 9, token: "t", clientName: "Mac", protocolVersion: 1, capabilities: RemoteProtocol.clientCapabilities),
        .stateFetch(id: 3),
        .attach(id: 4, sessionID: S.session, cols: 120, rows: 40, viewportGeneration: 2),
        .detach(sessionID: S.session),
        .input(sessionID: S.session, data: Data([0x1B, 0x5B, 0x41])),
        .resize(sessionID: S.session, cols: 80, rows: 24, viewportGeneration: 3),
        .paste(id: 12, sessionID: S.session, text: "multi\nline \"prompt\"", submit: false),
        .openPane(id: 14, agentID: S.agent, axis: .vertical, relativeTo: S.pane),
        .closePane(id: 15, agentID: S.agent, paneID: S.pane),
        .resizePaneSplit(id: 16, agentID: S.agent, split: S.split, ratio: 0.7),
        .listDir(id: 8, path: ""),
        .listModels(id: 10),
        .addSpace(id: 5, path: "/Users/demo/Developer/project"),
        .createAgent(id: 6, spaceID: S.space, cwd: "/tmp/checkout", model: "anthropic/claude-4", thinking: .high,
                     initialPrompt: "fix the \"thing\"\nplease", worktreeBranch: "worktree/a", worktreeBase: "origin/release",
                     worktreeFetchFirst: false),
        .upload(id: 50, action: .begin(sessionID: S.session, name: "image.png", size: 20)),
        .creationOptions(id: 54, spaceID: S.space, cwd: "/host/repo", fetchFirst: false),
        .agentQuery(id: 31, agentID: S.agent, query: .children),
        .agentAction(id: 20, agentID: S.agent, action: .rename(name: "new \"name\"")),
        .automation(id: 21, automationID: S.automation, request: .setEnabled(enabled: false)),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ request: RemoteRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ request: RemoteRequest) throws {
        #expect(try Wire.object(request)["type"] as? String == Self.caseName(request))
    }

    @Test(arguments: RemoteSamples.agentQueries)
    func everyAgentQueryRoundTrips(_ query: RemoteAgentQuery) throws {
        let request = RemoteRequest.agentQuery(id: 1, agentID: S.agent, query: query)
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test(arguments: [
        RemoteUploadAction.begin(sessionID: RemoteSamples.session, name: "a.png", size: 3),
        .chunk(uploadID: RemoteSamples.op, data: Data([0, 1, 2])),
        .finish(uploadID: RemoteSamples.op),
        .cancel(uploadID: RemoteSamples.op),
    ])
    func everyUploadActionRoundTrips(_ action: RemoteUploadAction) throws {
        #expect(try Wire.roundTrip(RemoteRequest.upload(id: 1, action: action)) == .upload(id: 1, action: action))
    }

    @Test(arguments: [RemoteAgentAction.rename(name: "x"), .deleteKeepingWorktree, .reorder(target: AgentID(rawValue: "b"))])
    func everyAgentActionRoundTrips(_ action: RemoteAgentAction) throws {
        #expect(try Wire.roundTrip(RemoteRequest.agentAction(id: 1, agentID: S.agent, action: action))
            == .agentAction(id: 1, agentID: S.agent, action: action))
    }

    @Test(arguments: RemoteSamples.automationRequests)
    func everyAutomationRequestRoundTrips(_ request: RemoteAutomationRequest) throws {
        let message = RemoteRequest.automation(id: 1, automationID: S.automation, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test func anAutomationRequestNamesItsAutomation() throws {
        let object = try Wire.object(RemoteRequest.automation(id: 1, automationID: S.automation, request: .run))
        #expect(object["automationID"] as? String == "automation")
        #expect(object["type"] as? String == "automation")
    }

    @Test func aMinimalCreateAgentOmitsEveryOptional() throws {
        let request = RemoteRequest.createAgent(id: 7, spaceID: S.space, cwd: nil, model: nil, thinking: nil, initialPrompt: nil)
        #expect(Set(try Wire.object(request).keys) == ["type", "id", "spaceID"])
        #expect(try Wire.roundTrip(request) == request)
    }

    /// Older clients predate viewport generations and the paste `submit` flag.
    @Test(arguments: [
        (#"{"type":"attach","id":1,"sessionID":"session","cols":80,"rows":24}"#,
         RemoteRequest.attach(id: 1, sessionID: RemoteSamples.session, cols: 80, rows: 24, viewportGeneration: 0)),
        (#"{"type":"resize","sessionID":"session","cols":90,"rows":30}"#,
         .resize(sessionID: RemoteSamples.session, cols: 90, rows: 30, viewportGeneration: 0)),
        (#"{"type":"paste","id":2,"sessionID":"session","text":"hi"}"#,
         .paste(id: 2, sessionID: RemoteSamples.session, text: "hi", submit: true)),
        // Older clients list no capabilities: the host reads them as not knowing its queue.
        (#"{"type":"hello","id":1,"token":"t","clientName":"old","protocolVersion":1}"#,
         .hello(id: 1, token: "t", clientName: "old", protocolVersion: 1, capabilities: nil)),
    ])
    func olderClientShapesDecodeWithDefaults(json: String, expected: RemoteRequest) throws {
        #expect(try Wire.decode(RemoteRequest.self, json) == expected)
    }

    @Test func unknownRequestKindsAreRejected() {
        #expect(throws: DecodingError.self) { try Wire.decode(RemoteRequest.self, #"{"type":"launchMissiles","id":1}"#) }
    }

    @Test func inputBytesTravelAsBase64() throws {
        let object = try Wire.object(RemoteRequest.input(sessionID: S.session, data: Data([0xFF, 0x00])))
        #expect(object["data"] as? String == "/wA=")
    }
}

@Suite("Remote replies")
struct RemoteReplyTests {
    typealias S = RemoteSamples

    static func caseName(_ reply: RemoteReply) -> String {
        switch reply {
        case .nativeThread, .uploadResult, .creationOptions, .helloOk, .agentResult, .ok, .paneOpened, .error,
             .state, .stateChanged, .attached, .output, .sessionExited, .dirListing, .models, .spaceAdded,
             .agentCreated, .automationResult:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 18

    static let samples: [RemoteReply] = [
        .nativeThread(id: 80, result: .accepted(operationID: S.op)),
        .uploadResult(id: 51, result: .complete(path: "/host/private/image.png")),
        .creationOptions(id: 52, options: RemoteCreationOptions(base: "origin/main", note: "cached", fetchFirst: false,
                                                                model: "host/model", thinking: .high)),
        .helloOk(id: 1, protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities),
        .agentResult(id: 60, result: .ok),
        .ok(id: 12),
        .paneOpened(id: 14, paneID: S.pane),
        .error(id: 2, code: "unauthorized", message: "bad token"),
        .state(id: 3, state: S.state),
        .stateChanged(state: ShepherdState()),
        .attached(id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 80, rows: 24, viewportGeneration: 2)),
        .output(sessionID: S.session, data: Data("screen bytes \u{1B}[31m".utf8)),
        .sessionExited(sessionID: S.session, code: 0),
        .dirListing(id: 8, path: "/Users/demo", parent: "/Users", dirs: ["Developer", "Documents"]),
        .models(id: 10, models: ["anthropic/claude-4", "openai/gpt-5"], defaultModel: "anthropic/claude-4"),
        .spaceAdded(id: 6, spaceID: S.space),
        .agentCreated(id: 7, agentID: S.agent),
        .automationResult(id: 22, result: .runs(S.runs)),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ reply: RemoteReply) throws {
        #expect(try Wire.object(reply)["type"] as? String == Self.caseName(reply))
    }

    @Test(arguments: RemoteSamples.agentResults)
    func everyAgentResultRoundTrips(_ result: RemoteAgentResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.agentResult(id: 1, result: result)) == .agentResult(id: 1, result: result))
    }

    @Test(arguments: RemoteSamples.automationResults)
    func everyAutomationResultRoundTrips(_ result: RemoteAutomationResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.automationResult(id: 1, result: result)) == .automationResult(id: 1, result: result))
    }

    /// A run a newer host reports with a result this build does not know reads as stopped;
    /// optional times and the agent may be absent.
    @Test func aRunFromANewerHostDecodesLeniently() throws {
        let json = #"{"id":"00000000-0000-0000-0000-00000000000A","startedAt":5,"result":"skipped"}"#
        #expect(try Wire.decode(AutomationRun.self, json)
            == AutomationRun(id: S.op, startedAt: 5, result: .stopped))
    }

    @Test(arguments: AutomationRunResult.allCases)
    func everyRunResultRoundTrips(_ result: AutomationRunResult) throws {
        #expect(try Wire.roundTrip([result]) == [result])
    }

    @Test(arguments: [
        (AutomationRun(startedAt: 10, settledAt: 53, endedAt: 100, result: .finished), 43.0 as Double?),
        (AutomationRun(startedAt: 10, endedAt: 25, result: .stopped), 15),
        (AutomationRun(startedAt: 10, result: .running), nil),
    ])
    func aRunLastsUntilItsFirstFinishedTurnOrItsEnd(_ run: AutomationRun, _ duration: Double?) {
        #expect(run.duration == duration)
    }

    @Test(arguments: [RemoteUploadResult.ready(uploadID: RemoteSamples.op), .complete(path: "/p")])
    func everyUploadResultRoundTrips(_ result: RemoteUploadResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.uploadResult(id: 1, result: result)) == .uploadResult(id: 1, result: result))
    }

    @Test(arguments: [
        RemoteReply.sessionExited(sessionID: RemoteSamples.session, code: nil),
        .dirListing(id: 9, path: "/", parent: nil, dirs: []),
        .models(id: 11, models: [], defaultModel: nil),
    ])
    func absentOptionalsRoundTrip(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test func sessionExitCodeTravelsUnderExitCode() throws {
        #expect(try Wire.object(RemoteReply.sessionExited(sessionID: S.session, code: 3))["exitCode"] as? Int == 3)
    }

    @Test func aHelloOkWithoutCapabilitiesMeansNone() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"helloOk","id":1,"protocolVersion":1}"#)
            == .helloOk(id: 1, protocolVersion: 1, capabilities: []))
    }

    /// Older hosts replied with a bare session id; the attachment's grid is then unknown (0).
    @Test func anAttachedReplyFromAnOlderHostDecodesWithAZeroGrid() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"attached","id":5,"sessionID":"session"}"#)
            == .attached(id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 0, rows: 0, viewportGeneration: 0)))
    }

    @Test func attachedStillCarriesTheBareSessionIDForOlderClients() throws {
        let object = try Wire.object(RemoteReply.attached(
            id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 1, rows: 2, viewportGeneration: 3)
        ))
        #expect(object["sessionID"] as? String == "session")
    }

    @Test func worktreeCheckStatePassesOnlyWhenPassed() {
        #expect(RemoteWorktreeCheckState.pass("ok").passed)
        for state in [RemoteWorktreeCheckState.fail("x"), .pending, .checking] { #expect(!state.passed) }
    }
}

@Suite("Remote protocol constants")
struct RemoteProtocolConstantTests {
    @Test func versionIsOne() {
        #expect(RemoteProtocol.version == 1)
    }

    @Test func hostAdvertisesEveryNamedCapabilityOnce() {
        let named = [
            RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeThreadV2Capability,
            RemoteProtocol.nativeThreadStartingCapability, RemoteProtocol.nativeQueueCapability,
            RemoteProtocol.pasteCapability, RemoteProtocol.paneControlCapability,
            RemoteProtocol.agentActionsCapability, RemoteProtocol.agentInspectionCapability,
            RemoteProtocol.worktreeActionsCapability, RemoteProtocol.worktreeSetupCapability,
            RemoteProtocol.uploadCapability, RemoteProtocol.creationOptionsCapability,
            RemoteProtocol.automationsCapability,
        ]
        #expect(Set(RemoteProtocol.capabilities) == Set(named))
        #expect(RemoteProtocol.capabilities.count == named.count)
    }

    /// Capability strings are negotiated with older peers; they must never be renamed.
    @Test func capabilityStringsAreStable() {
        #expect(RemoteProtocol.nativeThreadCapability == "native.thread.v1")
        #expect(RemoteProtocol.nativeThreadV2Capability == "native.thread.v2")
        #expect(RemoteProtocol.nativeThreadStartingCapability == "native.thread.starting.v1")
        #expect(RemoteProtocol.nativeQueueCapability == "native.queue.v1")
        #expect(RemoteProtocol.pasteCapability == "session.paste.v1")
        #expect(RemoteProtocol.paneControlCapability == "pane.control.v1")
        #expect(RemoteProtocol.uploadCapability == "session.upload.v1")
        #expect(RemoteProtocol.automationsCapability == "automations.v1")
    }

    @Test func aFullUploadChunkFitsInOneFrameAfterBase64() throws {
        let chunk = RemoteRequest.upload(id: Int.max, action: .chunk(
            uploadID: UUID(), data: Data(repeating: 0xAB, count: RemoteProtocol.uploadChunkBytes)
        ))
        #expect(try NDJSON.encode(chunk).count - 1 <= NDJSON.maxPayloadBytes)
        #expect(RemoteProtocol.uploadMaxBytes % RemoteProtocol.uploadChunkBytes == 0)
    }

    @Test func composedInputIsOneBracketedPasteWithAnOptionalReturn() {
        #expect(RemoteProtocol.composedInput(text: "one\ntwo", submit: true) == Data("\u{1B}[200~one\ntwo\u{1B}[201~\r".utf8))
        #expect(RemoteProtocol.composedInput(text: "draft", submit: false) == Data("\u{1B}[200~draft\u{1B}[201~".utf8))
        #expect(RemoteProtocol.composedInput(text: "", submit: false) == Data("\u{1B}[200~\u{1B}[201~".utf8))
    }
}
