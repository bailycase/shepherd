import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// "Up next" in a real `ThreadView`, off screen: the stack grows upward from a card that never
/// moves while the thread keeps its tail in view, a hovered message shows its actions in place,
/// the Send menu floats over the thread, and the keyboard paths reach the host. Hover is seeded,
/// handlers are called directly, and events are built but never posted.
@Suite("Queue stack", .serialized, .mainActorExclusive)
@MainActor
struct QueueStackIntegrationTests {
    static let texts = ["Also cover partial refunds in the tests.", "Use table-driven tests, like ledger_test.go.", "Then open a draft PR."]

    /// The stack's height over the card: its header, its rows, and the gap to the card.
    static func stackHeight(rows: Int) -> CGFloat {
        NWQueueMetrics.headerHeight + CGFloat(rows) * NWQueueMetrics.rowHeight + AppLayout.menuGap
    }

    @Test func theStackGrowsUpwardFromACardThatStaysPut() async throws {
        let thread = QueueThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset
        let cardTop = thread.size.height - inset
        let card = CGRect(x: 0, y: cardTop, width: thread.size.width, height: inset)
        let before = FrameTimer.capture(thread.window, card)
        #expect(thread.isPinned)

        await thread.publish(QueueFixture.messages(Array(Self.texts.prefix(2))))
        try await thread.settle()

        #expect(thread.composerInset == inset + Self.stackHeight(rows: 2), "the stack sits on the card and the thread's inset follows it")
        #expect(FrameTimer.capture(thread.window, card) == before, "the card never moved")
        #expect(thread.isPinned, "the thread keeps its last turn in view above the stack")

        // pi takes both: the stack leaves, and the card still has not moved.
        await thread.publish([])
        try await thread.settle()
        #expect(thread.composerInset == inset)
        #expect(FrameTimer.capture(thread.window, card) == before)
        #expect(thread.isPinned)
    }

    /// A hovered message shows its grip, fill and actions in place: nothing outside its row
    /// changes, and nothing moves.
    @Test func hoveringAMessageShowsItsActionsInPlace() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset
        let stackTop = thread.size.height - inset
        let row = CGRect(x: thread.columnLeading, y: stackTop + NWQueueMetrics.headerHeight + NWQueueMetrics.rowHeight,
                         width: thread.columnTrailing - thread.columnLeading, height: NWQueueMetrics.rowHeight)
        let whole = CGRect(origin: .zero, size: thread.size)
        let before = FrameTimer.capture(thread.window, whole)

        thread.state.hover(thread.host.queue[1].id.uuidString).hovering = true
        try await thread.settle()

        #expect(thread.composerInset == inset, "hovering changes no height")
        let after = FrameTimer.capture(thread.window, whole)
        let changed = try #require(Pixels.bounds(differing: before, after, rows: 0..<Int(thread.size.height)), "the row changed")
        #expect(row.insetBy(dx: -1, dy: -1).contains(changed), "only the hovered row changed: \(changed) in \(row)")
        let actions = CGRect(x: row.maxX - NW.Space.s - NWQueueMetrics.actionsWidth, y: row.minY, width: NWQueueMetrics.actionsWidth,
                             height: row.height)
        let solid = try #require(Pixels.bounds(differing: before, after, rows: Int(row.minY)..<Int(row.maxY), by: 0.15))
        #expect(solid.maxX > actions.minX, "its actions show at the trailing end: \(solid)")

        thread.state.hover(thread.host.queue[1].id.uuidString).hovering = false
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, whole) == before, "leaving it puts everything back")
    }

    /// Right-clicking Send while pi works opens the Send menu over the thread above the card's
    /// trailing corner: the composer's height and the thread's scroll stay where they were.
    @Test func theSendMenuFloatsOverTheThread() async throws {
        let thread = QueueThread(draft: "Keep the PR title under 60 characters")
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset, offset = thread.threadOffset
        let cardTop = thread.size.height - inset
        let above = CGRect(x: 0, y: 0, width: thread.size.width, height: cardTop - NWComposerMetrics.focusRing - 1)
        let before = FrameTimer.capture(thread.window, above)
        let send = try #require(thread.sendButton, "Send stands beside an outlined Stop while pi works with a draft")

        send.rightMouseDown(with: QueueThread.rightClick)
        try await thread.settle()

        #expect(thread.composerInset == inset && thread.threadOffset == offset)
        let menu = try #require(Pixels.bounds(differing: before, FrameTimer.capture(thread.window, above), rows: 0..<Int(above.height), by: 0.11),
                                "the menu opened")
        #expect(abs(menu.maxX - thread.columnTrailing) <= 2, "at the card's trailing edge: \(menu)")
        #expect(abs(menu.maxY - (cardTop - AppLayout.menuGap)) <= 2, "8pt above the card: \(menu)")
        #expect(abs(menu.width - NWQueueMetrics.sendMenuWidth) <= 2, "the menu's own width: \(menu)")
    }

    /// Where the thread has room beside the card, the Send menu stands there (as the boards
    /// draw it), bottom-aligned with the card, and covers none of Up next above it.
    @Test func theSendMenuStandsBesideTheCardWhereThereIsRoom() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Array(Self.texts.prefix(2))), draft: "Keep the PR title under 60 characters",
                                 size: CGSize(width: 1500, height: 700))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset, offset = thread.threadOffset
        let stack = CGRect(x: thread.columnLeading, y: thread.size.height - inset, width: thread.columnTrailing - thread.columnLeading,
                           height: Self.stackHeight(rows: 2) - AppLayout.menuGap)
        let beside = CGRect(x: thread.columnTrailing + 1, y: 0, width: thread.size.width - thread.columnTrailing - 1, height: thread.size.height)
        let (stackBefore, besideBefore) = (FrameTimer.capture(thread.window, stack), FrameTimer.capture(thread.window, beside))
        let send = try #require(thread.sendButton)

        send.rightMouseDown(with: QueueThread.rightClick)
        try await thread.settle()

        #expect(thread.composerInset == inset && thread.threadOffset == offset)
        let found = Pixels.bounds(differing: besideBefore, FrameTimer.capture(thread.window, beside), rows: 0..<Int(beside.height), by: 0.11)
        let menu = try #require(found, "the menu opened beside the card").offsetBy(dx: beside.minX, dy: 0)
        #expect(abs(menu.minX - (thread.columnTrailing + AppLayout.menuGap)) <= 2, "8pt after the card's trailing edge: \(menu)")
        #expect(abs(menu.maxY - (thread.size.height - AppLayout.composerBottom)) <= 2, "bottom-aligned with the card: \(menu)")
        #expect(abs(menu.width - NWQueueMetrics.sendMenuWidth) <= 2, "the menu's own width: \(menu)")
        // Only the menu's shadow may reach it.
        let covered = Pixels.bounds(differing: stackBefore, FrameTimer.capture(thread.window, stack), rows: 0..<Int(stack.height), by: 0.11)
        #expect(covered == nil, "Up next stays uncovered: \(String(describing: covered)) in \(stack)")
    }

    // MARK: Keys

    /// ⌘↩ in the composer is Steer now, ahead of any key equivalent in the window (the review
    /// pane's ⌘⏎); another window's ⌘↩ is not the composer's. This host cannot stop pi, so Steer
    /// now falls back to steering the draft in, and its row reads Steering until pi reads it.
    @Test func theAlternateSendStillSteersWhereTheHostCannotStopPi() async throws {
        let thread = QueueThread(queue: QueueFixture.messages([Self.texts[0]]), draft: "Don’t touch the migrations in this PR.")
        defer { thread.close() }
        try await thread.waitUntilReady()
        let monitor = try #require(thread.keyMonitor)
        let other = OffscreenWindow(size: CGSize(width: 100, height: 100))
        defer { other.close() }
        let elsewhere = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                         windowNumber: other.window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!

        #expect(!monitor.handle(elsewhere), "another window's ⌘↩ passes by")
        #expect(!monitor.handle(thread.key("\r", keyCode: 36)), "a plain ↩ is the field's")
        let draft = thread.store.draft
        thread.store.draft = "  "
        #expect(!monitor.handle(thread.key("\r", keyCode: 36, modifiers: .command)), "with nothing to send it goes on to the window")
        thread.store.draft = draft
        #expect(monitor.handle(thread.key("\r", keyCode: 36, modifiers: .command)))
        try await eventuallyOnMain("the draft to be steered in") { thread.host.sends.count == 1 }

        #expect(thread.host.sends.first?.delivery == .steer)
        #expect(thread.host.sends.first?.text == "Don’t touch the migrations in this PR.")
        try await eventuallyOnMain("the steering row to show") { thread.state.rows.first?.kind == .steering }
        #expect(thread.store.draft.isEmpty)
    }

    /// Return while pi works queues the draft: the host is sent a follow-up, and the stack shows
    /// it as a queued row behind what waits, never as Steering. This sends as the composer's
    /// ↩ does (`ComposerSendKey.primary`), on a host that can also stop pi.
    @Test func returnQueuesTheDraftAndNeverDrawsASteeringRow() async throws {
        let draft = "Don’t touch the migrations in this PR."
        let thread = QueueThread(queue: QueueFixture.messages([Self.texts[0]]), draft: draft, interrupts: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        #expect(thread.store.hostInterrupts)

        let sent = await thread.store.send(delivery: ComposerSendKey.primary.delivery)

        #expect(sent)
        try await eventuallyOnMain("the draft to wait in Up next") { thread.state.rows.count == 2 }
        #expect(thread.host.sends.map(\.delivery) == [.followUp])
        #expect(thread.host.sends.first?.text == draft)
        #expect(thread.state.rows.map(\.kind) == [.queued(number: 1), .queued(number: 2)], "it waits its turn behind the first")
        #expect(thread.host.queue.map(\.text) == [Self.texts[0], draft])
        #expect(thread.host.queue.allSatisfy { $0.state == .queued })
        #expect(thread.host.aborts == 0, "nothing was stopped")
        #expect(thread.store.draft.isEmpty)
    }

    /// ⌘↩ on a host that stops pi is Steer now: the host is sent an interrupt, and the draft is
    /// first in Up next, still queued, until the host has sent it. No row ever reads Steering.
    @Test func theAlternateSendInterruptsAndNeverDrawsASteeringRow() async throws {
        let draft = "Stop, and use the ledger fixtures instead."
        let thread = QueueThread(queue: QueueFixture.messages([Self.texts[0]]), draft: draft, interrupts: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let monitor = try #require(thread.keyMonitor)

        #expect(monitor.handle(thread.key("\r", keyCode: 36, modifiers: .command)))
        try await eventuallyOnMain("the draft to be sent") { thread.host.sends.count == 1 }

        #expect(thread.host.sends.first?.delivery == .interrupt)
        #expect(thread.host.sends.first?.text == draft)
        try await eventuallyOnMain("the draft to lead Up next") { thread.host.queue.first?.text == draft }
        #expect(thread.state.rows.map(\.kind) == [.queued(number: 1), .queued(number: 2)])
        #expect(thread.host.queue.allSatisfy { $0.state == .queued })
        #expect(thread.store.draft.isEmpty)
    }

    /// Steer now on a queued row, and Steer all now, ask the host to interrupt: the messages go
    /// first in Up next as queued rows, in order, and nothing is marked Steering.
    @Test func steerNowOnQueuedRowsInterruptsAndNeverDrawsASteeringRow() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts), interrupts: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let ids = thread.host.queue.map(\.id)

        thread.state.steer([ids[2]], running: true, store: thread.store)
        try await eventuallyOnMain("the interrupt to reach the host") { thread.host.actions.contains(.interrupt(ids: [ids[2]])) }
        try await eventuallyOnMain("the message to lead Up next") { thread.host.queue.first?.id == ids[2] }
        #expect(thread.state.rows.map(\.kind) == [.queued(number: 1), .queued(number: 2), .queued(number: 3)])
        #expect(thread.host.queue.allSatisfy { $0.state == .queued })

        thread.state.steerAll(running: true, store: thread.store)
        try await eventuallyOnMain("every message to be interrupted for") { thread.host.actions.contains(.interrupt(ids: [ids[2], ids[0], ids[1]])) }
        #expect(thread.host.queue.map(\.id) == [ids[2], ids[0], ids[1]], "in the order they were")
        #expect(thread.host.queue.allSatisfy { $0.state == .queued })
        #expect(!thread.host.actions.contains { if case .steer = $0 { true } else { false } }, "nothing asked the host to steer")
        #expect(thread.state.rows.allSatisfy { $0.kind != .steering })
    }

    /// ↑ in an empty composer opens the editor on the last queued message and holds the queue;
    /// saving edits it in place on the host.
    @Test func upEditsTheLastQueuedMessage() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset
        let last = thread.host.queue[2].id

        #expect(thread.state.editLast(store: thread.store))
        try await eventuallyOnMain("the host to hold the queue") { thread.host.actions.contains(.hold(id: last, held: true)) }
        try await thread.settle()
        #expect(thread.composerInset > inset, "the editor grows the stack upward")
        #expect(thread.state.rows.map(\.kind).last == .editing(number: 3))

        thread.state.draft = "Then open a draft PR against nightly."
        thread.state.saveEdit(store: thread.store)
        try await eventuallyOnMain("the edit to reach the host") {
            thread.host.queue.last?.text == "Then open a draft PR against nightly."
        }
        #expect(thread.host.actions.contains(.edit(id: last, text: "Then open a draft PR against nightly.")))
        try await thread.settle()
        #expect(thread.composerInset == inset, "the row closes back to its place")
    }

    /// A focused message's keys: ⌥↓ moves it, ⌘↩ steers it, ⌫ deletes it with Undo in its place,
    /// and Undo puts it back where it was.
    @Test func aFocusedMessagesKeysReachTheHost() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let (first, second, third) = (thread.host.queue[0].id, thread.host.queue[1].id, thread.host.queue[2].id)
        func handle(_ key: QueueRowKey, _ id: UUID) -> QueueFocus {
            thread.state.handle(key, on: id.uuidString, running: true, store: thread.store)
        }

        #expect(handle(.moveDown, first) == .row(first.uuidString), "focus moves with the message")
        try await eventuallyOnMain("the move to reach the host") { thread.host.queue.map(\.id) == [second, first, third] }

        #expect(handle(.steer, third) == .row(third.uuidString))
        try await eventuallyOnMain("the steer to reach the host") { thread.host.queue.first?.id == third }
        #expect(thread.host.queue.first?.state == .steering)

        #expect(handle(.delete, first) == .row(second.uuidString), "focus goes to its neighbour")
        try await eventuallyOnMain("the delete to reach the host") { !thread.host.queue.contains { $0.id == first } }
        try await thread.settle()
        #expect(thread.state.rows.map(\.kind) == [.steering, .queued(number: 1), .deleted(Self.texts[0])])

        thread.state.undo(first.uuidString, store: thread.store)
        try await eventuallyOnMain("the message to come back") { thread.host.queue.map(\.id) == [third, second, first] }
        try await thread.settle()
        #expect(thread.state.rows.map(\.kind) == [.steering, .queued(number: 1), .queued(number: 2)])

        // Back to the queue: the steering message returns as #1.
        thread.state.unsteer(third, store: thread.store)
        try await eventuallyOnMain("the unsteer to reach the host") { thread.host.queue.first?.state == .queued }
        #expect(thread.host.queue.map(\.id) == [third, second, first])
    }

    /// An Undo row closes when its window passes, but not while the pointer is on it.
    @Test func anUndoRowWaitsWhileHovered() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let first = thread.host.queue[0].id
        thread.state.delete(first, store: thread.store)
        try await eventuallyOnMain("the delete to reach the host") { thread.host.queue.count == 2 }
        let later = ContinuousClock.now + AppLayout.queueUndoWindow + .seconds(1)

        thread.state.hover(first.uuidString).hovering = true
        thread.state.expireUndo(at: later)
        #expect(thread.state.undo.count == 1, "hovered, it stays")

        thread.state.hover(first.uuidString).hovering = false
        thread.state.expireUndo(at: later + AppLayout.queueUndoWindow + .seconds(1))
        #expect(thread.state.undo.isEmpty, "its window starts over once the pointer leaves, then closes")
        #expect(thread.state.rows.map(\.kind) == [.queued(number: 1), .queued(number: 2)])
    }

    /// Clearing leaves one Undo row; Steer all now steers every queued message in order.
    @Test func clearAndSteerAllReachTheHost() async throws {
        let thread = QueueThread(queue: QueueFixture.messages(Self.texts))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let ids = thread.host.queue.map(\.id)

        thread.state.clear(store: thread.store)
        try await eventuallyOnMain("the clear to reach the host") { thread.host.queue.isEmpty }
        #expect(thread.state.rows.map(\.kind) == [.cleared(3)])
        let cleared = try #require(thread.state.undo.first?.id)
        thread.state.undo(cleared, store: thread.store)
        try await eventuallyOnMain("the queue to come back") { thread.host.queue.map(\.id) == ids }

        thread.state.steerAll(running: true, store: thread.store)
        try await eventuallyOnMain("every message to steer") { thread.host.queue.allSatisfy { $0.state == .steering } }
        #expect(thread.host.queue.map(\.id) == ids, "in order")
    }
}
