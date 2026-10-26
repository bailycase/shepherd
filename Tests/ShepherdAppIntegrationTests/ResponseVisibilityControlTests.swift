import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Response visibility controls", .integrationTimeLimit)
struct ResponseVisibilityControlTests {
    @Test func liveThinkingOpensItsSharedSummaryWithoutAFinishedFooter() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.openingSummary() }
        }
        expectScenarioCompleted(result)
    }

    @Test func timingOpensAfterTheUnchangedCopyAndRetryActions() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.openingTiming() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor static func openingSummary() async throws {
        AccessibilityNode.enable()
        let now = Date.now.timeIntervalSince1970 * 1000
        var reply = NativeThreadMessage(entryID: "live", role: "assistant", blocks: [
            NativeThreadBlock(kind: .thinking, text: "**Choosing a screen**\n\nCompared both placements.")
        ], status: "streaming", timestamp: now)
        reply.timing = NativeResponseTiming(sentAt: now - 31_000, firstEventAt: now - 30_000, firstThinkingAt: now - 30_000)
        let presentation = nativeTurnPresentation([reply], live: true)
        let window = OffscreenWindow(size: CGSize(width: 820, height: 400), dark: true,
                                    AgentTurn(presentation: presentation, live: true, retry: {}))
        defer { window.close() }
        let before = try #require(window.controls().first { $0.label == "Thinking" })
        #expect(before.value == "Collapsed")
        #expect(!window.controls().contains { $0.label == "Copy response" || $0.label == "Response timing" })
        try window.press("Thinking")
        try await eventuallyOnMain("the live summary to open") {
            window.controls().first { $0.label == "Thinking" }?.value == "Expanded"
        }
        try window.press("Thinking")
        try await eventuallyOnMain("the live summary to fold") {
            window.controls().first { $0.label == "Thinking" }?.value == "Collapsed"
        }
        #expect(!window.window.isKeyWindow)
    }

    @MainActor static func openingTiming() async throws {
        AccessibilityNode.enable()
        let timing = NativeResponseTiming(sentAt: 1_000, headersAt: 2_200, firstEventAt: 2_400,
                                          firstThinkingAt: 2_400, firstTextAt: 32_800, endedAt: 46_000)
        let report = try #require(NativeResponseTimingReport(timing, hasText: true))
        var copied = 0
        var retried = 0
        let window = OffscreenWindow(size: CGSize(width: 820, height: 600), dark: false,
            NWTurnFooter(meta: "45s", onCopy: { copied += 1 }, onRetry: { retried += 1 },
                         timing: NWResponseTimingModel(report), revealed: true).padding(NW.Space.xl))
        defer { window.close() }
        let controls = window.controls()
        let copy = try #require(controls.first { $0.label == "Copy response" })
        let retry = try #require(controls.first { $0.label == "Retry turn" })
        let button = try #require(controls.first { $0.label == "Response timing" })
        #expect(copy.frame.minX < retry.frame.minX && retry.frame.minX < button.frame.minX)
        #expect(ControlPress.undersized([button], minimum: .desktop).isEmpty)
        try window.press("Copy response")
        try window.press("Retry turn")
        #expect(copied == 1 && retried == 1)
        try window.press("Response timing")
        try await eventuallyOnMain("the standard timing popover to open") {
            window.controls().first { $0.label == "Response timing" }?.value == "Expanded"
        }
        #expect(!window.window.isKeyWindow)
        // Toggle the presenting button again; native dismissal also clears this binding.
        try window.press("Response timing")
        try await eventuallyOnMain("the standard timing popover to close") {
            window.controls().first { $0.label == "Response timing" }?.value == "Collapsed"
        }
    }
}
