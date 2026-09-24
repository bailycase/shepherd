import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Queue & steer boards (QueueStack, QueueSteer, QueueEdit, QueueStates), in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    /// QueueStack: three messages wait above the composer while the tests run, the second
    /// hovered (grip, Steer now, Edit, Delete), and a draft brings Stop outlined beside Send.
    @Test func queueStack() async throws {
        let fixture = QueueThreadFixture(QueueThreads.running, queue: QueueFixture.messages(QueueThreads.queued),
                                         draft: "Keep the PR title under 60 characters")
        defer { fixture.store.stop() }
        try await Preview.render("queue-stack", size: CGSize(width: 1180, height: 900), ready: {
            guard fixture.store.ready, fixture.state.rows.count == 3 else { return false }
            fixture.state.hover(fixture.id(1).uuidString).hovering = true
            return true
        }) {
            fixture.thread()
        }
    }

    /// QueueSteer: a message steered in lands after the tool call pi was running, with its
    /// outline; the next one is steering (Back to the queue) above two queued; Stop, no draft.
    @Test func queueSteer() async throws {
        let fixture = QueueThreadFixture(QueueThreads.steered, queue: QueueFixture.messages(
            ["Don’t touch the migrations in this PR.", "Also cover partial refunds in the tests.", "Then open a draft PR."], steering: 1))
        defer { fixture.store.stop() }
        try await Preview.render("queue-steer", size: CGSize(width: 1180, height: 900), ready: {
            fixture.store.ready && fixture.state.rows.count == 3
        }) {
            fixture.thread()
        }
    }

    /// QueueEdit: the first message open in the editor, the third deleted with Undo, and the Send
    /// menu open on a draft (opened as a right-click on Send opens it), beside the card as the
    /// board draws it: the thread is wide enough for it there.
    @Test func queueEdit() async throws {
        let fixture = QueueThreadFixture(QueueThreads.running, queue: QueueFixture.messages(QueueThreads.queued),
                                         draft: "Open it as a draft once tests pass")
        defer { fixture.store.stop() }
        final class Once { var seeded = false; var opened = false }
        let once = Once()
        try await Preview.render("queue-edit", size: CGSize(width: 1440, height: 900), ready: {
            guard fixture.store.ready else { return false }
            if !once.seeded {
                guard fixture.store.queue.count == 3 else { return false }
                once.seeded = true
                fixture.state.edit(fixture.id(0), store: fixture.store)
                fixture.state.draft = "Also cover partial refunds and refunds of a refund in the tests."
                fixture.state.delete(fixture.id(2), store: fixture.store)
            }
            if !once.opened, let send = SendButton.find() {
                once.opened = true
                send.rightMouseDown(with: SendButton.rightClick)
            }
            return once.opened && fixture.state.undo.count == 1 && fixture.state.editing != nil
        }) {
            // Each appearance renders a new composer: its Send menu opens again.
            let _ = once.opened = false
            fixture.thread()
        }
    }

    /// QueueStates: every state of a row and the stack (queued, hovered, steering, editing,
    /// deleted, with attachments, reordering, long, collapsed, focused), the Send menu, and the
    /// thread's "From the queue" and "Steered".
    @Test func queueStates() async throws {
        let queued = QueueStackFixture(["Also cover partial refunds in the tests."])
        let hovered = QueueStackFixture(["Use table-driven tests, like ledger_test.go."])
        let steering = QueueStackFixture(["Don’t touch the migrations in this PR."], steering: 1)
        let editing = QueueStackFixture(["Also cover partial refunds in the tests."])
        let deleted = QueueStackFixture(["Then open a draft PR.", "Use table-driven tests, like ledger_test.go."])
        let attachments = QueueStackFixture(["Make this full width on phones"], images: [0: ["checkout.png"]])
        let reordering = QueueStackFixture(["Also cover partial refunds in the tests.", "Then open a draft PR.",
                                            "Use table-driven tests, like ledger_test.go."])
        let long = QueueStackFixture(["Don’t touch the migrations in this PR.", "Also cover partial refunds in the tests.",
                                      "Then open a draft PR.", "Use table-driven tests.", "Keep the title short.", "Tag the release."], steering: 1)
        let collapsed = QueueStackFixture(["Also cover partial refunds in the tests.", "Then open a draft PR."])
        let expanded = QueueStackFixture((1...8).map { "Queued message \($0)" })
        let all = [queued, hovered, steering, editing, deleted, attachments, reordering, long, collapsed, expanded]
        defer { all.forEach { $0.store.stop() } }
        final class Once { var seeded = false }
        let once = Once()
        let size = CGSize(width: 1520, height: 1180)
        try await Preview.render("queue-states", size: size, ready: {
            guard all.allSatisfy({ $0.store.ready && !$0.state.rows.isEmpty }) else { return false }
            if !once.seeded {
                once.seeded = true
                hovered.state.hover(hovered.id(0).uuidString).hovering = true
                editing.state.edit(editing.id(0), store: editing.store)
                editing.state.draft = "Also cover partial refunds and refunds of a refund in the tests."
                deleted.state.delete(deleted.id(0), store: deleted.store)
                reordering.state.drag(reordering.id(2).uuidString, by: -46)
                collapsed.state.collapsed = true
                expanded.state.toggleExpanded()
            }
            return deleted.state.undo.count == 1 && editing.state.editing != nil && reordering.state.drop != nil
        }) {
            QueueStatesBoard(queued: queued, hovered: hovered, steering: steering, editing: editing, deleted: deleted,
                             attachments: attachments, reordering: reordering, long: long, collapsed: collapsed, expanded: expanded)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// In the thread: messages the queue delivered as one turn under "From the queue · 2", each
    /// with the time it was sent (shown here as on hover), and a message steered in mid-turn.
    @Test func threadQueue() async throws {
        let fixture = QueueThreadFixture(QueueThreads.delivered)
        defer { fixture.store.stop() }
        let store = fixture.store
        let size = CGSize(width: 1180, height: 900)
        try await Preview.render("thread-queue", size: size, ready: { store.ready && !store.rows.isEmpty }) {
            HoveredQueueThread(store: store)
                .frame(width: size.width, height: size.height)
                .task { await store.run(request: fixture.request) }
        }
    }
}

/// The thread's rows with every turn hovered, so each bubble's time shows.
private struct HoveredQueueThread: View {
    let store: NativeThreadStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
            ForEach(store.rows) { row in
                if row.isUser {
                    UserTurn(turn: row.turn, hover: MessageHover(hovering: true))
                } else if let presentation = row.presentation {
                    AgentTurn(presentation: presentation, live: row.live, startedAt: row.startedAt, retry: {}, review: { _ in },
                              hover: MessageHover(hovering: true))
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

/// One stack state for the board: its own store and host.
@MainActor
final class QueueStackFixture {
    let fixture: QueueThreadFixture
    var store: NativeThreadStore { fixture.store }
    var state: QueueStackState { fixture.state }

    init(_ texts: [String], steering: Int = 0, images: [Int: [String]] = [:]) {
        fixture = QueueThreadFixture(QueueThreads.running, queue: QueueFixture.messages(texts, steering: steering, images: images))
    }

    func id(_ index: Int) -> UUID { fixture.id(index) }
}

private struct QueueStatesBoard: View {
    let queued, hovered, steering, editing, deleted, attachments, reordering, long, collapsed, expanded: QueueStackFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(alignment: .top, spacing: 16) {
                cell("QueueItem · queued", queued)
                cell("QueueItem · hover", hovered)
                cell("QueueItem · steering", steering)
            }
            HStack(alignment: .top, spacing: 16) {
                cell("QueueItem · editing", editing)
                cell("QueueItem · deleted", deleted)
                cell("QueueItem · with attachments", attachments)
            }
            HStack(alignment: .top, spacing: 16) {
                cell("QueueItem · reordering", reordering)
                cell("QueueStack · long", long)
                VStack(alignment: .leading, spacing: 16) {
                    cell("QueueStack · collapsed", collapsed)
                    label("QueueItem · focused")
                    NWQueueStack(count: 1, collapsed: false, onToggle: {}) {
                        NWQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1), focused: true,
                                   actions: NWQueueRowActions(steer: {}, edit: {}, delete: {}))
                    } options: { EmptyView() }
                    .frame(width: 424)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    label("SendMenu (right-click or hold Send)")
                    NWSendMenu(options: Composer.sendOptions(.queue, send: "↩", alternate: "⌘↩"), onChoose: { _ in }, onClose: {})
                }
                cell("QueueStack · expanded (scrolls past six)", expanded)
                VStack(alignment: .trailing, spacing: 10) {
                    label("Queue delivered at turn end · Steer landed mid-turn")
                    NWQueueDivider(count: 2)
                    NWUserBubble("Also cover partial refunds in the tests.", timestamp: "3:04 PM", revealed: true)
                    NWUserBubble("Use table-driven tests, like ledger_test.go.", timestamp: "3:07 PM", revealed: true, origin: .steered)
                }
                .frame(width: 520)
            }
        }
        .padding(32)
        .background(Color.nw.bgWindow)
    }

    private func cell(_ title: String, _ fixture: QueueStackFixture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label(title)
            fixture.fixture.stack().frame(width: 424)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.nwMono(11)).foregroundStyle(Color.nw.textSecondary)
    }
}

/// Send's right-click catcher in the window on screen, and a right-click built for it (never
/// posted): the way the Send menu opens without driving the pointer.
@MainActor
enum SendButton {
    static func find() -> SecondaryClick.Catcher? {
        func find(_ view: NSView) -> SecondaryClick.Catcher? {
            if let catcher = view as? SecondaryClick.Catcher { return catcher }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApplication.shared.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    static var rightClick: NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// The Queue & steer boards' thread: refund events for a ledger outbox.
@MainActor
enum QueueThreads {
    static let queued = ["Also cover partial refunds in the tests.", "Use table-driven tests, like ledger_test.go.", "Then open a draft PR."]

    private static var now: Double { ActivityThreads.now }

    /// The prompt, what pi explored and edited, and its note before the tests.
    static func opening(at t0: Double) -> [NativeThreadMessage] {
        var messages = [ActivityThreads.user("u1", "Add refund events to the ledger outbox and cover them with tests.", at: t0)]
        let t = t0 + 4_000
        let reads = ["ledger/outbox.go", "ledger/events.go", "ledger/ledger.go", "ledger/ledger_test.go", "payments/refund.go", "payments/refund_test.go"]
        for (index, path) in reads.enumerated() {
            messages.append(ActivityThreads.tool("r\(index)", "read", ["path": path], output: "line\nline", start: t + Double(index) * 200, end: t + Double(index) * 200 + 120))
        }
        messages.append(ActivityThreads.tool("g1", "grep", ["pattern": "RefundEvent", "path": "ledger/"], output: "ledger/events.go:12", start: t + 1_400, end: t + 1_500))
        messages.append(ActivityThreads.edit("e1", "ledger/outbox.go", added: 52, removed: 8, at: t + 20_000))
        messages.append(ActivityThreads.edit("e2", "ledger/events.go", added: 30, removed: 4, at: t + 22_000))
        messages.append(ActivityThreads.edit("e3", "payments/refund.go", added: 6, removed: 0, at: t + 24_000))
        messages.append(ActivityThreads.assistant("a1", "The outbox now emits `refund.created` and `refund.settled`. Running the ledger tests before I touch the consumer.",
                                                  at: t + 30_000))
        return messages
    }

    static func snapshot(_ messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [], running: Bool) -> NativeThreadSnapshot {
        var snapshot = ActivityThreads.snapshot(messages, provisional: provisional, running: running)
        snapshot.supportedActions.append("queue")
        snapshot.queue = NativeQueue(mode: .all)
        return snapshot
    }

    /// QueueStack and QueueEdit: the tests running.
    static var running: NativeThreadSnapshot {
        let t0 = now - 3 * 60_000
        return snapshot(opening(at: t0), provisional: [
            ActivityThreads.tool("p1", "bash", ["command": "go test ./ledger/..."], start: now - 18_000, end: nil, status: "running"),
        ], running: true)
    }

    /// QueueSteer: the tests passed, a test file started, a message steered in, and pi editing
    /// the way it asked.
    static var steered: NativeThreadSnapshot {
        let t0 = now - 5 * 60_000
        var messages = opening(at: t0)
        messages.append(ActivityThreads.tool("b1", "bash", ["command": "go test ./ledger/..."], output: "ok  ledger  0.8s\n41 passed",
                                             start: t0 + 40_000, end: t0 + 62_000))
        messages.append(ActivityThreads.tool("w1", "write", ["path": "ledger/refund_test.go", "content": (0..<34).map { "line \($0)" }.joined(separator: "\n")],
                                             output: "Wrote 34 lines.", start: t0 + 70_000, end: t0 + 71_000))
        messages.append(NativeThreadMessage(entryID: "user:steer", role: "user",
                                            blocks: [NativeThreadBlock(kind: .text, text: "Use table-driven tests, like ledger_test.go.")],
                                            timestamp: now - 60_000, origin: .steered))
        messages.append(ActivityThreads.assistant("a2", "Switching `refund_test.go` to a table of cases, the same shape as `ledger_test.go`.",
                                                  at: now - 50_000))
        return snapshot(messages, provisional: [
            ActivityThreads.tool("p2", "edit", ["path": "ledger/refund_test.go", "edits": [["oldText": "a", "newText": "b"]]],
                                 start: now - 6_000, end: nil, status: "running"),
        ], running: true)
    }

    /// The thread: a steered message inside the finished turn, then two queued messages that
    /// arrived as one, and pi thinking about them.
    static var delivered: NativeThreadSnapshot {
        let t0 = now - 9 * 60_000
        var messages = opening(at: t0)
        messages.append(ActivityThreads.tool("b1", "bash", ["command": "go test ./ledger/..."], output: "ok  ledger  0.8s\n41 passed",
                                             start: t0 + 40_000, end: t0 + 62_000))
        messages.append(ActivityThreads.tool("w1", "write", ["path": "ledger/refund_test.go", "content": "a\nb"],
                                             output: "Wrote 34 lines.", start: t0 + 70_000, end: t0 + 71_000))
        messages.append(NativeThreadMessage(entryID: "user:steer", role: "user",
                                            blocks: [NativeThreadBlock(kind: .text, text: "Use table-driven tests, like ledger_test.go.")],
                                            timestamp: t0 + 300_000, origin: .steered))
        messages.append(ActivityThreads.edit("e4", "ledger/refund_test.go", added: 40, removed: 34, at: t0 + 320_000))
        messages.append(ActivityThreads.assistant("a2", "Refund events are in the outbox and all 41 ledger tests pass.", at: t0 + 420_000))
        let parts = [NativeQueuePart(text: "Also cover partial refunds in the tests.", sentAt: t0 + 120_000),
                     NativeQueuePart(text: "Then open a draft PR.", sentAt: t0 + 180_000)]
        messages.append(NativeThreadMessage(entryID: "user:queue", role: "user",
                                            blocks: [NativeThreadBlock(kind: .text, text: parts.map(\.text).joined(separator: "\n\n"))],
                                            timestamp: t0 + 421_000, origin: .queue(parts: parts)))
        return snapshot(messages, provisional: [
            NativeThreadMessage(entryID: "provisional:assistant:9", role: "assistant",
                                blocks: [NativeThreadBlock(kind: .thinking, text: "Partial refunds first.")],
                                status: "streaming", timestamp: now - 3_000, thinkingSeconds: 3),
        ], running: true)
    }
}
