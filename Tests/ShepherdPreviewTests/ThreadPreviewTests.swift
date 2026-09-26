import AppKit
import Foundation
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The thread and composer surfaces of the NWThread, "Activity line states", Running, Main and
/// NWComposer boards, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
@Suite("Thread previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ThreadPreviewTests {
    /// Long enough for a one-shot motion a test starts to come fully to rest: a spring reads as
    /// done at its anchor (240ms at most) and settles by about 1.7× it (DESIGN.md › Motion).
    static let motionAtRest: TimeInterval = 0.45

    private func render(_ surface: String, _ snapshot: NativeThreadSnapshot, size: CGSize = CGSize(width: 1180, height: 900),
                        ready: @escaping @MainActor () -> Bool = { true }) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty && ready() }) {
            fixture.thread()
        }
    }

    /// Main board: explored / edited / tests-and-build lines and the changes card, at rest (the
    /// footer and the prompt's time wait for the pointer).
    @Test func threadActivityIdle() async throws {
        try await render("thread-activity-idle", ActivityThreads.idle)
    }

    /// The Main board's thread with the pointer resting on the reply: its footer shows (copy,
    /// retry, time · duration · tool calls), while the prompt above keeps its time hidden.
    @Test func threadTurnHovered() async throws {
        let fixture = ThreadFixture(ActivityThreads.idle)
        defer { fixture.store.stop() }
        let store = fixture.store
        let size = CGSize(width: 1180, height: 760)
        try await Preview.render("thread-turn-hovered", size: size, ready: { store.ready && !store.rows.isEmpty }) {
            HoveredReplyThread(store: store)
                .frame(width: size.width, height: size.height)
                // No thread view drives this store here; feed it its fixture directly.
                .task { await store.run(request: fixture.request) }
        }
    }

    /// A thread scrolled up from its tail: the reply runs under the fade the composer lays on
    /// the thread, and "Jump to latest" sits over that fade, above the card, drawn crisply.
    @Test func threadJumpPill() async throws {
        let fixture = ThreadFixture(ActivityThreads.idle)
        defer { fixture.store.stop() }
        let store = fixture.store
        let size = CGSize(width: 1180, height: 700)
        try await Preview.render("thread-jump-pill", size: size, ready: { store.ready && !store.rows.isEmpty }) {
            DetachedThread(store: store)
                .frame(width: size.width, height: size.height)
                // No thread view drives this store here; feed it its fixture directly.
                .task { await store.run(request: fixture.request) }
        }
    }

    /// A long stretch of work (asking, exploring, editing, commands that failed along the way):
    /// one quiet line per burst between the prose around it, the failures red and visible.
    @Test func threadActivityLong() async throws {
        try await render("thread-activity-long", ActivityThreads.long)
    }

    /// Running board, LiveText's "A tool is running": a finished commit line, then the live
    /// push, its verb and command shimmering beside its clock, with its last output lines.
    /// Nothing under it.
    @Test func threadActivityRunning() async throws {
        try await render("thread-activity-running", ActivityThreads.running(.call))
    }

    /// The model thinking at the tail: "› Thinking…" shimmering, the thread's one live line.
    @Test func threadActivityThinking() async throws {
        try await render("thread-activity-thinking", ActivityThreads.running(.thinking))
    }

    /// LiveText's "Between tools": the commit finished and nothing streams yet, so the turn ends
    /// in "› Thinking…".
    @Test func threadActivityBetweenTools() async throws {
        try await render("thread-activity-between-tools", ActivityThreads.running(.between))
    }

    /// Thinking the model kept back: a plain "Thought for 10s" line with no chevron, above the
    /// disclosure of thinking it shared.
    @Test func threadThinkingUnshared() async throws {
        try await render("thread-thinking-unshared", ActivityThreads.unsharedThinking, size: CGSize(width: 1180, height: 640))
    }

    /// A new agent from its first frame, while its pi boots: the framed empty state and a complete
    /// composer, with nothing said about pi yet (a normal start is over before it would be).
    @Test func threadStartingQuiet() async throws {
        let fixture = ThreadFixture(Threads.empty)
        fixture.starting = true
        defer { fixture.store.stop() }
        fixture.store.preview(PiSessionPreview.empty(sessionID: "fixture", model: "anthropic/claude-opus-4-5", thinking: "high"))
        try await Preview.render("thread-starting-quiet", size: CGSize(width: 1180, height: 700), ready: {
            fixture.store.starting
        }) {
            fixture.thread(title: "New agent").environment(\.threadStartingDelay, .seconds(3600))
        }
    }

    /// A new agent created with a prompt, while its pi boots: the prompt shows at once as the
    /// pending row the host's first snapshot will carry, not the empty state.
    @Test func threadStartingWithItsPrompt() async throws {
        let fixture = ThreadFixture(Threads.empty)
        fixture.starting = true
        defer { fixture.store.stop() }
        let prompt = try #require(OpeningPrompt("Do these steps in order. 1) Read tally.py and its tests. 2) Fix mean([]) so it returns 0. 3) Reply with what you changed.",
                                                agentID: AgentID()))
        fixture.store.preview(prompt.preview(PiSessionPreview.empty(sessionID: "fixture", model: "anthropic/claude-opus-4-5", thinking: "high")))
        try await Preview.render("thread-starting-prompt", size: CGSize(width: 1180, height: 700), ready: {
            fixture.store.starting && !fixture.store.rows.isEmpty
        }) {
            fixture.thread(title: "Do these steps in order…").environment(\.threadStartingDelay, .seconds(3600))
        }
    }

    /// The same agent once its pi has kept it waiting past the delay: "Starting…" beside Send,
    /// no banner, and Send offered for a typed draft.
    @Test func threadStarting() async throws {
        let fixture = ThreadFixture(Threads.empty)
        fixture.starting = true
        defer { fixture.store.stop() }
        fixture.store.preview(PiSessionPreview.empty(sessionID: "fixture", model: "anthropic/claude-opus-4-5", thinking: "high"))
        fixture.store.draft = "Fix the login redirect"
        try await Preview.render("thread-starting", size: CGSize(width: 1180, height: 700), ready: {
            fixture.store.starting
        }) {
            fixture.thread(title: "New agent").environment(\.threadStartingDelay, .zero)
        }
    }

    /// A message sent while pi boots waits for it behind the composer's spinner.
    @Test func threadStartingSend() async throws {
        let fixture = ThreadFixture(Threads.empty)
        fixture.starting = true
        defer { fixture.store.stop() }
        fixture.store.preview(PiSessionPreview.empty(sessionID: "fixture", model: "anthropic/claude-opus-4-5", thinking: "high"))
        let store = fixture.store
        final class Once { var sent = false }
        let once = Once()
        try await Preview.render("thread-starting-send", size: CGSize(width: 1180, height: 700), ready: {
            guard store.starting else { return false }
            if !once.sent {
                once.sent = true
                store.draft = "Fix the login redirect"
                Task { await store.send() }
            }
            return store.busy
        }) {
            // Each appearance renders in a new window, with the send waiting in each.
            let _ = once.sent = false
            fixture.thread(title: "New agent").environment(\.threadStartingDelay, .zero)
        }
    }

    /// A relaunched agent's thread read from pi's session file while its pi boots: the history
    /// as pi will show it, and "Starting…" beside Send once pi keeps it waiting.
    @Test func threadRestoring() async throws {
        let fixture = ThreadFixture(ActivityThreads.idle)
        fixture.starting = true
        defer { fixture.store.stop() }
        var fromDisk = ActivityThreads.idle
        fromDisk.generation = PiSessionPreview.generation
        fromDisk.stats = nil
        fromDisk.commands = nil
        fixture.store.preview(fromDisk)
        try await Preview.render("thread-restoring", size: CGSize(width: 1180, height: 900), ready: {
            fixture.store.starting && fixture.store.previewing && !fixture.store.rows.isEmpty
        }) {
            fixture.thread().environment(\.threadStartingDelay, .zero)
        }
    }

    /// A thread kept from before (a host that relaunched) while its pi starts again: the
    /// transcript stays, and the composer says pi is starting.
    @Test func threadStartingAgain() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.render("thread-starting-again", size: CGSize(width: 1180, height: 900), ready: {
            if store.ready, !fixture.starting {
                fixture.starting = true
                Task { await store.refresh() }
            }
            return store.starting
        }) {
            let _ = fixture.starting = false
            fixture.thread().environment(\.threadStartingDelay, .zero)
        }
    }

    /// Failed test runs stay red; a turn that failed as a whole ends in NWTurnError with Retry.
    @Test func threadActivityFailed() async throws {
        try await render("thread-activity-failed", ActivityThreads.failed)
    }

    /// A turn the user stopped mid-command: the call reads "stopped" in its usual colors, and the
    /// turn ends in a quiet "Stopped" note, not an error with Retry.
    @Test func threadActivityStopped() async throws {
        try await render("thread-activity-stopped", ActivityThreads.stopped, size: CGSize(width: 1180, height: 600))
    }

    /// Prose, lists, inline code, a link, and a highlighted code block.
    @Test func threadProse() async throws {
        // Code blocks color themselves off the main actor: capture once every fence's colors
        // are in.
        let snapshot = ActivityThreads.prose
        let fences = snapshot.messages.flatMap(\.blocks).filter { $0.kind == .text }.flatMap { nativeMarkdownBlocks($0.text) }
            .compactMap { block -> CodeHighlightCache.Key? in
                guard case .code(let code, let language) = block else { return nil }
                return CodeHighlightCache.Key(fence: code, language: language)
            }
        #expect(!fences.isEmpty)
        try await render("thread-prose", snapshot, ready: { fences.allSatisfy { CodeHighlightCache.cached($0) != nil } })
    }

    /// The "Activity line states" board (ToolRows): done lines (the edit expanded into its
    /// calls), a failed line, and a live one; one quiet line per burst, nothing folding them.
    @Test func activityLineStates() async throws {
        let turn = nativeTurnPresentation(ActivityThreads.stateMessages, live: false)
        let bursts = turn.items.flatMap { item -> [NativeActivityBurst] in
            if case .activity(_, let bursts) = item { return bursts }
            return []
        }
        let live = nativeActivityBurst([NativeActivityCall(ActivityThreads.liveBuild)])
        let failed = try #require(bursts.first { $0.state == .failed })
        let size = CGSize(width: 760, height: 520)
        try await Preview.render("activity-line-states", size: size) {
            VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
                Text("DONE").nwSectionLabel()
                ForEach(bursts.filter { $0.state == .done }) { burst in
                    ActivityLineView(burst: burst, review: { _ in }, expanded: burst.kind == .edit)
                }
                Text("FAILED").nwSectionLabel().padding(.top, NW.Space.s)
                ActivityLineView(burst: failed)
                Text("LIVE").nwSectionLabel().padding(.top, NW.Space.s)
                ActivityLineView(burst: live)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// The NWThread board's parts: bubbles (hovered, showing its time, and steered), attachment
    /// chips, thinking open and live, the changes card, a hovered turn's footer and a turn error.
    @Test func threadParts() async throws {
        let changes = NWChangesCard(title: "4 files changed", added: 149, removed: 63, files: [
            NWChangedFile(path: "Sources/ShepherdApp/DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/", name: "DesktopNativeThreadView.swift", status: .modified, added: 58, removed: 41),
            NWChangedFile(path: "Sources/ShepherdApp/ToolRow.swift", directory: "Sources/ShepherdApp/", name: "ToolRow.swift", status: .modified, added: 12, removed: 4),
            NWChangedFile(path: "App/iOS/ThreadView.swift", directory: "App/iOS/", name: "ThreadView.swift", status: .modified, added: 31, removed: 18),
            NWChangedFile(path: "Tests/ShepherdAppTests/ToolPreviewTests.swift", directory: "Tests/ShepherdAppTests/", name: "ToolPreviewTests.swift", status: .added, added: 48, removed: 0),
        ], onReview: {}, onOpen: { _ in })
        let size = CGSize(width: 900, height: 900)
        try await Preview.render("thread-parts", size: size) {
            VStack(alignment: .leading, spacing: 20) {
                NWUserBubble("Restyle the thread view to the spec and split the work however you like.", timestamp: "2:41 PM",
                             revealed: true)
                NWUserBubble("Also bump the tool row height to 28.", timestamp: "2:44 PM", revealed: true, origin: .steered)
                HStack(spacing: NW.Space.s) {
                    NWAttachmentChip("Spec.dc.html") {}
                    NWAttachmentChip("screenshot.png", thumbnail: Image(systemName: "photo"))
                }
                NWThinking("Thought for 6s", text: "The tool summary row is 28pt elsewhere. I’ll keep it a minimum, not a fixed height, so large text sizes still fit.",
                           isExpanded: .constant(true))
                NWThinking("Thought for 4s", text: "Check the labels first.", isExpanded: .constant(false))
                NWThinking("Thought for 10s", text: "", isExpanded: .constant(false), spokenTitle: "Thought for 10 seconds")
                NWThinking.live()
                changes
                NWTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {},
                             revealed: true)
                NWTurnError("Model overloaded — the turn stopped after 6 tool calls.", retry: {})
                    .frame(maxWidth: 440)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// QuestionAsk, QuestionPick and QuestionStates on the Mac: the shared head over the agent's
    /// own question in the composer card (one waiting, then two), the question hidden to its
    /// line, and a subagent's question asking and picked.
    @Test func questionStates() async throws {
        func controls() -> some View {
            Group {
                Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                Button {} label: { HStack(spacing: 6) { Text("claude-opus").font(.nwMono(12)); NWChipChevron() } }.buttonStyle(.nwComposerChip())
                Spacer(minLength: 8)
                NWComposerActionButton(.send, enabled: false) {}
            }
        }
        let select = NativeThreadDialog(id: "handle", kind: .select, title: "How should I handle Horizon’s uncommitted edits?",
                                        options: ["Compare, keep what’s unique, then go through GitHub",
                                                  "Leave Horizon alone and deploy from a clean checkout"])
        let next = NativeThreadDialog(id: "hosts", kind: .select, title: "Which host should get the new Traefik config?",
                                      options: ["build-01", "horizon"])
        let options = [
            NWQuestionDockOption(number: 1, title: "Replace everywhere", detail: "41 call sites move to the spec colors. One PR, bigger diff.",
                                 recommended: true),
            NWQuestionDockOption(number: 2, title: "Rename the new ones", detail: "New names get an nw prefix. Old screens keep the old ones."),
        ]
        let question = "Rename the new token names, or replace `Tokens.textSecondary` everywhere?"
        let size = CGSize(width: 1400, height: 620)
        try await Preview.render("question-states", size: size) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 28) {
                    NWComposer(isFocused: false) {
                        QuestionPanel(dialog: select, enabled: true, answer: { _ in }, hide: {})
                    } controls: { controls() }
                    NWComposer(isFocused: false) {
                        QuestionPanel(dialog: next, count: 2, enabled: true, answer: { _ in }, hide: {})
                    } controls: { controls() }
                    NWComposer(isFocused: false) {
                        NWQuestionHiddenLine(.agent, question: select.title) {}
                    } controls: { controls() }
                }
                .frame(width: 640)
                VStack(alignment: .leading, spacing: 28) {
                    NWSubagentQuestionDock(name: "reviewer", question: question, options: options, answer: { _ in }, hide: {})
                    NWSubagentQuestionDock(name: "reviewer", question: question, options: options, chosen: 1, answer: { _ in }, hide: {})
                }
                .frame(width: 600)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// NWComposer board: idle, focused with text, running, with an attachment; and its menus.
    @Test func composerStates() async throws {
        func controls(stop: Bool = false, enabled: Bool = false) -> some View {
            Group {
                Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                Button {} label: { HStack(spacing: 6) { Text("/").font(.nwMono(12)); Text("commands") } }.buttonStyle(.nwComposerChip())
                Button {} label: { HStack(spacing: 6) { Text("claude-opus").font(.nwMono(12)); NWChipChevron() } }.buttonStyle(.nwComposerChip())
                Button {} label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").font(.system(size: 11, weight: .medium))
                        Text("Thinking")
                        Text("Medium").foregroundStyle(Color.nw.textPrimary).fontWeight(.medium)
                        NWChipChevron()
                    }
                }
                .buttonStyle(.nwComposerChip())
                Spacer(minLength: 8)
                NWComposerActionButton(stop ? .stop : .send, enabled: stop || enabled) {}
            }
        }
        func field(_ text: String, placeholder: Bool) -> some View {
            Text(text).font(.nw(.body)).foregroundStyle(placeholder ? Color.nw.textTertiary : Color.nw.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        let size = CGSize(width: 1320, height: 760)
        try await Preview.render("composer-states", size: size) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 24) {
                    NWComposer(isFocused: false) { field("Follow up, or / for commands…", placeholder: true) } controls: { controls() }
                    NWComposer(isFocused: true) { field("Make the reviewer check dark mode too", placeholder: false) } controls: { controls(enabled: true) }
                    NWComposer(isFocused: false) { field("Follow up, or / for commands…", placeholder: true) } controls: { controls(stop: true) }
                    NWComposer(isFocused: false) {
                        NWAttachmentChip("thread-spacing.png", thumbnail: Image(systemName: "photo")) {}
                    } field: { field("Match the spacing in this screenshot", placeholder: false) } controls: { controls(enabled: true) }
                }
                .frame(width: 600)
                VStack(alignment: .leading, spacing: 24) {
                    NWSlashMenu(commands: Self.slashCommands, total: 23, query: "re", selection: .constant(0)) { _ in }
                    HStack(alignment: .top, spacing: 24) {
                        NWModelPicker(query: .constant(""), sections: Self.boardModels, selection: .constant(0), shortcut: "⇧⌘M",
                                      onChoose: { _ in }, onClose: {})
                        NWThinkingMenu(options: Self.thinkingOptions(["off", "low", "medium", "high"]), current: "medium",
                                       onChoose: { _ in }, onClose: {})
                    }
                }
                .frame(width: NWComposerMetrics.modelPickerWidth + 24 + NWComposerMetrics.thinkingMenuWidth)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}

// MARK: Fixtures

/// A thread's turns laid out in its column the way `ThreadView` lays them out, with the pointer
/// seeded over the last reply.
private struct HoveredReplyThread: View {
    let store: NativeThreadStore

    var body: some View {
        let rows = store.rows
        VStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if row.isUser {
                    UserTurn(messages: row.turn.messages, caption: row.turn.messages.first?.timestamp.map { nativeClockText($0) })
                } else if let presentation = row.presentation {
                    AgentTurn(presentation: presentation, live: row.live, startedAt: row.startedAt, retry: {}, review: { _ in },
                              hover: MessageHover(hovering: index == rows.count - 1))
                }
            }
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, AppLayout.gutter)
        .padding(.top, AppLayout.threadTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.nw.bgWindow)
    }
}

/// The thread's rows run down under the real composer, which shows "Jump to latest" as a
/// detached thread does.
private struct DetachedThread: View {
    let store: NativeThreadStore

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
                ForEach(store.rows) { row in
                    if row.isUser {
                        UserTurn(messages: row.turn.messages, caption: nil)
                    } else if let presentation = row.presentation {
                        AgentTurn(presentation: presentation, live: row.live, startedAt: row.startedAt, retry: {}, review: { _ in },
                                  hover: MessageHover(hovering: false))
                    }
                }
            }
            .frame(maxWidth: AppLayout.threadMaxWidth)
            .padding(.horizontal, AppLayout.gutter)
            // The last reply ends under the card, as a thread scrolled up from its tail does.
            .padding(.bottom, AppLayout.composerFade)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            Composer(store: store, active: true, isFocused: false, agentName: "Investigate", hasTurns: true,
                     gutter: AppLayout.gutter, jumpToLatest: {})
        }
        .background(Color.nw.bgWindow)
    }
}

/// Threads drawn from the boards. Times are relative to now, so durations and live elapsed
/// read as drawn.
@MainActor
enum ActivityThreads {
    static let now = Date().timeIntervalSince1970 * 1000

    static func user(_ id: String, _ text: String, at: Double) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], timestamp: at)
    }

    static func assistant(_ id: String, _ text: String, thinking: String? = nil, seconds: Double? = nil, at: Double? = nil,
                          status: String? = nil) -> NativeThreadMessage {
        var blocks: [NativeThreadBlock] = []
        if let thinking { blocks.append(NativeThreadBlock(kind: .thinking, text: thinking)) }
        if !text.isEmpty { blocks.append(NativeThreadBlock(kind: .text, text: text)) }
        return NativeThreadMessage(entryID: id, role: "assistant", blocks: blocks, status: status, timestamp: at, thinkingSeconds: seconds)
    }

    static func tool(_ id: String, _ name: String, _ args: [String: Any], output: String = "", error: Bool = false,
                     start: Double, end: Double?, status: String = "complete") -> NativeThreadMessage {
        let data = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                                   toolName: name, toolCallID: id, argumentsText: String(data: data, encoding: .utf8), status: status,
                                   isError: error, timestamp: end, startedAt: start)
    }

    /// An edit whose diff reads +added −removed.
    static func edit(_ id: String, _ path: String, added: Int, removed: Int, at: Double) -> NativeThreadMessage {
        let old = (0..<removed).map { "old \(path) \($0)" }.joined(separator: "\n")
        let new = (0..<added).map { "new \(path) \($0)" }.joined(separator: "\n")
        return tool(id, "edit", ["path": path, "edits": [["oldText": old, "newText": new]]],
                    output: "Successfully replaced 1 block(s) in \(path).", start: at, end: at + 300)
    }

    static func snapshot(_ messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [], running: Bool = false) -> NativeThreadSnapshot {
        NativeThreadSnapshot(
            piSessionID: "fixture", generation: "g", revision: 1, running: running, model: "anthropic/claude-opus", thinking: "medium",
            supportedActions: ["send", "abort", "answer", "setModel", "setThinking", "sendImages"], dialogsSupported: true, dialogs: [],
            messages: messages, provisional: provisional, clipped: false, runtime: "rpc",
            stats: NativeThreadStats(contextTokens: 42_000, contextWindow: 200_000, contextPercent: 21, totalTokens: 1_200_000),
            commands: [NativeCommand(name: "review", description: "Open the review pane on working-tree changes", source: "prompt")])
    }

    static let reads = ["Sources/ShepherdApp/DesktopNativeThreadView.swift", "Sources/ShepherdApp/ToolRow.swift", "App/iOS/ThreadView.swift",
                        "Sources/ShepherdRemote/NativeThreadPresentation.swift", "Tests/ShepherdAppTests/NativePresentationTests.swift"]

    /// The Main board's turn.
    static var idleMessages: [NativeThreadMessage] {
        let t0 = now - 10 * 60_000
        let t = t0 + 20_000
        var messages = [
            user("u1", "Remove the visible speaker labels, and make tool rows show something useful — a command or a path — instead of just \"complete\".", at: t0),
            assistant("a1", "I'll finish removing the speaker labels and make tool rows show a useful command or path preview. Slash commands and image support stay separate from this visual change.",
                      thinking: "Where do the labels render? The desktop thread view and the iOS bubble both draw them.", seconds: 4, at: t0 + 5_000),
        ]
        for (index, path) in reads.enumerated() {
            messages.append(tool("r\(index)", "read", ["path": path], output: Array(repeating: "line", count: 120 + index).joined(separator: "\n"),
                                 start: t + Double(index) * 100, end: t + Double(index) * 100 + 80))
        }
        messages.append(tool("g1", "grep", ["pattern": "speakerLabel", "path": "Sources/"], output: "Sources/A.swift:12\nSources/B.swift:40", start: t + 600, end: t + 700))
        messages.append(tool("g2", "grep", ["pattern": "toolRowHeight", "path": "Sources/"], output: "Sources/C.swift:7", start: t + 800, end: t + 900))
        let e = t + 30_000
        messages.append(edit("e1", reads[0], added: 58, removed: 41, at: e))
        messages.append(edit("e2", reads[1], added: 12, removed: 4, at: e + 1_000))
        messages.append(edit("e3", reads[2], added: 31, removed: 18, at: e + 2_000))
        messages.append(tool("w1", "write", ["path": "Tests/ShepherdAppTests/ToolPreviewTests.swift",
                                             "content": (0..<48).map { "line \($0)" }.joined(separator: "\n")],
                             output: "Wrote 48 lines.", start: e + 3_000, end: e + 3_200))
        let b = e + 60_000
        messages.append(tool("b1", "bash", ["command": "swift test --filter ToolPreview"],
                             output: "Building for debugging...\n✔ Test run with 17 tests in 4 suites passed after 3.1 seconds.", start: b, end: b + 20_000))
        messages.append(tool("b2", "bash", ["command": "xcodebuild -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build"],
                             output: "CompileSwift normal arm64 ThreadView.swift\n** BUILD SUCCEEDED **", start: b + 20_000, end: b + 62_000))
        messages.append(assistant("a2", """
            Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation.

            Tool rows now show a command or path preview when available, or the first output line for saved results. The repetitive "complete" label is gone.

            Focused regression test and Mac Dev build passed. Slash commands and image drops are next.
            """, at: t0 + 192_000))
        return messages
    }

    static var idle: NativeThreadSnapshot { snapshot(idleMessages) }

    /// A turn whose model shared some of its thinking: none for the first stretch (timed, a
    /// plain line), some for the second (the disclosure, folding in a blank block).
    static var unsharedThinking: NativeThreadSnapshot {
        let t0 = now - 5 * 60_000
        return snapshot([
            user("u1", "Why does the sidebar jump when an agent finishes?", at: t0),
            assistant("a1", "Looking at how the sidebar orders its rows.", thinking: "", seconds: 10, at: t0 + 11_000),
            tool("r1", "read", ["path": "Sources/ShepherdApp/SidebarView.swift"], output: "line", start: t0 + 12_000, end: t0 + 12_100),
            tool("r2", "read", ["path": "Sources/ShepherdCore/Reorder.swift"], output: "line", start: t0 + 12_200, end: t0 + 12_300),
            assistant("a2", "", thinking: "Finished agents sort by their last activity, so a status change moves the row.", seconds: 4,
                      at: t0 + 17_000),
            tool("g1", "grep", ["pattern": "lastActivity", "path": "Sources/"], output: "Sources/A.swift:12", start: t0 + 17_100, end: t0 + 17_200),
            assistant("a3", "The row moves because finished agents sort by their last activity. Sorting by creation keeps it still.",
                      thinking: " ", at: t0 + 20_000),
        ])
    }

    /// What the Running board's turn is doing at its tail (LiveText's moments).
    enum Tail { case call, thinking, between }

    /// The Running board: the previous turn, the new prompt, a commit, and at the tail a live
    /// push, live thinking, or nothing yet (pi between tools).
    static func running(_ tail: Tail) -> NativeThreadSnapshot {
        let t0 = now - 60_000
        var messages = idleMessages
        messages += [
            user("u2", "Looks good. Commit it and push to main.", at: t0),
            assistant("a3", "Committing the three changed files with a message describing the label removal, then pushing.",
                      thinking: "Three files, one message.", seconds: 2, at: t0 + 3_000),
            tool("c1", "bash", ["command": "git add -A && git commit -m 'Remove speaker labels'"],
                 output: "[main 4f2a9c1] Remove speaker labels\n 3 files changed, 67 insertions(+), 46 deletions(-)", start: t0 + 5_000, end: t0 + 5_400),
        ]
        var provisional: [NativeThreadMessage] = []
        switch tail {
        case .between:
            break
        case .thinking:
            provisional.append(NativeThreadMessage(entryID: "provisional:assistant:9", role: "assistant",
                                                   blocks: [NativeThreadBlock(kind: .thinking, text: "Push, then check CI.")],
                                                   status: "streaming", timestamp: now - 4_000, thinkingSeconds: 4))
        case .call:
            provisional.append(tool("p1", "bash", ["command": "git push origin main"],
                                    output: "Enumerating objects: 14, done.\nCounting objects: 100% (14/14), done.\nWriting objects: 100% (8/8), 2.31 KiB | 2.31 MiB/s\nremote: Resolving deltas: 0% (0/5)",
                                    start: now - 3_000, end: nil, status: "running"))
        }
        return snapshot(messages, provisional: provisional, running: true)
    }

    static let swiftTestFailure = """
        ✘ Test toolRow_XL() failed after 0.2 seconds with 1 issue.
        ✘ Test toolRow_XXL() failed after 0.2 seconds with 1 issue.
        ✘ Test agentRow_AX3() failed after 0.3 seconds with 1 issue.
        ✘ Test run with 20 tests in 3 suites failed after 8.4 seconds with 3 issues.

        Command exited with code 1
        """

    /// Two failed test runs, then the provider gives up.
    static var failed: NativeThreadSnapshot {
        let t0 = now - 5 * 60_000
        let messages = [
            user("u1", "Run the accessibility snapshots and fix whatever drifts.", at: t0),
            assistant("a1", "Running the accessibility snapshots first.", at: t0 + 2_000),
            tool("f1", "bash", ["command": "swift test --filter snapshot_accessibility"], output: swiftTestFailure, error: true,
                 start: t0 + 3_000, end: t0 + 11_400),
            assistant("a2", "Three snapshots drift at XL. Making the row height a minimum rather than fixed.", at: t0 + 20_000),
            edit("e1", "Sources/ShepherdApp/ToolRow.swift", added: 3, removed: 2, at: t0 + 25_000),
            tool("f2", "bash", ["command": "swift test --filter snapshot_accessibilityXL"],
                 output: "error: compile failed\nCommand exited with code 1", error: true, start: t0 + 30_000, end: t0 + 38_400),
            NativeThreadMessage(entryID: "err", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Model overloaded")],
                                status: "error", timestamp: t0 + 40_000),
        ]
        return snapshot(messages)
    }

    /// The user stopped a long command: pi failed the call and ended the run with an error reply,
    /// which the host projects as `aborted`.
    static var stopped: NativeThreadSnapshot {
        let t0 = now - 60_000
        return snapshot([
            user("u1", "Use the bash tool to run `sleep 40`, then reply with exactly: slept", at: t0),
            tool("s1", "bash", ["command": "sleep 40"], output: "Command aborted", error: true, start: t0 + 2_000, end: t0 + 9_500,
                 status: "aborted"),
            NativeThreadMessage(entryID: "stop", role: "assistant", blocks: [], status: "aborted", timestamp: t0 + 9_600),
        ])
    }

    /// The NWThread board's prose sample.
    static var prose: NativeThreadSnapshot {
        let t0 = now - 2 * 60_000
        return snapshot([
            user("u1", "How do tool rows pick what to show?", at: t0),
            assistant("a1", """
                Tool rows now derive a `ToolPreview` once from the call's arguments. Three things changed:

                - Bash rows show the command, truncated at the tail.
                - Read and edit rows show the path, truncated at the head.
                - Saved results fall back to the first output line.

                See [NativeThreadPresentation.swift](https://example.com) for the enum.

                ```swift
                enum ToolPreview {
                  case command(String)
                  case path(String, lines: ClosedRange<Int>?)
                  // first line of saved output
                  case output(String)
                }
                ```
                """, thinking: "They should come from arguments, not output.", seconds: 4, at: t0 + 30_000),
        ])
    }

    /// Calls for the activity-states board: explore, edit, a failed run.
    static var stateMessages: [NativeThreadMessage] {
        let t = now - 60_000
        var messages: [NativeThreadMessage] = []
        for (index, path) in reads.prefix(5).enumerated() {
            messages.append(tool("s\(index)", "read", ["path": path], output: "a\nb", start: t + Double(index) * 100, end: t + Double(index) * 100 + 80))
        }
        messages.append(tool("sg1", "grep", ["pattern": "speakerLabel", "path": "Sources/"], output: "x", start: t + 600, end: t + 700))
        messages.append(tool("sg2", "grep", ["pattern": "gutter", "path": "Sources/"], output: "y", start: t + 800, end: t + 900))
        messages.append(edit("se1", reads[0], added: 58, removed: 41, at: t + 2_000))
        messages.append(edit("se2", reads[2], added: 0, removed: 4, at: t + 3_000))
        messages.append(edit("se3", reads[4], added: 9, removed: 1, at: t + 4_000))
        messages.append(tool("sf", "bash", ["command": "swift test --filter snapshot_accessibilityXL"], output: swiftTestFailure, error: true,
                             start: t + 10_000, end: t + 18_400))
        return messages
    }

    /// A long deploy: asking, exploring, editing, and commands that failed along the way (the
    /// stretch that used to read as a wall of lines).
    static var longMessages: [NativeThreadMessage] {
        let t0 = now - 12 * 60_000
        var t = t0 + 6_000
        var messages = [
            user("u1", "Get the media stack deployed to horizon and make sure the DNS for it resolves.", at: t0),
            assistant("a1", "I'll confirm the plan with you, then check the stack config and the DNS entry.", at: t0 + 3_000),
        ]
        var index = 0
        func add(_ name: String, _ args: [String: Any], output: String = "", error: Bool = false, seconds: Double = 2) {
            index += 1
            messages.append(tool("l\(index)", name, args, output: output, error: error, start: t, end: t + seconds * 1000))
            t += seconds * 1000 + 400
        }
        let infra = "/Users/you/homelab-infra"
        add("ask_user", ["question": "Apply to horizon now?"], output: "User response: yes", seconds: 5.5)
        for file in ["stacks/media/main.tf", "stacks/media/variables.tf", "stacks/ubiquiti/dns.tf", "flake.nix", "hosts/horizon.nix", "README.md"] {
            add("read", ["path": "\(infra)/\(file)"], output: "line\nline", seconds: 1.8)
        }
        add("bash", ["command": "cd \(infra) && tofu -chdir=stacks/media init"], output: "Terraform has been successfully initialized!", seconds: 14)
        add("bash", ["command": "cd \(infra) && tofu -chdir=stacks/media validate"], output: "Success! The configuration is valid.", seconds: 6)
        add("bash", ["command": "cd \(infra) && tofu -chdir=stacks/media plan"], output: "Plan: 3 to add, 1 to change, 0 to destroy.", seconds: 21)
        add("edit", ["path": "\(infra)/stacks/media/main.tf", "edits": [["oldText": "a", "newText": "a\nb\nc"]]], output: "ok")
        add("edit", ["path": "\(infra)/stacks/media/variables.tf", "edits": [["oldText": "a", "newText": "a\nb"]]], output: "ok")
        add("bash", ["command": "ssh you@horizon.local 'docker ps'"], output: "Command exited with code 255", error: true, seconds: 7.4)
        add("bash", ["command": "dscacheutil -flushcache"], output: "", seconds: 1)
        add("bash", ["command": "dig +short horizon.local"], output: "192.168.1.40", seconds: 0.8)
        add("edit", ["path": "\(infra)/stacks/ubiquiti/dns.tf", "edits": [["oldText": "a", "newText": "b"]]], output: "ok")
        add("bash", ["command": "cd \(infra) && tofu -chdir=stacks/ubiquiti apply -auto-approve"], output: "Apply complete! Resources: 0 added, 1 changed, 0 destroyed.", seconds: 54)
        add("bash", ["command": "for server in sonarr radarr; do curl -sf http://horizon.local/$server/ping; done"],
            output: "Command exited with code 2", error: true, seconds: 3)
        add("bash", ["command": "cd \(infra) && tofu -chdir=stacks/media apply -auto-approve"], output: "Apply complete! Resources: 3 added, 1 changed, 0 destroyed.", seconds: 68)
        add("bash", ["command": "for server in sonarr radarr jellyfin; do curl -sf http://horizon.local/$server/ping; done"], output: "ok\nok\nok", seconds: 6.3)
        messages.append(assistant("a2", "The stale record was on horizon; I flushed it, fixed the DNS entry, and all three services answer now.", at: t + 2_000))
        return messages
    }

    static var long: NativeThreadSnapshot { snapshot(longMessages) }

    static var liveBuild: NativeThreadMessage {
        tool("lb", "bash", ["command": "xcodebuild -scheme 'Shepherd (Dev)' build"],
             output: "CompileSwift normal arm64 ThreadView.swift\nCompileSwift normal arm64 ToolRow.swift\nLinking Shepherd …",
             start: now - 12_000, end: nil, status: "running")
    }
}
