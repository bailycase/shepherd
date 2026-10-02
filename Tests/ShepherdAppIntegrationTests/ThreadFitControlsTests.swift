import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The controls of a thread whose rows once ran off its pane, pressed the way VoiceOver presses
/// (`ControlPress`, in a process of its own: nothing is posted to the window). In a design's chat
/// at its real width, with an activity line naming three boards and a compaction, Show summary and
/// the activity line are in reach (inside the column, where a click lands) and do what they do.
@Suite("Thread controls at the design chat's width", .integrationTimeLimit)
struct ThreadFitControlsTests {
    @Test func showSummaryIsInReachAndOpensWhatTheAgentKept() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.openingTheSummary() }
        }
    }

    @Test func anActivityLineNamingBoardsIsInReachAndOpensItsCalls() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.openingTheCalls() }
        }
    }

    // MARK: Scenarios

    /// `comment`: the first message is a pinned comment, whose card ends at the compaction (so the
    /// compaction is not in the row of the line above it); else one reply holds them both.
    @MainActor
    static func chat(comment: Bool) async throws -> FakeThread {
        typealias L = LongThreads
        var messages: [NativeThreadMessage] = [L.user("u", L.prompt, origin: comment ? .designComment(id: L.commentID) : nil), L.assistant("a", "Working on it.")]
        messages += L.boards.enumerated().map { index, board in
            L.tool("e\(index)", "board_edit", ["path": "\(board).dc.html", "edits": [["find": "<div>", "replace": "<nav>"]]],
                   output: "Edited \(board).dc.html · 1 edit, 1 match", at: L.start + 2_000 + Double(index) * 500)
        }
        messages += [L.compaction("c", reason: .threshold), L.assistant("b", "Picking up from the summary.", at: L.start + 5_000)]
        let thread = FakeThread(ThreadFixture.snapshot(messages), size: CGSize(width: AppLayout.designChatWidth, height: 900), dark: false,
                                designCards: DesignChatFixture.cards())
        try await thread.waitUntilReady()
        return thread
    }

    /// Whether the control's frame lies inside the thread's column: the window's width less a gutter
    /// each side (AX frames are in screen coordinates, and the window is far off every screen).
    @MainActor
    static func isInTheColumn(_ control: Control, in thread: FakeThread) -> Bool {
        let window = thread.window.window.frame
        let gutter = AppLayout.threadGutter(width: window.width)
        return control.frame.minX >= window.minX + gutter - 5 && control.frame.maxX <= window.maxX - gutter + 5
    }

    /// Show summary: drawn inside the column (it was the line's far end, cut off), pressed, it opens
    /// what the agent kept and reads Hide.
    @MainActor
    static func openingTheSummary() async throws {
        AccessibilityNode.enable()
        let thread = try await chat(comment: false)
        defer { thread.close() }
        let show = "Show what the agent kept"
        let before = try #require(thread.window.controls().first { $0.label == show }, "Show summary is drawn")
        #expect(isInTheColumn(before, in: thread), "Show summary is inside the column: \(before.frame) in \(thread.window.window.frame)")
        #expect(before.isEnabled && before.frame.width >= 24 && before.frame.height >= 16, "a hit area as the line draws it: \(before)")
        #expect(!thread.store.compactions.isExpanded("c"))

        try thread.window.press(show)
        try await eventuallyOnMain("the summary to open") { thread.store.compactions.isExpanded("c") }
        ListPerf.settle(thread.window)
        let after = try #require(thread.window.controls().first { $0.label == "Hide what the agent kept" }, "it now offers Hide")
        #expect(isInTheColumn(after, in: thread))
        #expect(thread.window.controls().allSatisfy { $0.label != show }, "Show is gone while it is open")
    }

    /// The line naming the boards: inside the column, a real button, and pressed it opens the calls
    /// (one row per board), which fit the column too.
    @MainActor
    static func openingTheCalls() async throws {
        AccessibilityNode.enable()
        let thread = try await chat(comment: true)
        defer { thread.close() }
        let line = try #require(thread.window.controls().first { $0.label?.hasPrefix("Updated withdrawals-mobile-approve") == true },
                                "the line naming the boards is a button")
        #expect(isInTheColumn(line, in: thread), "the line is inside the column: \(line.frame)")
        #expect(line.value == "Collapsed")

        try thread.window.press(try #require(line.label))
        ListPerf.settle(thread.window)
        let opened = try #require(thread.window.controls().first { $0.label?.hasPrefix("Updated withdrawals-mobile-approve") == true })
        #expect(opened.value == "Expanded")
        let calls = thread.window.controls().filter { $0.label?.hasPrefix("board, withdrawals-") == true }
        #expect(calls.count == LongThreads.boards.count, "one call row per board: \(thread.window.controls().map(\.description))")
        #expect(calls.allSatisfy { isInTheColumn($0, in: thread) }, "every call row is inside the column")
    }
}
