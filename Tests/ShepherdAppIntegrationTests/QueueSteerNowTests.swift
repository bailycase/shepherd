import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Steer now on the first queued row at rest (decided by the user, 2026-10-01): a labelled button
/// that is there while pi works, pressed the way VoiceOver presses (`ControlPress`) and never with
/// a posted event. SwiftUI draws the accessibility tree only for a process an assistive client is
/// attached to, so each scenario runs in a process of its own.
///
/// The Mac's rows are one accessibility element each (their controls are the element's actions), so
/// the button itself is pressed on the component, where it is a control of its own, and what a row
/// of the real stack reaches is pressed through its action menu.
@Suite("Steer now at rest", .integrationTimeLimit)
struct QueueSteerNowTests {
    @Test func theLabelledButtonIsPressedAtRestAndStaysPutWhenTheRowIsHovered() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheButton() }
        }
    }

    @Test func aRowOfTheStackSteersTheHostInByItsOwnMessage() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.steeringFromTheStack() }
        }
    }

    @MainActor
    private final class Log {
        var steered = 0
        var edited = 0
        var deleted = 0
    }

    private static let text = "Also cover partial refunds in the tests."

    @MainActor
    private static func row(_ log: Log, hovering: Bool, labelled: Bool, running: Bool = true) -> some View {
        NWQueueRow(text, kind: .queued(number: 1), hovering: hovering, actions: NWQueueRowActions(
            steer: { log.steered += 1 }, steerLabel: NativeQueueStack.steerLabel(running: running), steerShortcut: "⌘↩",
            steerHelp: running ? NativeSendChoice.steerNowHelp : "Send this now", steerLabelled: labelled,
            edit: { log.edited += 1 }, delete: { log.deleted += 1 }, deleteShortcut: "⌫"))
            .frame(width: 520)
            .background(Color.nw.bgRaised)
    }

    /// At rest the button is a control with the words Steer now and a desktop hit area, and pressing it
    /// steers. Hovering adds Edit and Delete before it without moving it or the message's own button
    /// (so nothing re-truncates), a row that is not the first draws no button at rest, and an idle row's
    /// is Send now.
    @MainActor
    static func pressingTheButton() async throws {
        AccessibilityNode.enable()
        let log = Log()
        let window = OffscreenWindow(size: CGSize(width: 520, height: 40), dark: false, row(log, hovering: false, labelled: true))
        defer { window.close() }

        let atRest = window.controls()
        let steer = try #require(atRest.first { $0.label == "Steer now" }, "Steer now is drawn without the pointer: \(atRest)")
        #expect(!atRest.contains { $0.label == "Edit" || $0.label == "Delete" }, "Edit and Delete wait for the pointer: \(atRest)")
        let message = try #require(atRest.first { $0.label == text }, "the text is the row's Edit button: \(atRest)")
        #expect(ControlPress.undersized([steer], minimum: .desktop).isEmpty, "Steer now has a desktop hit area: \(steer)")

        try window.press("Steer now")
        #expect(log.steered == 1, "pressing it steers")

        window.show(row(log, hovering: true, labelled: true))
        let hovered = window.controls()
        let labels = hovered.compactMap(\.label)
        #expect(labels.contains("Steer now") && labels.contains("Edit") && labels.contains("Delete"), "hovered: \(labels)")
        let steerAfter = try #require(hovered.first { $0.label == "Steer now" })
        let messageAfter = try #require(hovered.first { $0.label == text })
        #expect(steerAfter.frame == steer.frame, "Steer now did not move when Edit and Delete came in: \(steer.frame) → \(steerAfter.frame)")
        #expect(messageAfter.frame.width == message.frame.width, "the message did not re-truncate: \(message.frame.width) → \(messageAfter.frame.width)")
        #expect(ControlPress.undersized(hovered.filter { $0.label == "Edit" || $0.label == "Delete" }, minimum: .desktop).isEmpty)

        try window.press("Delete")
        try window.press("Edit")
        try window.press("Steer now")
        #expect(log.steered == 2 && log.edited == 1 && log.deleted == 1, "each control reached its own action")

        // Any other row keeps the hover icons only.
        window.show(row(log, hovering: false, labelled: false))
        #expect(!window.controls().contains { $0.label == "Steer now" }, "a row that is not the first draws no button at rest")
        window.show(row(log, hovering: false, labelled: false, running: false))
        #expect(!window.controls().contains { $0.label == "Send now" || $0.label == "Steer now" }, "an idle row draws none at rest")
        window.show(row(log, hovering: true, labelled: false, running: false))
        try window.press("Send now")
        #expect(log.steered == 3, "idle, hovered, its Steer now is Send now")
    }

    /// Through the real stack, the first queued row's action menu (what VoiceOver offers in place of
    /// the hover buttons) and any other row's each ask the host to interrupt for that message alone.
    @MainActor
    static func steeringFromTheStack() async throws {
        AccessibilityNode.enable()
        let thread = QueueThread(queue: QueueFixture.messages(["Also cover partial refunds in the tests.", "Use table-driven tests, like ledger_test.go.",
                                                              "Then open a draft PR."]), interrupts: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let ids = thread.host.queue.map(\.id)

        let first = ControlPress.actions(onLabelContaining: "Queued 1 of 3", under: thread.window.host)
        #expect(Set(first) == ["Steer now", "Edit", "Delete", "Move up", "Move down"], "a queued row's actions: \(first)")
        try ControlPress.perform("Steer now", onLabelContaining: "Queued 1 of 3", under: thread.window.host)
        try await eventuallyOnMain("the host to be asked to interrupt for the first message") {
            thread.host.actions.contains(.interrupt(ids: [ids[0]]))
        }
        try await thread.settle()
        #expect(thread.host.sends.isEmpty, "Steer now sent nothing new: it moved a queued message")
    }
}
