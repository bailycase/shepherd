import AppKit
import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import Testing
@testable import ShepherdApp

/// The thread and composer surfaces of the NWThread, "Activity line states", Running, Main and
/// NWComposer boards, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
@Suite("Thread previews", .serialized, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ThreadPreviewTests {
    private func render(_ surface: String, _ snapshot: NativeThreadSnapshot, size: CGSize = CGSize(width: 1180, height: 900)) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty }) {
            fixture.thread()
        }
    }

    /// Main board: explored / edited / tests-and-build lines, the changes card and the footer.
    @Test func threadActivityIdle() async throws {
        try await render("thread-activity-idle", ActivityThreads.idle)
    }

    /// Running board: a finished commit line, the live push with its last output lines, and
    /// the working row.
    @Test func threadActivityRunning() async throws {
        try await render("thread-activity-running", ActivityThreads.running(thinking: false))
    }

    /// The model thinking at the tail: "Thinking… 4s" instead of the working row.
    @Test func threadActivityThinking() async throws {
        try await render("thread-activity-thinking", ActivityThreads.running(thinking: true))
    }

    /// Failed test runs stay red; a turn that failed as a whole ends in NWTurnError with Retry.
    @Test func threadActivityFailed() async throws {
        try await render("thread-activity-failed", ActivityThreads.failed)
    }

    /// Prose, lists, inline code, a link, and a highlighted code block.
    @Test func threadProse() async throws {
        try await render("thread-prose", ActivityThreads.prose)
    }

    /// The "Activity line states" board: done, expanded into calls, failed with its output
    /// expanded, and live.
    @Test func activityLineStates() async throws {
        let turn = nativeTurnPresentation(ActivityThreads.stateMessages, live: false)
        let bursts = turn.items.compactMap { item -> NativeActivityBurst? in
            if case .activity(let burst) = item { return burst }
            return nil
        }
        let live = nativeActivityBurst([NativeActivityCall(ActivityThreads.liveBuild)])
        let failed = try #require(bursts.first { $0.state == .failed })
        let size = CGSize(width: 760, height: 560)
        try await Preview.render("activity-line-states", size: size) {
            VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
                Text("DONE").nwSectionLabel()
                ForEach(bursts.filter { $0.state == .done }) { burst in
                    ActivityLineView(burst: burst, review: { _ in }, expanded: burst.kind == .edit)
                }
                Text("FAILED").nwSectionLabel().padding(.top, NW.Space.s)
                ActivityLineView(burst: failed, expanded: true, expandedCalls: Set(failed.calls.map(\.id)))
                Text("LIVE").nwSectionLabel().padding(.top, NW.Space.s)
                ActivityLineView(burst: live)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// The NWThread board's parts: bubbles (plain and queued), attachment chips, thinking open
    /// and live, the changes card, the footer and a turn error.
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
                NWUserBubble("Restyle the thread view to the spec and split the work however you like.", timestamp: "2:41 PM")
                NWUserBubble("Also bump the tool row height to 28.", isQueued: true)
                HStack(spacing: NW.Space.s) {
                    NWAttachmentChip("Spec.dc.html") {}
                    NWAttachmentChip("screenshot.png", thumbnail: Image(systemName: "photo"))
                }
                NWThinking("Thought for 6s", text: "The tool summary row is 28pt elsewhere. I’ll keep it a minimum, not a fixed height, so large text sizes still fit.",
                           isExpanded: .constant(true))
                NWThinking(liveSince: Date().addingTimeInterval(-4))
                changes
                NWTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {})
                NWTurnError("Model overloaded — the turn stopped after 6 tool calls.", retry: {})
                    .frame(maxWidth: 440)
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
        let size = CGSize(width: 1260, height: 760)
        try await Preview.render("composer-states", size: size) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 24) {
                    NWComposer(isFocused: false) { field("Follow up, or / for commands…", placeholder: true) } controls: { controls() }
                    NWComposer(isFocused: true) { field("Make the reviewer check dark mode too", placeholder: false) } controls: { controls(enabled: true) }
                    NWComposer(isFocused: false) { field("Queue a follow-up — sent when the turn ends", placeholder: true) } controls: { controls(stop: true) }
                    NWComposer(isFocused: false) {
                        NWAttachmentChip("thread-spacing.png", thumbnail: Image(systemName: "photo")) {}
                    } field: { field("Match the spacing in this screenshot", placeholder: false) } controls: { controls(enabled: true) }
                }
                .frame(width: 600)
                VStack(alignment: .leading, spacing: 24) {
                    NWSlashMenu(commands: [
                        NWSlashCommand(name: "review", description: "Open the review pane on working-tree changes"),
                        NWSlashCommand(name: "resume", description: "Pick a previous session to continue", arguments: "[session]"),
                        NWSlashCommand(name: "reload", description: "Reload extensions, skills and prompts"),
                        NWSlashCommand(name: "release-notes", description: "Draft release notes since the last tag", arguments: "[tag]", tag: "prompt"),
                    ], total: 23, query: "re", selection: .constant(0)) { _ in }
                    HStack(alignment: .top, spacing: 24) {
                        NWModelPicker(query: .constant(""), sections: [
                            NWModelSection(title: "Recent", options: [
                                NWModelOption(id: "anthropic/claude-opus", title: "claude-opus", isCurrent: true),
                                NWModelOption(id: "anthropic/claude-sonnet", title: "claude-sonnet", note: "fast"),
                            ]),
                            NWModelSection(title: "Anthropic", options: [
                                NWModelOption(id: "anthropic/claude-fable-5-1", title: "claude-fable-5-1"),
                                NWModelOption(id: "anthropic/claude-haiku", title: "claude-haiku"),
                            ]),
                        ], selection: .constant(0), onChoose: { _ in }, onClose: {})
                        NWThinkingMenu(options: [
                            NWThinkingOption(id: "off", title: "Off"), NWThinkingOption(id: "low", title: "Low", note: "quick"),
                            NWThinkingOption(id: "medium", title: "Medium", note: "default"), NWThinkingOption(id: "high", title: "High", note: "slower, deeper"),
                        ], current: "medium", onChoose: { _ in }, onClose: {})
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}

// MARK: Fixtures

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

    /// The Running board: the previous turn, the new prompt, a commit, and a live push (or live
    /// thinking) at the tail.
    static func running(thinking: Bool) -> NativeThreadSnapshot {
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
        if thinking {
            provisional.append(NativeThreadMessage(entryID: "provisional:assistant:9", role: "assistant",
                                                   blocks: [NativeThreadBlock(kind: .thinking, text: "Push, then check CI.")],
                                                   status: "streaming", timestamp: now - 4_000, thinkingSeconds: 4))
        } else {
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

    static var liveBuild: NativeThreadMessage {
        tool("lb", "bash", ["command": "xcodebuild -scheme 'Shepherd (Dev)' build"],
             output: "CompileSwift normal arm64 ThreadView.swift\nCompileSwift normal arm64 ToolRow.swift\nLinking Shepherd …",
             start: now - 12_000, end: nil, status: "running")
    }
}
