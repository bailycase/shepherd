import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// A message's quiet details, a user turn's time and a finished turn's footer (copy, retry, the
/// time and tool calls, the subagents link), show only while the message is hovered. Hovering
/// is seeded through the turn's `MessageHover`, never the pointer. It never moves or resizes
/// anything: what shows at rest stays put, pixel for pixel, while the details fade in beneath it.
@Suite("Thread hover", .mainActorExclusive)
@MainActor
struct ThreadHoverTests {
    static let width: CGFloat = 640

    private func agentTurn(_ hover: MessageHover, live: Bool = false) -> some View {
        AgentTurn(presentation: nativeTurnPresentation(Turns.reply(live: live), live: live), live: live,
                  startedAt: Turns.asked, retry: {}, hover: hover)
            .padding(24)
            .frame(width: Self.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgWindow)
    }

    private func userTurn(_ hover: MessageHover, note: String?) -> some View {
        UserTurn(messages: [Turns.prompt], caption: "10:58", note: note, hover: hover)
            .padding(24)
            .frame(width: Self.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgWindow)
    }

    /// Waits for the window to come to rest (fonts, first layout) before recording.
    private func rested(_ window: OffscreenWindow) async -> MotionRecording.Frame {
        await MotionProbe.record(window, timeout: 0.3) {}.settled
    }

    /// At rest the footer draws nothing; the pointer over the turn fades it in (`.hover`, also
    /// under Reduce Motion) below everything the turn already showed, which never redraws.
    @Test(.timingSensitive, arguments: [false, true])
    func aFinishedTurnsFooterShowsOnlyWhileHovered(reduceMotion: Bool) async throws {
        let hover = MessageHover()
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: 240), dark: false,
                                     agentTurn(hover).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        let rest = await rested(window)
        let content = try #require(rest.lastInkRow(), "the reply at rest")

        let recording = await MotionProbe.record(window) { hover.hovering = true }

        let top = try #require(recording.settled.firstRow(differingFrom: recording.before), "the footer shows")
        let bottom = try #require(recording.settled.lastRow(differingFrom: recording.before))
        #expect(top > content, "it draws only below what showed at rest: rows \(top)…\(bottom), content to \(content)")
        #expect(!recording.inBetween.isEmpty, "it fades in over frames")
        #expect(recording.frames.allSatisfy { frame in
            frame.firstRow(differingFrom: recording.before).map { $0 >= top } ?? true
                && frame.lastRow(differingFrom: recording.before).map { $0 <= bottom } ?? true
        }, "it fades in place, and nothing else moves")

        let leaving = await MotionProbe.record(window) { hover.hovering = false }
        #expect(leaving.settled.matches(rest), "leaving the turn hides it again")
    }

    /// The user's time shows under the bubble only while the turn is hovered. In a child's
    /// transcript "from parent" always shows, and the time fades in beside it without moving it.
    @Test(.timingSensitive, arguments: [nil, "from parent"] as [String?])
    func aUserTurnsTimeShowsOnlyWhileHovered(note: String?) async throws {
        let hover = MessageHover()
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: 140), dark: false, userTurn(hover, note: note))
        defer { window.close() }
        let rest = await rested(window)
        let content = try #require(rest.lastInkRow(), "the bubble at rest")

        let recording = await MotionProbe.record(window) { hover.hovering = true }

        let top = try #require(recording.settled.firstRow(differingFrom: recording.before), "the time shows")
        let bottom = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let right = try #require(recording.settled.lastColumn(differingFrom: recording.before))
        #expect(!recording.inBetween.isEmpty, "it fades in over frames")
        if note == nil {
            #expect(top > content, "it draws only below the bubble: rows \(top)…\(bottom), bubble to \(content)")
        } else {
            // The note shares the time's line: the time draws only to its left.
            let noteStart = try #require(rest.firstInkColumn(rows: top...bottom), "the note at rest")
            #expect(right < noteStart, "the time ends at \(right), left of the note at \(noteStart)")
        }
    }

    /// Hovering changes no frame: a hovered turn measures exactly as it does at rest.
    @Test func hoveringATurnKeepsItsSize() {
        func size(_ view: some View) -> CGSize { NSHostingView(rootView: view).fittingSize }
        #expect(size(agentTurn(MessageHover(hovering: true))) == size(agentTurn(MessageHover())))
        #expect(size(userTurn(MessageHover(hovering: true), note: "from parent")) == size(userTurn(MessageHover(), note: "from parent")))
    }

    /// VoiceOver never depends on the pointer: while it runs the footer's buttons (Copy
    /// response, Retry turn, the subagents link) show at rest exactly as they do on hover.
    @Test(.timingSensitive) func underVoiceOverTheFootersControlsShowAtRest() async throws {
        func footer(revealed: Bool, voiceOver: Bool) -> some View {
            NWTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {},
                         revealed: revealed, voiceOver: voiceOver)
                .padding(12)
                .frame(width: 420, height: 48, alignment: .leading)
                .background(Color.nw.bgWindow)
        }
        func render(_ view: some View) async -> MotionRecording.Frame {
            let window = OffscreenWindow(size: CGSize(width: 420, height: 48), dark: false, view)
            defer { window.close() }
            return await rested(window)
        }
        let rest = await render(footer(revealed: false, voiceOver: false))
        let hovered = await render(footer(revealed: true, voiceOver: false))
        let voiceOver = await render(footer(revealed: false, voiceOver: true))

        #expect(rest.lastInkRow() == nil, "hidden at rest")
        #expect(hovered.lastInkRow() != nil, "shown on hover")
        #expect(voiceOver.matches(hovered), "under VoiceOver it shows at rest")
    }

    /// A turn that ends under the pointer brings its footer in, rising from just below its place.
    @Test(.timingSensitive) func aHoveredTurnThatEndsBringsItsFooterInFromBelow() async throws {
        let ending = Ending()
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: 240), dark: false,
                                     EndingTurn(ending: ending, hover: MessageHover(hovering: true)))
        defer { window.close() }
        _ = await rested(window)

        let recording = await MotionProbe.record(window) { ending.live = false }

        let rest = try #require(recording.settled.lastRow(differingFrom: recording.before), "the footer came")
        let bottoms = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(!bottoms.isEmpty, "it comes in over frames")
        #expect(bottoms.contains { $0 > rest }, "it rises from below its place: \(bottoms), resting at \(rest)")
    }
}

@MainActor
@Observable
private final class Ending {
    var live = true
}

/// A reply that is streaming until `ending.live` turns false.
private struct EndingTurn: View {
    let ending: Ending
    let hover: MessageHover

    var body: some View {
        AgentTurn(presentation: nativeTurnPresentation(Turns.reply(live: ending.live), live: ending.live), live: ending.live,
                  startedAt: Turns.asked, hover: hover)
            .padding(24)
            .frame(width: ThreadHoverTests.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgWindow)
    }
}

private enum Turns {
    static let asked = 1_700_000_000_000.0

    static let prompt = NativeThreadMessage(entryID: "u1", role: "user",
                                            blocks: [NativeThreadBlock(kind: .text, text: "Build it and tell me how it went.")],
                                            timestamp: asked)

    /// The answer and the build it ran; the answer streams while `live`.
    static func reply(live: Bool) -> [NativeThreadMessage] {
        let answer = NativeThreadMessage(entryID: "a1", role: "assistant",
                                         blocks: [NativeThreadBlock(kind: .text, text: "Built it: the build is clean.")],
                                         status: live ? "streaming" : nil, timestamp: asked + 65_000)
        let build = NativeThreadMessage(entryID: "t-b1", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Build complete")],
                                        toolName: "bash", toolCallID: "b1", argumentsText: "{\"command\":\"swift build\"}",
                                        status: "complete", timestamp: asked + 60_000, startedAt: asked + 3_000)
        return [build, answer]
    }
}

extension MotionRecording.Frame {
    /// The background: the top-left pixel, which every render here leaves empty.
    fileprivate var background: Double { lightness(x: 0, y: 0) }

    fileprivate func inked(_ x: Int, _ y: Int) -> Bool { abs(lightness(x: x, y: y) - background) > 0.02 }

    /// The last row with anything drawn on it.
    fileprivate func lastInkRow() -> Int? {
        (0..<bitmap.pixelsHigh).reversed().first { y in (0..<bitmap.pixelsWide).contains { inked($0, y) } }
    }

    /// The first column with anything drawn on it within `rows`.
    fileprivate func firstInkColumn(rows: ClosedRange<Int>) -> Int? {
        (0..<bitmap.pixelsWide).first { x in rows.contains { inked(x, $0) } }
    }
}
