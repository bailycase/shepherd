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

    init(modelCatalog: @escaping SessionServer.ModelCatalog = { ScratchServer.standInModels }) throws {
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
            checkoutReader: nil
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
               branch: String? = nil) async throws -> (Agent, ShepherdCore.Tab) {
        var session: SessionID?
        if live {
            session = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: StubPi.command, runtime: .rpc)).id
        }
        let id = AgentID()
        let pane = LeafPane(sessionID: session, cwd: space.path, agentID: id)
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
                listModels: (() async -> ModelCatalog)? = nil) -> some View {
        VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: title)
            ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "preview",
                       agentName: "Investigate", workingDirectory: workingDirectory, inspectSubagent: { _ in },
                       inspectedRunID: inspected, review: { _ in },
                       turnActions: TurnChangesActions(review: { _, _ in }, undo: { _ in nil }, redo: { _ in nil }), listModels: listModels)
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
         "commands":[{"name":"fix-tests","description":"Fix failing tests","source":"prompt"},{"name":"review","description":"Review the working tree","source":"prompt"},{"name":"session-name","description":"Set or clear session name","source":"extension"}],
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
