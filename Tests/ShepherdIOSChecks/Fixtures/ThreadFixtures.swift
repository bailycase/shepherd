import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol

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
            // MobileApproval: a running command's live output, Stop, "Queue a follow-up…".
            FixtureScreen(name: "running", hosts: ThreadFixtures.hosts(), routes: [.thread(running)]),
            // MobileQuestion, iPadQuestion: numbered answers, Recommended, one chosen on iPad.
            FixtureScreen(name: "question", hosts: ThreadFixtures.hosts(), routes: [.thread(dock)]),
            FixtureScreen(name: "question-confirm", hosts: ThreadFixtures.hosts(dock: ThreadFixtures.confirm()), routes: [.thread(dock)]),
            FixtureScreen(name: "question-input", hosts: ThreadFixtures.hosts(dock: ThreadFixtures.input()), routes: [.thread(dock)]),
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
            // The same chips for a model the host says takes no thinking level: no Thinking chip.
            FixtureScreen(name: "composer-plain-model", hosts: ThreadFixtures.plainModel(ThreadFixtures.hosts()), routes: [.thread(preview)],
                          prepare: { app in
                              app.threads.store(for: preview).draft = "Match the spacing in this screenshot"
                              for _ in 0..<100 where ComposerStates.shared.state(for: preview).models == nil {
                                  try? await Task.sleep(for: .milliseconds(50))
                              }
                          }),
            // The model picker, from the host's catalog.
            FixtureScreen(name: "models", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
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
            NativeCommand(name: "release-notes", description: "Draft release notes from commits since the last tag", source: "prompt"),
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
