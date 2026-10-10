import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's corner button and the model settings popover's click-away, over the real
/// composer in an off-screen window. The corner is pressed the way VoiceOver presses
/// (`ControlPress`, one process per scenario); a click is handed to the dismissal watcher as an
/// event that is built, never posted. Nothing takes focus or moves the pointer.
@Suite("Composer corner button and click-away", .integrationTimeLimit)
struct ComposerActionAndDismissTests {
    @Test func whileWorkingWithNothingToSendTheCornerIsStopAndAbortsTheTurn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.stopping() }
        }
    }

    @Test func whileWorkingWithWordsOrAnImageTheCornerIsSendAndQueues() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.queueing() }
        }
    }

    @Test func whileIdleTheCornerIsSend() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.idle() }
        }
    }

    @Test func aClickInTheFieldClosesTheModelSettingsAndAClickOnItsChipDoesNot() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.clickingAway() }
        }
    }

    /// The Mac's own corner, through every change of input and of the turn that could leave it stale:
    /// the row compares its model before it redraws, so each step is read from the window.
    @Test func theCornerFollowsTheTurnAndTheInputThroughEveryChange() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.following() }
        }
    }

    // MARK: Scenarios

    private static let chip = "Model settings: anthropic/claude-opus-4-5"

    @MainActor
    static func labels(_ thread: ComposerThread) -> [String] {
        thread.window.controls().compactMap(\.label)
    }

    @MainActor
    static func stopping() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(running: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the thread to be working") { thread.store.running }
        thread.window.layout()
        let labels = Self.labels(thread)
        #expect(labels.contains("Stop") && !labels.contains("Send"), "an empty field shows Stop alone: \(labels)")

        let stop = try thread.window.press("Stop")
        #expect(stop.isEnabled && stop.frame.width >= 24 && stop.frame.height >= 24)
        try await eventuallyOnMain("the host to be told to abort") {
            thread.requests.contains { if case .abort = $0 { true } else { false } }
        }
    }

    /// Words, then an attached image alone: each is input, so the corner is Send beside an outlined Stop.
    @MainActor
    static func queueing() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(running: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the thread to be working") { thread.store.running }

        thread.store.draft = "also check the tests"
        try await eventuallyOnMain("Send to take the corner") { thread.window.layout(); return Self.labels(thread).contains("Send") }
        #expect(Self.labels(thread).contains("Stop"), "Stop steps aside, outlined, rather than going away")
        let send = try thread.window.press("Send")
        #expect(send.isEnabled)
        try await eventuallyOnMain("the message to be queued, not sent as a steer") {
            thread.requests.contains { if case .send(_, _, _, _, let delivery, _, _, _, _) = $0 { delivery == .followUp } else { false } }
        }

        // An attachment alone is input too.
        thread.store.draft = ""
        let image = ImageAttachment(name: "shot.png", image: NativeImage(mimeType: "image/png", data: Data([1, 2, 3])))
        thread.input.attachments.add([(image.name, image)])
        try await eventuallyOnMain("Send to stay with only an image") { thread.window.layout(); return Self.labels(thread).contains("Send") }
        #expect(Self.labels(thread).contains("Stop"))
    }

    @MainActor
    static func idle() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.window.layout()
        let labels = Self.labels(thread)
        #expect(labels.contains("Send") && !labels.contains("Stop"), "an idle thread offers Send only: \(labels)")
        #expect(thread.window.controls().first { $0.label == "Send" }?.isEnabled == false, "nothing to send yet, so Send is held")

        thread.store.draft = "hello"
        try await eventuallyOnMain("Send to open up") { thread.window.layout(); return thread.window.controls().first { $0.label == "Send" }?.isEnabled == true }
        try thread.window.press("Send")
        try await eventuallyOnMain("the message to be sent at once") {
            thread.requests.contains { if case .send = $0 { true } else { false } }
        }
    }

    /// The chip toggles its own popover and a click in the field is outside it. The click is
    /// handed to the watcher; the chip is pressed through the accessibility tree.
    @MainActor
    static func clickingAway() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        try thread.window.press(Self.chip)
        try await thread.settle()
        #expect(thread.window.element("Model, thinking and speed") != nil, "the popover is open")
        let dismissal = try #require(thread.menuDismissal)

        // Inside the popover: it stays, and so do its controls.
        dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop - AppLayout.menuGap - 20)))
        try await thread.settle()
        #expect(thread.window.element("Model, thinking and speed") != nil, "a click inside the popover leaves it open")

        // The chip toggles its own popover, so the watcher must leave that click to it.
        dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 60, y: thread.size.height - AppLayout.composerBottom - 14)))
        try await thread.settle()
        #expect(thread.window.element("Model, thinking and speed") != nil, "a click on the chip is the chip's own")

        // Blank space in the control row is outside the popover and its chip.
        let row = thread.size.height - AppLayout.composerBottom - 14
        dismissal.handle(thread.click(at: CGPoint(x: thread.size.width / 2, y: row)))
        try await eventuallyOnMain("the popover to close for a click on the blank row") {
            thread.window.layout(); return thread.window.element("Model, thinking and speed") == nil
        }

        // Open again: the field, near the card's top-left, away from the control row.
        try thread.window.press(Self.chip)
        try await eventuallyOnMain("the popover to open again") { thread.window.element("Model, thinking and speed") != nil }
        let again = try #require(thread.menuDismissal)
        again.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop + 20)))
        try await eventuallyOnMain("the popover to close for a click in the field") {
            thread.window.layout(); return thread.window.element("Model, thinking and speed") == nil
        }
    }
}

extension ComposerActionAndDismissTests {
    @MainActor
    static func following() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        func corner() -> [String] { thread.window.layout(); return labels(thread).filter { $0 == "Stop" || $0 == "Send" } }
        func expect(_ expected: [String], _ why: String) async throws {
            try await eventuallyOnMain(why) { corner() == expected }
        }
        try await expect(["Send"], "idle: Send")

        await thread.setRunning(true)
        try await eventuallyOnMain("the store to be running") { thread.store.running }
        try await expect(["Stop"], "a turn starts: Stop")

        // Whitespace is not input: the host would not send it, so Send has nothing and Stop stays.
        thread.store.draft = "  \n\t "
        try await Task.sleep(for: .milliseconds(150))
        try await expect(["Stop"], "only whitespace: still Stop")

        thread.store.draft = "also this"
        try await expect(["Stop", "Send"], "words: Stop steps aside, Send takes the corner")
        thread.store.draft = ""
        try await expect(["Stop"], "words cleared: Stop is back in the corner")

        let image = ImageAttachment(name: "shot.png", image: NativeImage(mimeType: "image/png", data: Data([1, 2, 3])))
        thread.input.attachments.add([(image.name, image)])
        try await expect(["Stop", "Send"], "an attachment is input")
        thread.input.attachments.remove(image.id)
        try await expect(["Stop"], "attachment removed: Stop again")

        thread.store.draft = "typed"
        try await expect(["Stop", "Send"], "typed again")
        await thread.setRunning(false)
        try await eventuallyOnMain("the turn to settle idle") { !thread.store.running }
        try await expect(["Send"], "the turn ended with words typed: Send alone")
        thread.store.draft = ""
        await thread.setRunning(true)
        try await expect(["Stop"], "the next turn starts with nothing typed: Stop")
    }
}
