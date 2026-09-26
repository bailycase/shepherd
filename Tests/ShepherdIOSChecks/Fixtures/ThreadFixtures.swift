import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Thread track's screens (thread and composer). Each one serves the default hosts with the
// Studio agents' threads replaced by what its board draws; nothing here asks a host to change.
extension FixtureCatalog {
    static var thread: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        let running = FixtureData.ref(FixtureData.extensions)
        let dock = FixtureData.ref(FixtureData.dock)
        return [
            // MobileThread, iPadThread: a finished turn, tokens in the header, the changes card.
            FixtureScreen(name: "thread", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)]),
            // Rich content in prose: the reported reply's table, then task and nested lists,
            // images, a disclosure and footnotes, then a table wider than the phone and fences.
            FixtureScreen(name: "thread-table", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.reply(MarkdownFixtures.toolsReply)),
                          routes: [.thread(preview)]),
            FixtureScreen(name: "thread-rich", hosts: ThreadFixtures.hosts(
                preview: ThreadFixtures.reply(MarkdownFixtures.structureReply(image: "docs/thread-table.png"))), routes: [.thread(preview)]),
            FixtureScreen(name: "thread-wide", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.reply(MarkdownFixtures.wideReply)),
                          routes: [.thread(preview)]),
            // A turn the user stopped mid-command: "stopped" on its line and a quiet note, no error.
            FixtureScreen(name: "stopped", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.stopped()), routes: [.thread(preview)]),
            // MobileThreadError, iPadThreadError: the earlier error folded, the last one's card,
            // and the header reading Failed.
            FixtureScreen(name: "thread-error", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.providerError()), routes: [.thread(preview)]),
            // TurnErrors › Touch sizes: the card with Details open, the facts above the raw body.
            FixtureScreen(name: "thread-error-details", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.providerError()),
                          routes: [.thread(preview)],
                          prepare: { app in app.threads.store(for: preview).errors.setDetails("e5", open: true) }),
            // TurnErrors › While it retries: the retry line ends the live turn.
            FixtureScreen(name: "thread-error-retrying", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.retrying()), routes: [.thread(preview)]),
            // Thinking the model kept back: a plain "Thought for 10s" line, then thinking it shared.
            FixtureScreen(name: "thinking-unshared", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.unsharedThinking()),
                          routes: [.thread(preview)]),
            // MobileApproval: a running command's live output, Stop, "Queue a follow-up…".
            FixtureScreen(name: "running", hosts: ThreadFixtures.hosts(), routes: [.thread(running)]),
            // MobileQuestion, iPadQuestion: numbered answers, Recommended, one chosen on iPad.
            FixtureScreen(name: "question", hosts: ThreadFixtures.hosts(), routes: [.thread(dock)]),
            FixtureScreen(name: "question-confirm", hosts: ThreadFixtures.hosts(dock: ThreadFixtures.confirm()), routes: [.thread(dock)]),
            FixtureScreen(name: "question-input", hosts: ThreadFixtures.hosts(dock: ThreadFixtures.input()), routes: [.thread(dock)]),
            // Hiding the question (iPad's Hide the question, the phone's grabber) folds it to one
            // line so the thread reads; the agent still waits.
            FixtureScreen(name: "question-hidden", hosts: ThreadFixtures.hosts(), routes: [.thread(dock)],
                          prepare: { _ in
                              let session = NativeThreadSession(piSessionID: "fixture-session", generation: "fixture-generation")
                              ComposerStates.shared.state(for: dock).questionHiding.hide(session.key + ":d-select")
                          }),
            // QuestionAnswered: where pi asked, "Agent asked:" and the question, the answer as the
            // user's bubble with its time, and pi's turn carrying on; one nobody answered below.
            FixtureScreen(name: "question-answered", hosts: ThreadFixtures.hosts(dock: ThreadFixtures.answered()), routes: [.thread(dock)]),
            // MobileQueue, iPadQueue: a steering message, two queued, a draft.
            FixtureScreen(name: "queue", hosts: ThreadFixtures.hosts(running: ThreadFixtures.queued()), routes: [.thread(running)],
                          prepare: { app in app.threads.store(for: running).draft = "Keep the PR title short" }),
            // MobileSteer: one message steering.
            FixtureScreen(name: "steer", hosts: ThreadFixtures.hosts(running: ThreadFixtures.steering()), routes: [.thread(running)]),
            // A paused queue with a deleted message's Undo row.
            FixtureScreen(name: "queue-paused", hosts: ThreadFixtures.idle(ThreadFixtures.hosts(running: ThreadFixtures.paused())),
                          routes: [.thread(running)],
                          prepare: { _ in
                              ComposerStates.shared.state(for: running).deleted(
                                  NativeQueuedMessage(id: ThreadFixtures.deleted, text: "Rename the outbox table", sentAt: FixtureData.start),
                                  index: 1)
                          }),
            // The editor on a queued message (the sheet only; the hold is the app's action).
            FixtureScreen(name: "queue-edit", hosts: ThreadFixtures.hosts(running: ThreadFixtures.queued()), routes: [.thread(running)],
                          prepare: { _ in
                              let state = ComposerStates.shared.state(for: running)
                              state.editText = "Also cover partial refunds in the tests."
                              state.editing = ThreadFixtures.queued().queue?.items.first { $0.id == ThreadFixtures.second }
                          }),
            // iPadPortrait: "/re" lists the commands that match.
            FixtureScreen(name: "commands", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: { app in app.threads.store(for: preview).draft = "/re" }),
            // The phone's chips (commands, model, thinking) over a draft with an image attached.
            FixtureScreen(name: "composer", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: { app in
                              app.threads.store(for: preview).draft = "Match the spacing in this screenshot"
                              Task { await ComposerStates.shared.state(for: preview).attach([(ThreadFixtures.image(), "thread-spacing.png")]) }
                          }),
            // Following the tail: a long thread gets a turn and then its reply (and changes card)
            // after the composer shrinks from eight lines to one, and on iPad the review docks
            // beside it before the reply. The reply must end above the composer.
            FixtureScreen(name: "thread-follow", hosts: FollowFixture.hosts(), routes: [.thread(preview)], prepare: FollowFixture.follow),
            // The same thread dragged up from its tail: the turn and its reply arrive below
            // without moving it, and "Jump to latest" sits above the composer.
            FixtureScreen(name: "thread-jump", hosts: FollowFixture.hosts(), routes: [.thread(preview)], prepare: FollowFixture.jump),
            // The same chips for a model the host says takes no thinking level: no Thinking chip.
            FixtureScreen(name: "composer-plain-model", hosts: ThreadFixtures.plainModel(ThreadFixtures.hosts()), routes: [.thread(preview)],
                          prepare: { app in
                              app.threads.store(for: preview).draft = "Match the spacing in this screenshot"
                              for _ in 0..<100 where ComposerStates.shared.state(for: preview).models == nil {
                                  try? await Task.sleep(for: .milliseconds(50))
                              }
                          }),
            // A tap on the composer: the field keeps focus while the keyboard comes up, and on an
            // iPad in portrait the sidebar stays an overlay, hidden (iPadPortrait).
            FixtureScreen(name: "composer-focus", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FollowFixture.focusAndCheck),
            // The same with the keyboard already up in landscape and the iPad turned to portrait:
            // the sidebar goes back to being an overlay, and the field keeps the focus through
            // the turn with no second tap.
            FixtureScreen(name: "composer-focus-rotate", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FollowFixture.focusRotateAndCheck),
            // The model picker, from the host's catalog: each model's thinking levels under its name.
            FixtureScreen(name: "models", hosts: ThreadFixtures.levels(ThreadFixtures.hosts()), routes: [.thread(preview)],
                          prepare: { _ in ComposerStates.shared.state(for: preview).choosingModel = true }),
        ]
    }
}

enum ThreadFixtures {
    static let steer = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A1")!
    static let first = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A2")!
    static let second = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A3")!
    static let deleted = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A4")!

    /// The default hosts, with Studio's preview, extensions and dock threads replaced.
    static func hosts(preview: NativeThreadSnapshot = thread(), running: NativeThreadSnapshot = approval(),
                      dock: NativeThreadSnapshot = select()) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].threads[FixtureData.preview] = preview
        hosts[0].threads[FixtureData.extensions] = running
        hosts[0].threads[FixtureData.dock] = dock
        hosts[0].models = ["anthropic/claude-opus", "anthropic/claude-sonnet", "anthropic/claude-haiku", "openai/gpt-5", "openai/o3",
                           "google/gemini-2.5-pro"]
        return hosts
    }

    /// Studio's hosts with the threads' model (and New thread's default) one that takes no
    /// thinking level.
    static func plainModel(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        hosts[0].withoutThinking = ["anthropic/claude-opus"]
        return hosts
    }

    /// Studio's catalog with a model that takes no thinking level and one models.json gives
    /// Extra high and Max.
    static func levels(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        hosts[0].withoutThinking = ["anthropic/claude-haiku"]
        hosts[0].thinkingLevels = ["anthropic/claude-sonnet": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]]
        return hosts
    }

    /// The running agent reported idle (its pi was stopped).
    static func idle(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        if let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.extensions }) {
            hosts[0].state.agents[index].status = .idle
        }
        return hosts
    }

    /// Everything an RPC agent offers: the composer's chips and the paperclip show.
    private static func rpc(_ snapshot: NativeThreadSnapshot, contextTokens: Int? = 42_300) -> NativeThreadSnapshot {
        var snapshot = snapshot
        snapshot.supportedActions = ["send", "abort", "answer", "queue", "subagents", "setModel", "setThinking", "sendImages"]
        snapshot.stats = NativeThreadStats(contextTokens: contextTokens, contextWindow: 200_000)
        snapshot.commands = [
            NativeCommand(name: "review", description: "Open the review pane on working-tree changes", source: "extension"),
            NativeCommand(name: "resume", description: "Pick a previous session to continue"),
            NativeCommand(name: "reload", description: "Reload extensions, skills and prompt templates"),
            NativeCommand(name: "release-notes", description: "Draft release notes from commits since the last tag", source: "prompt", arguments: "[tag]"),
            NativeCommand(name: "compact", description: "Summarize the conversation to free context"),
            NativeCommand(name: "model", description: "Switch the model"),
        ]
        return snapshot
    }

    /// MobileThread: the finished turn, with the board's diff sizes.
    static func thread() -> NativeThreadSnapshot {
        typealias F = FixtureData
        let removed = (0..<41).map { "old \($0)" }.joined(separator: "\\n")
        let added = (0..<58).map { "new \($0)" }.joined(separator: "\\n")
        return rpc(F.snapshot([
            F.user("m1", "Remove the visible speaker labels, and make tool rows show something useful instead of just \"complete\"."),
            F.assistant("m2", "I'll finish removing the speaker labels and make tool rows show a useful command or path preview.",
                        thinking: "The labels live in two views; the tool rows need a preview line.", seconds: 4, at: 4_000),
            F.tool("m3", "edit", args: #"{"path":"Sources/ShepherdApp/DesktopNativeThreadView.swift","oldText":""# + removed + #"","newText":""# + added + #""}"#,
                   output: "Edited", at: 60_000),
            F.tool("m4", "edit", args: #"{"path":"App/iOS/ThreadView.swift","oldText":"a\nb\nc\nd","newText":""}"#, output: "Edited", at: 70_000),
            F.tool("m5", "bash", args: #"{"command":"swift test --filter ThreadRows"}"#,
                   output: "✔ Test run with 1 test in 1 suite passed after 0.2 seconds.", at: 150_000),
            F.tool("m6", "bash", args: #"{"command":"xcodebuild -scheme 'Shepherd (Dev)' build"}"#, output: "** BUILD SUCCEEDED **", at: 180_000),
            F.assistant("m7", "Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation.\n\nFocused regression test and Mac Dev build passed.",
                        at: 192_000),
        ], turnChanges: [F.previewTurn()]))
    }

    /// A question and an answer in rich Markdown (MarkdownFixtures).
    static func reply(_ text: String) -> NativeThreadSnapshot {
        typealias F = FixtureData
        return rpc(F.snapshot([
            F.user("m1", "Which tools does Shepherd expose to its agents?"),
            F.assistant("m2", text, at: 9_000),
        ]))
    }

    /// OpenAI refusing the key, as the error boards draw it.
    static let authError = #"401: {"message":"Incorrect API key provided: sk-svcac*****************************fvMA. You can find your API key at https://platform.openai.com/account/api-keys.","type":"authentication_error","code":"auth_unavailable"}"#

    private static func failure(_ id: String, _ text: String, at offset: Double) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], status: "error",
                            timestamp: FixtureData.start + offset, provider: "openai", model: "gpt-6-astra")
    }

    /// MobileThreadError: the dashboards follow-up failed, and the next one failed the same way.
    static func providerError() -> NativeThreadSnapshot {
        typealias F = FixtureData
        return rpc(F.snapshot([
            F.user("e1", "Add Prometheus metrics to ms-payments: request latency, error rate and Kafka consumer lag."),
            F.assistant("e2", "The Grafana dashboard and alert rules live in the infra repo, so they aren’t in this branch yet.", at: 250_000),
            F.user("e3", "ok, add the dashboard and alerts too", at: 1_260_000),
            failure("e4", authError, at: 1_262_000),
            F.user("e5u", "we need two PRs for this right? one for this service, and one for infra wherever the grafana and prometheus stuff lives. copy what I did for ms-graphql-internal.",
                   at: 1_380_000),
            failure("e5", authError, at: 1_382_000),
        ]))
    }

    /// pi retrying an overloaded request: the second of three tries goes in a few seconds.
    static func retrying() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var snapshot = rpc(F.snapshot([
            F.user("r1", "ok, add the dashboard and alerts too"),
            failure("r2", #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, at: 2_000),
        ], running: true))
        snapshot.retry = NativeThreadRetry(attempt: 2, maxAttempts: 3, retryAt: Date.now.timeIntervalSince1970 * 1000 + 60_000)
        return snapshot
    }

    /// The user stopped a long command: pi failed the call and ended the run with an error reply,
    /// which the host projects as `aborted`.
    static func stopped() -> NativeThreadSnapshot {
        typealias F = FixtureData
        return rpc(F.snapshot([
            F.user("s1", "Use the bash tool to run `sleep 40`, then reply with exactly: slept"),
            F.tool("s2", "bash", args: #"{"command":"sleep 40"}"#, output: "Command aborted", error: true, status: "aborted", at: 9_500),
            F.assistant("s3", "", at: 9_600, status: "aborted"),
        ]))
    }

    /// A turn whose model shared none of its first stretch's thinking (timed: a plain line) and
    /// some of the second's (the disclosure).
    static func unsharedThinking() -> NativeThreadSnapshot {
        typealias F = FixtureData
        return rpc(F.snapshot([
            F.user("k1", "Why does the sidebar jump when an agent finishes?"),
            F.assistant("k2", "Looking at how the sidebar orders its rows.", thinking: "", seconds: 10, at: 11_000),
            F.tool("k3", "read", args: #"{"path":"Sources/ShepherdApp/SidebarView.swift"}"#, output: "line", at: 12_000),
            F.assistant("k4", "", thinking: "Finished agents sort by their last activity, so a status change moves the row.", seconds: 4,
                        at: 17_000),
            F.tool("k5", "grep", args: #"{"pattern":"lastActivity","path":"Sources/"}"#, output: "Sources/A.swift:12", at: 18_000),
            F.assistant("k6", "The row moves because finished agents sort by their last activity. Sorting by creation keeps it still.",
                        at: 20_000),
        ]))
    }

    /// MobileApproval: committed, and a push streaming its output.
    static func approval() -> NativeThreadSnapshot {
        typealias F = FixtureData
        let started = Date().timeIntervalSince1970 * 1000 - F.start - 21_000
        return rpc(F.snapshot([
            F.user("a1", "Looks good. Commit it and push to main.", at: started),
            F.assistant("a2", "Committing the three changed files, then pushing.", at: started + 3_000),
            F.tool("a3", "bash", args: #"{"command":"git add -A && git commit -m 'Tool rows show a preview'"}"#,
                   output: "[main 4c1d2e9] Tool rows show a preview\n 3 files changed", at: started + 9_000),
            F.tool("a4", "bash", args: #"{"command":"git push origin main"}"#,
                   output: "Enumerating objects: 14, done.\nWriting objects: 100% (8/8), 2.31 KiB | 2.31 MiB/s\nremote: Resolving deltas: 0% (0/5)",
                   status: "running", at: started + 18_000),
        ], running: true))
    }

    private static func refunds(_ queue: NativeQueue) -> NativeThreadSnapshot {
        typealias F = FixtureData
        let started = Date().timeIntervalSince1970 * 1000 - F.start - 300_000
        var snapshot = rpc(F.snapshot([
            F.user("q1", "Add refund events to the ledger outbox and cover them with tests.", at: started),
            F.tool("q2", "read", args: #"{"path":"ledger/outbox.go"}"#, output: "package ledger", at: started + 20_000),
            F.tool("q3", "edit", args: #"{"path":"ledger/outbox.go","oldText":"a","newText":"b\nc"}"#, output: "Edited", at: started + 60_000),
            F.assistant("q4", "The outbox now emits refund.created and refund.settled. Running the ledger tests next.", at: started + 80_000),
            F.tool("q5", "bash", args: #"{"command":"go test ./ledger/..."}"#, output: "=== RUN   TestRefundCreated", status: "running",
                   at: started + 282_000),
        ], running: true))
        snapshot.queue = queue
        return snapshot
    }

    /// MobileQueue: one steering, two queued.
    static func queued() -> NativeThreadSnapshot {
        refunds(NativeQueue(items: [
            NativeQueuedMessage(id: steer, text: "Don't touch the migrations in this PR.", sentAt: FixtureData.start, state: .steering),
            NativeQueuedMessage(id: second, text: "Also cover partial refunds in the tests.", sentAt: FixtureData.start),
            NativeQueuedMessage(id: first, text: "Then open a draft PR.", images: [NativeQueuedImage(mimeType: "image/png", name: "ledger.png")],
                                sentAt: FixtureData.start),
        ], mode: .oneAtATime))
    }

    /// MobileSteer: a message steering, nothing queued.
    static func steering() -> NativeThreadSnapshot {
        refunds(NativeQueue(items: [
            NativeQueuedMessage(id: steer, text: "Keep the sidebar at 232pt when a pane opens beside it.", sentAt: FixtureData.start, state: .steering),
        ]))
    }

    /// A queue that waits: pi was stopped.
    static func paused() -> NativeThreadSnapshot {
        var snapshot = refunds(NativeQueue(items: [
            NativeQueuedMessage(id: second, text: "Also cover partial refunds in the tests.", sentAt: FixtureData.start),
            NativeQueuedMessage(id: first, text: "Then open a draft PR.", sentAt: FixtureData.start),
        ], mode: .all, paused: true))
        snapshot.running = false
        snapshot.messages[4].status = "complete"
        return snapshot
    }

    private static func asking(_ dialog: NativeThreadDialog) -> NativeThreadSnapshot {
        typealias F = FixtureData
        return rpc(F.snapshot([
            F.user("d1", "Deploy the new media stack to Horizon."),
            F.tool("d2", "bash", args: #"{"command":"git status && git fetch"}"#, output: "Your branch is behind 'origin/master' by 50 commits.",
                   at: 4_000),
            F.assistant("d3", "Horizon's checkout isn't clean, so I stopped before pulling:\n\n- 50 commits behind GitHub\n- 11 uncommitted files, one an encrypted secret\n- The Homarr removal is already merged",
                        at: 9_000),
        ], running: true, dialogs: [dialog]))
    }

    /// MobileQuestion: two answers, the first recommended by the asker, and a timeout.
    static func select() -> NativeThreadSnapshot {
        asking(NativeThreadDialog(id: "d-select", kind: .select, title: "How should I handle Horizon's uncommitted edits?", options: [
            "Compare, keep what's unique, then go through GitHub (Recommended)\nNew branch and PR for anything not merged. Nothing on Horizon is overwritten.",
            "Leave Horizon alone and deploy from a clean checkout\nHorizon keeps its edits. The deploy uses a fresh clone.",
        ]))
    }

    /// QuestionAnswered: the question recorded where pi asked it, and the turn going on.
    static func answered() -> NativeThreadSnapshot {
        typealias F = FixtureData
        func record(_ id: String, _ question: NativeQuestionRecord, at offset: Double) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "q:" + id, role: "question", blocks: [], timestamp: F.start + offset, question: question)
        }
        return rpc(F.snapshot([
            F.user("d1", "Deploy the new media stack to Horizon."),
            F.tool("d2", "bash", args: #"{"command":"git status && git fetch"}"#, output: "Your branch is behind 'origin/master' by 50 commits.",
                   at: 4_000),
            F.assistant("d3", "Horizon's checkout isn't clean, so I stopped before pulling:\n\n- 50 commits behind GitHub\n- 11 uncommitted files, one an encrypted secret\n- The Homarr removal is already merged",
                        at: 9_000),
            record("d-select", NativeQuestionRecord(
                kind: .select, question: "How should I handle Horizon's uncommitted edits?",
                answer: "Compare, keep what's unique, then go through GitHub (Recommended)\nNew branch and PR for anything not merged.",
                outcome: .answered, askedAt: F.start + 10_000), at: 300_000),
            F.tool("d4", "bash", args: #"{"command":"git push origin HEAD:horizon/media-support"}"#, output: "", at: 330_000),
            F.assistant("d5", "Four of the eleven files were already in the merged Homarr PR. The other seven are on `horizon/media-support`. The encrypted secret stays on Horizon.",
                        at: 340_000),
            record("d-confirm", NativeQuestionRecord(kind: .confirm, question: "Push the deploy branch to origin?", outcome: .expired,
                                                     askedAt: F.start + 341_000), at: 401_000),
        ]))
    }

    static func confirm() -> NativeThreadSnapshot {
        asking(NativeThreadDialog(id: "d-confirm", kind: .confirm, title: "Push the deploy branch to origin?",
                                  message: "git push origin deploy/media-stack"))
    }

    static func input() -> NativeThreadSnapshot {
        asking(NativeThreadDialog(id: "d-input", kind: .input, title: "Which tag should the deploy use?", placeholder: "v1.4.2"))
    }

    /// A small image, as the picker would hand one over.
    static func image() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }
}

/// "thread-follow": the host serves a long thread, then, as the screen asks, the same thread with
/// a new turn (pi took it) and then its reply, as two polls bring them.
enum FollowFixture {
    private static let state = FollowState()

    private final class FollowState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func advance() { lock.withLock { value += 1 } }
        var stage: Int { lock.withLock { value } }
    }

    static func hosts() -> [FixtureHostData] {
        var hosts = ReviewFixture.hosts()
        let review = hosts[0].reply
        hosts[0].reply = { request in
            guard case .nativeThread(let id, let agentID, .snapshot) = request, agentID == FixtureData.preview else { return review?(request) }
            return .nativeThread(id: id, result: .snapshot(value: thread(stage: state.stage)))
        }
        return hosts
    }

    static func thread(stage: Int) -> NativeThreadSnapshot {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        for turn in 0..<8 {
            let at = Double(turn) * 60_000
            messages.append(F.user("f\(turn)u", "Reply with exactly: follow-\(turn)", at: at))
            messages.append(F.assistant("f\(turn)a", "follow-\(turn)\n\nThe thread keeps growing so it scrolls well past one screen on every device, iPad landscape included.",
                                        at: at + 3_000))
        }
        if stage >= 1 {
            messages.append(F.user("g1", "Use the edit tool to append a line '# pad' to README.md. Then reply with exactly: pad-done", at: 600_000))
        }
        if stage >= 2 {
            messages.append(F.tool("g2", "edit", args: #"{"path":"README.md","oldText":"a","newText":"a\n# pad"}"#, output: "Edited", at: 603_000))
            messages.append(F.assistant("g3", "pad-done", at: 605_000))
        }
        var snapshot = F.snapshot(messages, running: stage < 2)
        snapshot.revision = UInt64(stage + 1)
        return snapshot
    }

    /// A draft of many lines grows the composer, as the keyboard does; sending clears it, and the
    /// turn and its reply arrive in two polls. While pi works the reader starts a follow-up, so
    /// the composer grows again under the thread before the reply lands.
    @MainActor static func follow(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        let draft = (1...8).map { "Line \($0) of a long message to the agent" }.joined(separator: "\n")
        store.draft = draft
        try? await Task.sleep(for: .seconds(1.5))
        store.draft = ""
        for stage in 1...2 {
            // On iPad the review docks beside the thread between the turn and its reply, and
            // the thread's rows re-wrap narrower.
            if stage == 2, UIDevice.current.userInterfaceIdiom == .pad { app.navigator.open(.review(.changes(ref, file: nil))) }
            if stage == 2 {
                store.draft = draft
                focusComposer()
                try? await Task.sleep(for: .seconds(1))
            }
            state.advance()
            await FixtureWindows.wait(seconds: 10) { store.snapshot?.revision == UInt64(stage + 1) }
            try? await Task.sleep(for: .seconds(1))
        }
        check("the reply ends above the composer") { $0 <= MobileLayout.gutter + 1 }
    }

    /// Focuses the composer as a tap does and waits for the keyboard: the field keeps the focus
    /// and sits above the keyboard, and on an iPad in portrait the sidebar is still a hidden
    /// overlay (the keyboard's height must not read as a landscape window).
    @MainActor static func focusAndCheck(_ app: MobileApp) async {
        let keyboard = KeyboardFrame()
        focusComposer()
        try? await Task.sleep(for: .seconds(2))
        checkFocus(app, keyboard: keyboard)
    }

    /// Focuses the composer in landscape, then turns the iPad to portrait with the keyboard up:
    /// the field keeps the focus through the turn, with no second tap, and the checks of
    /// `focusAndCheck` hold. On iPhone, only `focusAndCheck`.
    @MainActor static func focusRotateAndCheck(_ app: MobileApp) async {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return await focusAndCheck(app)
        }
        let keyboard = KeyboardFrame()
        await turn(scene, to: .landscapeRight)
        focusComposer()
        try? await Task.sleep(for: .seconds(2))
        await turn(scene, to: .portrait)
        try? await Task.sleep(for: .seconds(1))
        checkFocus(app, keyboard: keyboard)
    }

    @MainActor private static func checkFocus(_ app: MobileApp, keyboard: KeyboardFrame) {
        let field = composerField()
        let focused = field?.isFirstResponder == true
        print("FIXTURE CHECK \(focused ? "ok" : "FAILED"): the composer keeps focus")
        if focused, let field, let top = keyboard.top {
            let bottom = field.convert(field.bounds, to: nil).maxY
            print("FIXTURE CHECK \(bottom <= top ? "ok" : "FAILED"): the field sits above the keyboard (\(Int(top - bottom))pt)")
        }
        if UIDevice.current.userInterfaceIdiom == .pad, let window = field?.window, window.bounds.height > window.bounds.width {
            let holds = app.navigator.padSidebarOverlays && app.navigator.padColumns == .detailOnly
            print("FIXTURE CHECK \(holds ? "ok" : "FAILED"): the portrait sidebar stays a hidden overlay")
        }
    }

    @MainActor private static func turn(_ scene: UIWindowScene, to orientation: UIInterfaceOrientationMask) async {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
            print("FIXTURE ORIENTATION \(error.localizedDescription)")
        }
        await FixtureWindows.wait(seconds: 5) {
            orientation == .portrait ? scene.effectiveGeometry.interfaceOrientation.isPortrait
                : scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// The top of the keyboard's last frame on screen, in the window's coordinates (full screen
    /// here). A turn with the keyboard up also reports it going below the screen, or with no
    /// height, as the composer mounts again (`PadShell`); those frames are passed over.
    @MainActor private final class KeyboardFrame {
        private(set) var top: CGFloat?
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                                              queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
                    guard let frame, frame.height > 0, let window, frame.minY < window.bounds.maxY else { return }
                    self?.top = frame.minY
                }
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    @MainActor private static func composerField() -> UITextView? {
        var fields: [UITextView] = []
        func walk(_ view: UIView) {
            if let field = view as? UITextView, field.isEditable { fields.append(field) }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        return fields.last
    }

    /// A finger drags the thread up from its tail (its pan recognizer stepped through a drag, as
    /// a touch would), then the turn and its reply arrive in two polls.
    @MainActor static func jump(_ app: MobileApp) async {
        let store = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        try? await Task.sleep(for: .seconds(1))
        guard let scroll = threadScrollView() else { return print("FIXTURE CHECK FAILED: no thread scroll view") }
        let pan = scroll.panGestureRecognizer
        pan.state = .began
        for step in 1...12 {
            pan.setTranslation(CGPoint(x: 0, y: step * 50), in: scroll)
            pan.state = .changed
            scroll.contentOffset.y -= 50
            try? await Task.sleep(for: .milliseconds(16))
        }
        pan.state = .ended
        for stage in 1...2 {
            state.advance()
            await FixtureWindows.wait(seconds: 10) { store.snapshot?.revision == UInt64(stage + 1) }
            try? await Task.sleep(for: .seconds(1))
        }
        check("a thread dragged up stays where the reader left it") { $0 > NativeScrollFollower.threshold }
    }

    /// Prints whether the thread's tail sits where `holds` wants it: its distance, in points,
    /// above the end of the content, with the composer's inset counted. At the tail it is the
    /// thread's bottom padding (the gutter under the bottom marker a scroll lands on).
    @MainActor private static func check(_ what: String, _ holds: (CGFloat) -> Bool) {
        guard let scroll = threadScrollView() else { return print("FIXTURE CHECK FAILED: no thread scroll view") }
        let distance = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y - scroll.bounds.height
        print("FIXTURE CHECK \(holds(distance) ? "ok" : "FAILED"): \(what) (\(Int(distance.rounded()))pt above the tail)")
    }

    /// Puts the caret in the composer's field, so the software keyboard (when the simulator
    /// shows one) raises the composer as a reader's tap would.
    @MainActor private static func focusComposer() {
        composerField()?.becomeFirstResponder()
    }

    /// The thread's scroll view: the tallest scrolling one that isn't a list (the iPad sidebar)
    /// or a text view.
    @MainActor private static func threadScrollView() -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UICollectionView), !(scroll is UITextView),
               scroll.contentSize.height > scroll.bounds.height {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }
}
