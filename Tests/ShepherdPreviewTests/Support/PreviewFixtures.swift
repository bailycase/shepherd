import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
@testable import ShepherdApp

// MARK: Workspace

/// A real server and view model with isolated preferences, seeded for a preview. Agents whose
/// layouts the workspace mounts get a running stub pi, so rendering never launches anything
/// else. Call `stop()` when done.
@MainActor
final class PreviewWorkspace {
    let scratch: ScratchServer
    let defaults = ScratchDefaults()
    let settings: AppSettings
    let vm: ShepherdViewModel
    var server: SessionServer { scratch.server }
    var dir: URL { scratch.dir }

    /// Settings ▸ Pi shows `yourPi` (a fixture: never this machine's pi, nor a read of the scratch one).
    init(modelCatalog: @escaping SessionServer.ModelCatalog = { ScratchServer.standInModels }, mcp: MCPStore? = nil,
         yourPi: YourPiSurvey = PreviewYourPi.imported) throws {
        try PreviewEnvironment.install()
        scratch = try ScratchServer(modelCatalog: modelCatalog)
        settings = AppSettings(store: defaults)
        // Never ask a real model to write a PR description while rendering the finalize sheet.
        settings.worktreeGeneratePRDescription = false
        vm = ShepherdViewModel(
            server: scratch.server, settings: settings, keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .light),
            remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in },
            // Only the agents a preview mounts get a pi, and those get the stub.
            restoresAgentsAtLaunch: false,
            // Fixtures set the checkout each header shows.
            checkoutReader: nil,
            mcp: mcp,
            yourPi: YourPiModel(pi: scratch.server.pi, survey: yourPi)
        )
        // The boards' footer, never this machine's user and name.
        vm.sidebarFooterIdentity = ("Baily", SidebarDerivation.footerDetail(computerName: "build-01"))
    }

    /// Replaces the server's workspace and waits for the view model to adopt it.
    func seed(_ state: ShepherdState) async throws {
        try await server.putState(state)
        let vm = vm, server = server
        try await eventuallyOnMain("the preview workspace to load") { vm.state == server.state }
    }

    /// An agent record and its one-pane layout; `live` binds a running stub pi to the pane.
    func agent(_ name: String, in space: Space, order: Int, status: AgentStatus = .idle, live: Bool = false,
               branch: String? = nil, cwd: String? = nil) async throws -> (Agent, ShepherdCore.Tab) {
        var session: SessionID?
        if live {
            session = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: StubPi.command, runtime: .rpc)).id
        }
        let id = AgentID()
        let pane = LeafPane(sessionID: session, cwd: cwd ?? space.path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
        var agent = Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status, nameIsFinal: true)
        agent.worktreeBranch = branch
        return (agent, tab)
    }

    func stop() {
        for connection in vm.remoteHosts.connections { vm.remoteHosts.removeHost(id: connection.id) }
        scratch.stop()
    }
}

// MARK: Threads

/// A thread store fed a fixed snapshot (and subagent transcripts), as the workspace wires one
/// to its agent's pi.
@MainActor
final class ThreadFixture {
    let store = NativeThreadStore()
    let commands = ThreadCommandCenter()
    var snapshot: NativeThreadSnapshot
    var transcripts: [String: NativeSubagentTranscript] = [:]
    /// True: the agent's pi is still starting, and every snapshot request says so.
    var starting = false

    init(_ snapshot: NativeThreadSnapshot) { self.snapshot = snapshot }

    var request: NativeThreadStore.Request {
        { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "fixture released") }
            if case .subagentTranscript(_, let runID, _) = value, let page = self.transcripts[runID] { return .transcript(value: page) }
            if self.starting { return .failure(code: NativeThreadCode.starting, message: "pi is starting.") }
            return .snapshot(value: self.snapshot)
        }
    }

    /// Header over thread, the way the workspace composes a native agent.
    func thread(title: String = "Investigate SwiftUI live preview capabilities", inspected: String? = nil,
                workingDirectory: String = "~/Developer/Shepherd",
                listModels: (() async -> ModelCatalog)? = nil, contextDetailsOpen: Bool = false,
                restartPi: ((Bool) -> Void)? = { _ in }, authNotice: ThreadAuthNotice? = nil,
                slashLogin: SlashLoginActions? = nil) -> some View {
        VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: title)
            ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "preview",
                       agentName: "Investigate", workingDirectory: workingDirectory, inspectSubagent: { _ in },
                       inspectedRunID: inspected, review: { _ in },
                       turnActions: TurnChangesActions(review: { _, _ in }, undo: { _ in nil }, redo: { _ in nil }), listModels: listModels,
                       restartPi: restartPi, authNotice: authNotice,
                       authActions: ThreadAuthActions(signIn: { _ in }, useModel: { _ in }, models: { ["openai/gpt-5.3-codex"] }),
                       slashLogin: slashLogin,
                       contextDetailsOpen: contextDetailsOpen)
        }
        .environment(\.threadCommands, commands)
    }
}

/// A thread whose host holds a queue (`QueueFixture`), with the composer's "Up next" state
/// in the test's hands: seed hover, the editor, a drag, or Undo rows through `state`.
@MainActor
final class QueueThreadFixture {
    let store = NativeThreadStore()
    let host: QueueFixture
    let state = QueueStackState()
    let commands = ThreadCommandCenter()

    init(_ snapshot: NativeThreadSnapshot, queue: [NativeQueuedMessage] = [], draft: String = "") {
        host = QueueFixture(snapshot)
        host.change(queue)
        store.draft = draft
    }

    var request: NativeThreadStore.Request { { [host] value in host.answer(value) } }

    /// Header over thread, the way the workspace composes a native agent. `inspect` wires the
    /// subagent inspector, so the tray shows.
    func thread(title: String = "Add refund events", inspect: Bool = false) -> some View {
        VStack(spacing: 0) {
            ThreadHeader(store: store, project: "payments", title: title)
            ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "preview",
                       agentName: "Add refund events", workingDirectory: "~/Developer/payments", inspectSubagent: inspect ? { _ in } : nil,
                       review: { _ in }, queueState: state)
        }
        .environment(\.threadCommands, commands)
    }

    /// The stack alone, fed by its own store.
    func stack() -> some View {
        QueueStackHost(state: state, store: store, running: host.snapshot.running)
            .task { [store, request] in await store.run(request: request) }
    }

    /// The queued message `index` in the host's queue.
    func id(_ index: Int) -> UUID { host.queue[index].id }
}

/// `QueueStackView` with the focus state it needs.
struct QueueStackHost: View {
    let state: QueueStackState
    let store: NativeThreadStore
    let running: Bool
    @FocusState private var focused: String?

    var body: some View {
        QueueStackView(state: state, store: store, running: running, animated: false, focusedRow: $focused, focusComposer: {})
            .onChange(of: store.queue, initial: true) { _, queue in state.update(queue, images: store.queuedImages) }
    }
}

enum Threads {
    private static func decode(_ json: String) -> NativeThreadSnapshot {
        try! JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(json.utf8))
    }

    /// The idle thread with the turn its host recorded: "Edited 3 files" with Undo.
    static var idle: NativeThreadSnapshot {
        var snapshot = idleMessages
        let prompt: Double = 1_758_830_400_000
        snapshot.messages[0].timestamp = prompt
        snapshot.turnChanges = [ChangesTurn(
            messageTimestamp: prompt, prompt: "Check the native desktop presentation", startedAt: prompt, endedAt: prompt + 130_000,
            state: .ready,
            files: [ChangesFile(path: "Sources/ShepherdApp/DesktopNativeThreadView.swift", status: .modified, added: 58, removed: 41),
                    ChangesFile(path: "App/iOS/ThreadView.swift", status: .modified, added: 0, removed: 4),
                    ChangesFile(path: "Tests/ShepherdAppTests/NativePresentationTests.swift", status: .modified, added: 9, removed: 1)],
            added: 67, removed: 46, canUndo: true)]
        return snapshot
    }

    /// A finished conversation: thinking, Markdown with code, and one of each common tool row.
    private static var idleMessages: NativeThreadSnapshot {
        decode(#"""
        {"piSessionID":"fixture","generation":"g","revision":1,"running":false,"model":"anthropic/claude-opus-4-5","thinking":"high",
         "supportedActions":["send","abort","answer","setModel","setThinking","sendImages"],"dialogsSupported":true,"dialogs":[],
         "commands":[{"name":"fix-tests","description":"Fix failing tests","source":"prompt","arguments":"[suite]"},{"name":"review","description":"Review the working tree","source":"prompt"},{"name":"session-name","description":"Set or clear session name","source":"extension"}],
         "messages":[
          {"entryID":"u","role":"user","blocks":[{"kind":"text","text":"Check the native desktop presentation without starting a second pi process."}],"truncated":false},
          {"entryID":"a","role":"assistant","blocks":[{"kind":"thinking","text":"Check focus and exact dialog values."},{"kind":"text","text":"**The same agent is still running.** This is a native transcript, not parsed terminal output.\n\n```swift\nlet mode = presentation.isNative(agent.id)\n```"}],"truncated":false},
          {"entryID":"t1","role":"toolResult","toolName":"read","toolCallID":"c1","status":"complete","argumentsText":"{\"path\":\"Sources/ShepherdApp/ThreadView.swift\",\"offset\":237,\"limit\":160}","blocks":[{"kind":"text","text":"struct ThreadView: View {\n    @ObservedObject var store: NativeThreadStore\n}"}],"truncated":false},
          {"entryID":"t2","role":"toolResult","toolName":"edit","toolCallID":"c2","status":"complete","argumentsText":"{\"path\":\"App/iOS/ThreadView.swift\",\"edits\":[{\"oldText\":\"a\\nb\\nc\\nd\",\"newText\":\"a\"}]}","blocks":[{"kind":"text","text":"Successfully replaced 1 block(s) in App/iOS/ThreadView.swift."}],"truncated":false},
          {"entryID":"t3","role":"toolResult","toolName":"grep","toolCallID":"c3","status":"complete","argumentsText":"{\"pattern\":\"speakerLabel\",\"path\":\"Sources/\"}","blocks":[{"kind":"text","text":"Sources/A.swift:12: speakerLabel\nSources/B.swift:40: speakerLabel\nSources/C.swift:7: speakerLabel"}],"truncated":false},
          {"entryID":"t4","role":"toolResult","toolName":"bash","toolCallID":"c4","status":"complete","argumentsText":"{\"command\":\"swift test --filter toolPreviewPrefersActionAndFallsBackToSavedOutput\"}","blocks":[{"kind":"text","text":"Build complete! (10.20 sec)\n1 test passed"}],"truncated":false},
          {"entryID":"t5","role":"toolResult","toolName":"bash","toolCallID":"c5","status":"complete","isError":true,"argumentsText":"{\"command\":\"swift test --filter NativePresentationTests\"}","blocks":[{"kind":"text","text":"error: cannot find 'MobileTokens' in scope\n  --> App/iOS/ThreadView.swift:41:27\n\nCommand exited with code 1"}],"truncated":false},
          {"entryID":"a2","role":"assistant","blocks":[{"kind":"text","text":"Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation."}],"truncated":false}],
         "widgets":[{"namespace":"fixture.build","key":"status","kind":"status","title":"Build status","text":"Focused checks passed"}],
         "provisional":[],"clipped":false,
         "stats":{"contextTokens":60000,"contextWindow":200000,"contextPercent":30,"totalTokens":1600000}}
        """#)
    }

    /// Mid-turn: a bash call running and the reply streaming.
    static var running: NativeThreadSnapshot {
        var snapshot = idle
        snapshot.running = true
        snapshot.revision = 2
        snapshot.provisional = [
            NativeThreadMessage(entryID: "provisional:tool:c6", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c6",
                                argumentsText: "{\"command\":\"xcodebuild -scheme 'Shepherd (Dev)' build\"}", status: "running", truncated: false),
        ]
        return snapshot
    }

    /// pi asking the user to choose.
    static var question: NativeThreadSnapshot {
        var snapshot = running
        snapshot.dialogs = [NativeThreadDialog(id: "choose", kind: .select, title: "Choose the deployment target",
                                               options: ["Local scratch only", "Staging", "Other / custom answer"])]
        return snapshot
    }

    /// A new agent: nothing said yet.
    static var empty: NativeThreadSnapshot {
        var snapshot = idle
        snapshot.messages = []
        snapshot.widgets = nil
        snapshot.stats = nil
        return snapshot
    }

    static let boardNow = Date(timeIntervalSince1970: 10_000)
    /// Shifts the board's timestamps so durations read as drawn relative to now.
    private static func retimed(_ runs: [ChildRun]) -> [ChildRun] {
        let shift = Date().timeIntervalSince1970 * 1000 - boardNow.timeIntervalSince1970 * 1000
        return runs.map { run in
            var run = run
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            run.lastActivity?.at += shift
            return run
        }
    }

    /// Four runs, one in each state the cards draw: running, needs you, done, failed.
    static var liveRuns: [ChildRun] {
        let now = boardNow.timeIntervalSince1970 * 1000
        return retimed([
            ChildRun(runID: "native-worker", label: "worker: restyle", state: "running", startedAt: now - (37 * 60 + 21) * 1000, currentTool: "edit",
                     needsAttention: false,
                     role: "worker", model: "anthropic/claude-opus-4-5", thinking: "high", context: "background", step: ChildStep(index: 1, total: 1),
                     turns: 78, toolCalls: 82, tokens: 922_000, contextPercent: 62,
                     lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/ShepherdRemote/NativeThreadPresentation.swift",
                                                 at: now - 4000),
                     toolCallID: "spawn-worker", task: "Restyle the desktop native thread view to match the spec; system fonts at spec sizes.", sessionFile: "/tmp/worker.jsonl",
                     files: [ChildFileChange(path: "Sources/ShepherdRemote/NativeThreadPresentation.swift", added: 31, removed: 4)]),
            ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: now - 30 * 60_000, needsAttention: true,
                     attentionText: "Two token names collide", role: "reviewer", model: "anthropic/claude-sonnet-4-5", context: "async", turns: 3, tokens: 40_000,
                     lastActivity: ChildActivity(tool: "shepherd_parent_message", at: now - 130_000),
                     question: ChildQuestion(text: "Two token names collide with existing `Tokens.textSecondary`. Rename the new token names, or replace the old ones everywhere?",
                                             options: ["Replace everywhere", "Rename new ones"]), toolCallID: "spawn-reviewer"),
            ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: now - 600_000, endedAt: now - 600_000 + (4 * 60 + 2) * 1000, needsAttention: false,
                     role: "tests", model: "anthropic/claude-haiku-4-5", context: "async", turns: 9, toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), toolCallID: "spawn-tests",
                     output: "Added 6 presentation tests · 14 pass. All 14 pass on macOS and iOS simulators."),
            ChildRun(runID: "native-docs", label: "docs: write", state: "failed", startedAt: now - 900_000, endedAt: now - 100_000, needsAttention: false,
                     role: "docs", turns: 41, exitReason: "exit 1 · context limit reached after 41 turns", toolCallID: "spawn-docs"),
        ])
    }

    /// The same group once every run finished.
    static var doneRuns: [ChildRun] {
        let t0 = boardNow.timeIntervalSince1970 * 1000 - 45 * 60_000
        return retimed([
            ChildRun(runID: "native-worker", label: "worker: restyle", state: "complete", startedAt: t0, endedAt: t0 + 41 * 60_000, role: "worker",
                     model: "anthropic/claude-opus-4-5", context: "background", turns: 78, toolCalls: 118, tokens: 922_000,
                     result: ChildResultSummary(files: 5, added: 190, removed: 58, tools: 118, tokens: 922_000), toolCallID: "spawn-worker",
                     task: "Restyle the desktop native thread view.", output: "Restyled thread, sidebar, composer and iOS to the spec.",
                     summary: "Restyled thread, sidebar, composer and iOS to the spec.", sessionID: "child-worker", cwd: "/tmp"),
            ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "complete", startedAt: t0 + 60_000, endedAt: t0 + 13 * 60_000, role: "reviewer",
                     model: "anthropic/claude-sonnet-4-5", context: "async", turns: 6, toolCalls: 24, tokens: 460_000,
                     result: ChildResultSummary(files: 0, added: 32, removed: 3, tools: 24, tokens: 460_000), toolCallID: "spawn-reviewer",
                     task: "Check each step against the spec.", output: "2 spec deviations fixed · you chose replace everywhere.",
                     summary: "2 spec deviations fixed · you chose replace everywhere.", sessionID: "child-reviewer", cwd: "/tmp"),
            ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: t0 + 41 * 60_000, endedAt: t0 + 45 * 60_000, role: "tests",
                     model: "anthropic/claude-haiku-4-5", context: "async", turns: 11, toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), toolCallID: "spawn-tests",
                     task: "Add presentation tests and run the suites.", output: "Added 6 presentation tests · 14 pass.",
                     sessionFile: "/tmp/tests.jsonl", summary: "Added 6 presentation tests · 14 pass.", sessionID: "child-tests", cwd: "/tmp"),
        ])
    }

    /// A parent that split its task into three subagents; `runs` fill the cards or the ledger.
    static func subagents(_ runs: [ChildRun], running: Bool) -> NativeThreadSnapshot {
        func spawn(_ id: String, _ role: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "{\"id\":\"native-\(role)\"}")],
                                toolName: "shepherd_child_start", toolCallID: id, argumentsText: "{\"task\":\"\(role)\",\"role\":\"\(role)\"}", status: "complete")
        }
        return NativeThreadSnapshot(
            piSessionID: "fixture", generation: "g", revision: 1, running: running, model: "anthropic/claude-opus-4-5", thinking: "high",
            supportedActions: ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents"], dialogsSupported: true, dialogs: [],
            messages: [
                NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Restyle Shepherd's native UI to match the design spec. Split it up if that's faster.")]),
                NativeThreadMessage(entryID: "a", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Splitting into three: a worker for the restyle, a reviewer that checks each step against the spec, and a tests run in parallel.")]),
                spawn("spawn-worker", "worker"), spawn("spawn-reviewer", "reviewer"), spawn("spawn-tests", "tests"),
            ] + (running ? [
                // The turn waits on them: that call runs, so the thread's own tail stays still and
                // only the tray moves (Subagents, SubagentsQueue: no "Thinking…").
                NativeThreadMessage(entryID: "t-wait", role: "toolResult", blocks: [], toolName: "shepherd_child_wait",
                                    toolCallID: "wait", argumentsText: "{}", status: "running"),
            ] : [
                NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "All three handed off. Integrated the worker's restyle with the reviewer's two fixes; the test suite is green on both platforms. The branch is ready for the review pane whenever you want to look.")],
                                    timestamp: (runs.compactMap(\.endedAt).max() ?? 0) + 60_000),
            ]),
            provisional: [], clipped: false, runtime: "rpc",
            stats: NativeThreadStats(contextTokens: 60_000, contextWindow: 200_000, contextPercent: 30, totalTokens: 1_600_000),
            subagents: runs)
    }

    /// The worker's transcript, as the inspector pages it: a session file holds only finished
    /// calls, so the call in flight is the run's own (its last line).
    static var workerTranscript: NativeSubagentTranscript {
        func tool(_ id: String, _ name: String, _ args: String, _ output: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "c:\(id)", role: "toolResult", blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                                toolName: name, toolCallID: id, argumentsText: args, status: "complete", isError: false)
        }
        return NativeSubagentTranscript(runID: "native-worker", messages: [
            NativeThreadMessage(entryID: "c:a1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Tokens landed. Moving the tool-row derivations into a shared presentation file.")]),
            tool("r1", "read", #"{"path":"Sources/ShepherdApp/Thread/ThreadView.swift","offset":1,"limit":420}"#, Array(repeating: "x", count: 40).joined(separator: "\n")),
            tool("e1", "edit", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift","edits":[{"oldText":"a\nb","newText":"a\nB\nc"}]}"#, "Successfully replaced 1 block(s)"),
        ], olderCursor: "c:a1", earlierCount: 72)
    }

    /// The finished tests run's whole transcript: its task, the work, a steer from the parent,
    /// and one from the user.
    static var testsTranscript: NativeSubagentTranscript {
        let t0 = Date().timeIntervalSince1970 * 1000 - 8 * 60_000
        func tool(_ id: String, _ name: String, _ args: String, _ output: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "t:\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: output)],
                                toolName: name, toolCallID: id, argumentsText: args, status: "complete", isError: false)
        }
        return NativeSubagentTranscript(runID: "native-tests", messages: [
            NativeThreadMessage(entryID: "t:u1", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Add presentation tests for the new tool-row derivations. Don't touch app code.")], timestamp: t0),
            NativeThreadMessage(entryID: "t:a1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Reading the presentation file first to see which derivations are pure and testable.")]),
            tool("r1", "read", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, "public func nativeToolPreview"),
            tool("e1", "edit", #"{"path":"Tests/ShepherdRemoteUnitTests/NativePresentationTests.swift","edits":[{"oldText":"a","newText":"a\nb\nc"}]}"#, "Successfully replaced 1 block(s)"),
            tool("b1", "bash", #"{"command":"swift test --filter NativePresentationTests"}"#, "Test run with 14 tests passed"),
            NativeThreadMessage(entryID: "t:u2", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Run the iOS simulator variant too.")], timestamp: t0 + 3 * 60_000),
            NativeThreadMessage(entryID: "t:a2", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Running them on the iOS simulator.")]),
            NativeThreadMessage(entryID: "t:u3", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Include the iPad simulator.")], timestamp: t0 + 4 * 60_000, origin: .user),
            NativeThreadMessage(entryID: "t:a3", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "All 14 pass on macOS, the iPhone and the iPad simulators.")]),
        ])
    }
}

// MARK: Review

enum Reviews {
    static let diff = """
    diff --git a/Sources/ShepherdApp/SidebarView.swift b/Sources/ShepherdApp/SidebarView.swift
    index 1111111..2222222 100644
    --- a/Sources/ShepherdApp/SidebarView.swift
    +++ b/Sources/ShepherdApp/SidebarView.swift
    @@ -40,7 +40,8 @@ struct SidebarView: View {
         var body: some View {
             ScrollView {
    -            LazyVStack(spacing: 0) {
    +            LazyVStack(alignment: .leading, spacing: 0) {
    +                header
                     ForEach(groups) { group in
                         SpaceSection(vm: vm, space: group.space)
                     }
    diff --git a/Sources/ShepherdApp/SidebarHeader.swift b/Sources/ShepherdApp/SidebarHeader.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/Sources/ShepherdApp/SidebarHeader.swift
    @@ -0,0 +1,6 @@
    +import SwiftUI
    +
    +struct SidebarHeader: View {
    +    var body: some View {
    +        Text("THIS MAC").font(.caption)
    +    }
    +}
    """

    @MainActor
    static func session() -> ReviewSession {
        let files = GitDiff.parse(diff)
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/Shepherd", reference: nil)
        session.files = files
        session.isLoading = false
        if let file = files.first, let line = file.hunks.first?.lines.first(where: { $0.kind == .added }) {
            session.comments = [ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath, lineNumber: line.newLine ?? 0,
                                              marker: "+", content: line.text, text: "Keep the header out of the lazy stack; it re-renders per row.")]
        }
        session.summary = "Close — one structural note."
        return session
    }

    static let actions = ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}, revert: { _, _ in }, open: { _ in })
}

// MARK: Your pi

/// Settings ▸ Pi's and the first launch's views of a user's own pi, as fixtures (the PiAuthStates
/// boards' data: fake names and masks, never a real value).
enum PreviewYourPi {
    typealias Login = YourPiSurvey.Login

    /// What the first copy brought over as files: instructions, skills, prompts, a theme, and
    /// four extensions (off, on, failed to load, off).
    static let copies: [YourPiCopy] = [
        YourPiCopy(kind: .instructions, name: "AGENTS.md", source: "/Users/you/.pi/agent/AGENTS.md", destination: "AGENTS.md"),
        YourPiCopy(kind: .skills, name: "pdf", source: "/Users/you/.pi/agent/skills/pdf", destination: "skills/pdf"),
        YourPiCopy(kind: .skills, name: "release", source: "/Users/you/team-skills/release", destination: "skills/release"),
        YourPiCopy(kind: .prompts, name: "review", source: "/Users/you/.pi/agent/prompts/review.md", destination: "prompts/review.md"),
        YourPiCopy(kind: .prompts, name: "release-notes", source: "/Users/you/.pi/agent/prompts/release-notes.md",
                   destination: "prompts/release-notes.md"),
        YourPiCopy(kind: .prompts, name: "triage", source: "/Users/you/.pi/agent/prompts/triage.md", destination: "prompts/triage.md"),
        YourPiCopy(kind: .themes, name: "harbor", source: "/Users/you/.pi/agent/themes/harbor.json", destination: "themes/harbor.json"),
        YourPiCopy(kind: .extensions, name: "pr-review", source: "/Users/you/.pi/agent/extensions/pr-review.ts",
                   destination: "your-extensions/files/pr-review.ts", entries: [""]),
        YourPiCopy(kind: .extensions, name: "notify-slack", source: "/Users/you/.pi/agent/extensions/notify-slack",
                   destination: "your-extensions/files/notify-slack", entries: ["index.ts"]),
        YourPiCopy(kind: .extensions, name: "web-search", source: "/Users/you/.pi/agent/extensions/web-search",
                   destination: "your-extensions/files/web-search", entries: ["index.ts"]),
        YourPiCopy(kind: .extensions, name: "git-guard", source: "/Users/you/.pi/agent/extensions/git-guard.ts",
                   destination: "your-extensions/files/git-guard.ts", entries: [""]),
    ]

    /// After the first copy, as SettingsPiSignIn and SettingsPiFromPi draw it: subscriptions signed
    /// in and not, keys copied, by variable and by command, one from the environment, two custom
    /// providers, and the files in `copies`.
    static let imported: YourPiSurvey = {
        var survey = YourPiSurvey(folder: "/Users/you/.pi/agent")
        survey.copied = true
        survey.copiedAt = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date())
        survey.logins = [
            Login(provider: "anthropic", shepherd: .subscription, yours: .subscription),
            Login(provider: "deepseek", shepherd: .apiKey(.environment(["DEEPSEEK_API_KEY"]))),
            Login(provider: "github-copilot", shepherd: .subscription),
            Login(provider: "kimi-coding", shepherd: .subscription, yours: .subscription),
            Login(provider: "openai", shepherd: .apiKey(.literal), yours: .apiKey(.literal)),
            Login(provider: "openai-codex", shepherd: .subscription, yours: .subscription),
            Login(provider: "openrouter", environment: ["OPENROUTER_API_KEY"]),
        ]
        survey.keys = ["openai": PiKeyDisplay(masked: "sk-proj-••••3kQz"), "deepseek": PiKeyDisplay(variables: ["DEEPSEEK_API_KEY"]),
                       "northwind-gateway": PiKeyDisplay(runsCommand: true)]
        survey.yourKeys = ["openai": PiKeyDisplay(masked: "sk-proj-••••3kQz")]
        survey.copiedLogins = ["anthropic", "openai", "kimi-coding"]
        survey.customProviders = ["northwind-gateway", "ollama"]
        survey.shepherdCustomProviders = ["northwind-gateway", "ollama"]
        survey.customProviderDetails = [PiCustomProvider(id: "northwind-gateway", key: PiKeyDisplay(command: "op read op://Dev/northwind/api-key")),
                                        PiCustomProvider(id: "ollama", baseURL: "http://localhost:11434")]
        survey.defaultModel = "openai-codex/gpt-5.3-codex"
        survey.shepherdDefaultModel = "anthropic/claude-opus"
        survey.trustedFolders = 4
        survey.trustedFolderPaths = ["/Users/you/code/shepherd", "/Users/you/code/billing", "/Users/you/code/site", "/Users/you/code/notes"]
        survey.shepherdTrustedFolders = 4
        survey.freshness = ["login:anthropic": .sameAsYourPi, "login:openai-codex": .newerInYourPi, "login:kimi-coding": .changedHere,
                            "login:openai": .sameAsYourPi, "customProviders": .sameAsYourPi, "defaultModel": .newerInYourPi,
                            "trust": .sameAsYourPi]
        survey.yourSignInsChanged = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24))
        survey.copies = copies
        survey.instructionLines = 38
        survey.extensions = [
            YourPiExtensionRow(copy: copies[7], summary: "Adds a /pr-review command that checks the diff against your repo’s rules."),
            YourPiExtensionRow(copy: copies[8], on: true, summary: "Posts to Slack when an agent finishes or needs you."),
            {
                var row = YourPiExtensionRow(copy: copies[9], on: true, failure: "Cannot find module 'turndown' · web-search/index.ts:4",
                                             summary: "A web_search tool backed by your Brave API key.")
                row.failureLines = ["Failed to load extension \"web-search/index.ts\": Cannot find module 'turndown'"]
                return row
            }(),
            YourPiExtensionRow(copy: copies[10], summary: "Blocks force-pushes and git reset --hard."),
        ]
        return survey
    }()

    /// A new user: no pi of theirs, nothing in the environment, not signed in.
    static let none: YourPiSurvey = {
        var survey = YourPiSurvey()
        survey.copied = true
        return survey
    }()

    /// The first copy from `imported`, as the sheet's summary shows it.
    static let report: YourPiImportReport = {
        var report = YourPiImportReport()
        report.first = true
        report.from = "/Users/you/.pi/agent"
        report.logins = [PiLogin(provider: "anthropic", kind: .subscription), PiLogin(provider: "openai-codex", kind: .subscription),
                         PiLogin(provider: "kimi-coding", kind: .subscription), PiLogin(provider: "openai", kind: .apiKey(.literal)),
                         PiLogin(provider: "openrouter", kind: .apiKey(.environment(["OPENROUTER_API_KEY"])))]
        report.customProviders = ["northwind-gateway", "ollama"]
        report.copied = copies + (0..<10).map { YourPiCopy(kind: .skills, name: "s\($0)", source: "/s\($0)", destination: "skills/s\($0)") }
            + ["explain", "tidy"].map { YourPiCopy(kind: .prompts, name: $0, source: "/\($0).md", destination: "prompts/\($0).md") }
        report.defaultModel = "anthropic/claude-opus"
        report.trustedFolders = 4
        return report
    }()

    static let allDone = Dictionary(uniqueKeysWithValues: YourPiImportStep.allCases.map { ($0, PiImportSheetState.StepState.done) })

    /// PiImportProgress: logins, keys and providers over, the default model under way.
    static let importProgress: PiImportSheetState = {
        var sheet = PiImportSheetState(from: report.from)
        sheet.report = report
        sheet.steps = [.logins: .done, .apiKeys: .done, .customProviders: .done, .defaultModel: .running]
        return sheet
    }()

    /// PiImportDone.
    static let importDone: PiImportSheetState = {
        var sheet = importProgress
        sheet.steps = allDone
        sheet.stage = .done
        sheet.survey = imported
        return sheet
    }()

    /// PiImportMissing: two providers the agents use that nothing covers, one signed in since.
    static let importMissing: PiImportSheetState = {
        var sheet = importDone
        sheet.stage = .missing
        sheet.report.logins = [PiLogin(provider: "anthropic", kind: .subscription), PiLogin(provider: "openai", kind: .apiKey(.literal)),
                               PiLogin(provider: "openrouter", kind: .apiKey(.environment(["OPENROUTER_API_KEY"])))]
        sheet.missing = [.init(id: "openai-codex", detail: "Your pi’s sign-in couldn’t be copied"),
                         .init(id: "kimi-coding", detail: "Your pi isn’t signed in to it")]
        var survey = imported
        survey.logins.removeAll { $0.provider == "openai-codex" || $0.provider == "kimi-coding" }
        sheet.survey = survey
        return sheet
    }()

    /// PiImportNew: no pi on this Mac.
    static let importNew: PiImportSheetState = {
        var sheet = PiImportSheetState(from: nil)
        sheet.stage = .newUser
        sheet.survey = none
        return sheet
    }()

    /// PiImportFailed: auth.json isn't valid JSON; everything else came over.
    static let importFailed: PiImportSheetState = {
        var sheet = importDone
        sheet.stage = .failed
        sheet.report.logins = []
        sheet.report.signInsUnreadable = ("/Users/you/.pi/agent/auth.json", "Unexpected character around line 31, column 5.")
        sheet.steps[.logins] = .failed
        return sheet
    }()
}
