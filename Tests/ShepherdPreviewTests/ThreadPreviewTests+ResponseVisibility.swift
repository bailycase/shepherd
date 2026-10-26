import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// ResponseVisibility (docs/design/mockups/response-visibility): A, the live line before the
/// model's first event, while it thinks, while it writes a call, and while pi retries; B, live
/// thinking opened onto the summary the provider shared; C, a finished reply's Response timing.
/// Each from a snapshot a host served (its budget, over the wire's JSON) into the store the
/// thread reads, with the moments the host would have measured.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    static let visibilitySize = CGSize(width: 1180, height: 760)

    /// The Duo thread up to the question the board's B and C turn answers.
    static func duoMessages(answered: Bool) -> [NativeThreadMessage] {
        let now = ActivityThreads.now
        let t0 = now - 14 * 60_000
        var messages = [
            ActivityThreads.user("u1", "Make Shepherd work well on iPhone Duo: folded on one screen, and open across both.", at: t0),
            ActivityThreads.assistant("a1", "Folded, the Duo is one 390pt screen, so the thread already fits. Open, the hinge cuts the window into two panes and the thread’s column straddles it.",
                                      thinking: "Where does the hinge fall?", seconds: 12, at: t0 + 14_000),
            ActivityThreads.user("u2", "Before you change the composer: should it live on the right screen when the Duo is open?", at: now - 60_000),
        ]
        if answered {
            var reply = ActivityThreads.assistant("a2", """
                Yes. Put the composer on the right screen, under the side pane, and keep the thread on the left.

                - Held open, your right thumb is already on that screen, so the field is where you type.
                - The thread gets the whole left screen for reading, with no card over its tail.
                - `DuoPaneLayout` already knows which screen is which, so this is one placement, not a new layout.

                Folded, the composer stays where it is today. Want me to make the change?
                """, thinking: summary, seconds: 30.4, at: now - 15_000, status: "stop")
            let sent = now - 60_000
            reply.timing = NativeResponseTiming(sentAt: sent, headersAt: sent + 1_200, firstEventAt: sent + 1_400, firstThinkingAt: sent + 1_400,
                                                firstTextAt: sent + 31_800, endedAt: sent + 45_000, inputTokens: 14_200, outputTokens: 2_900,
                                                provider: "anthropic", model: "claude-opus-4-5")
            messages.append(reply)
        }
        return messages
    }

    /// What Claude's summarized thinking reads like: a bold title, then what it weighed.
    static let summary = """
        **Choosing a screen for the composer**

        Compared keeping the composer under the thread with moving it to the trailing screen. Held open, the trailing screen sits under the right thumb, and the thread reads better without a card over its tail.

        Checked that `DuoPaneLayout` already reports which pane leads, so no new layout is needed.
        """

    /// Renders `snapshot` as the host would serve it, in the full thread.
    private func renderServed(_ surface: String, _ snapshot: NativeThreadSnapshot, live: [NativeThreadMessage] = [],
                              ready: @escaping @MainActor (NativeThreadStore) -> Bool = { _ in true }) async throws {
        let fixture = ThreadFixture(try Self.served(snapshot, live: live))
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: Self.visibilitySize,
                                 ready: { fixture.store.ready && !fixture.store.rows.isEmpty && ready(fixture.store) }) {
            fixture.thread(title: "Optimize Shepherd for iPhone Duo")
        }
    }

    /// A › Waiting: the request is sent and no model event came yet. The line says only that,
    /// with its clock from the send; it claims no thinking.
    @Test func responseLiveWaiting() async throws {
        var snapshot = ActivityThreads.snapshot(Self.duoMessages(answered: true) + [
            ActivityThreads.user("u3", "Go ahead. Move it to the right screen and keep the thread on the left.", at: ActivityThreads.now - 5_000),
        ], running: true)
        snapshot.liveRequest = NativeResponseTiming(sentAt: ActivityThreads.now - 4_000, headersAt: ActivityThreads.now - 3_000)
        try await renderServed("response-live-waiting", snapshot) { $0.showsThinking && $0.liveWait.since != nil }
    }

    /// A › Thinking: the model's thinking streams with nothing shared yet: "Thinking…" and its clock.
    @Test func responseLiveThinking() async throws {
        let snapshot = ActivityThreads.snapshot(Self.duoMessages(answered: true) + [
            ActivityThreads.user("u3", "Go ahead. Move it to the right screen and keep the thread on the left.", at: ActivityThreads.now - 22_000),
        ], running: true)
        var thinking = NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant", blocks: [NativeThreadBlock(kind: .thinking, text: "")],
                                           status: "streaming", timestamp: ActivityThreads.now - 19_000, thinkingSeconds: 18)
        thinking.timing = NativeResponseTiming(sentAt: ActivityThreads.now - 20_000, firstEventAt: ActivityThreads.now - 18_500,
                                               firstThinkingAt: ActivityThreads.now - 18_000)
        try await renderServed("response-live-thinking", snapshot, live: [thinking])
    }

    /// A › Generating: the model writes a file's call; its line counts the arguments that came.
    @Test func responseLiveGenerating() async throws {
        let now = ActivityThreads.now
        let snapshot = ActivityThreads.snapshot(Self.duoMessages(answered: true) + [
            ActivityThreads.user("u3", "Go ahead. Move it to the right screen and keep the thread on the left.", at: now - 20_000),
        ], running: true)
        var reply = ActivityThreads.assistant("provisional:assistant:1", "Moving the composer into the right pane now.",
                                              thinking: "Right pane, then tests.", seconds: 9, at: now - 15_000, status: "streaming")
        reply.timing = NativeResponseTiming(sentAt: now - 19_000, firstEventAt: now - 18_000, firstThinkingAt: now - 18_000, firstTextAt: now - 9_000)
        var call = ActivityThreads.tool("call_w", "write", ["path": "App/iOS/Thread/DuoComposerPlacement.swift"], start: now - 6_000, end: nil, status: "streaming")
        call.entryID = "provisional:tool:call_w"
        call.argumentBytes = StreamingToolArguments.shown(18 * 1024 + 300)
        try await renderServed("response-live-generating", snapshot, live: [reply, call])
    }

    /// A › Retrying: what the provider returned, and the countdown to pi's next try.
    @Test func responseLiveRetrying() async throws {
        let now = ActivityThreads.now
        var snapshot = ActivityThreads.snapshot(Self.duoMessages(answered: true) + [
            ActivityThreads.user("u3", "Go ahead. Move it to the right screen and keep the thread on the left.", at: now - 20_000),
        ], running: true)
        var failed = NativeThreadMessage(entryID: "r1", role: "assistant", blocks: [NativeThreadBlock(kind: .text,
                                         text: #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)],
                                         status: "error", timestamp: now - 10_000)
        failed.provider = "anthropic"
        failed.model = "claude-opus-4-5"
        snapshot.messages.append(failed)
        snapshot.retry = NativeThreadRetry(attempt: 2, maxAttempts: 3, retryAt: Date.now.timeIntervalSince1970 * 1000 + 8_400)
        try await renderServed("response-live-retrying", snapshot)
    }

    /// B: live thinking whose summary the provider shared, opened: "Thinking… · 30s", the
    /// summary so far, and where it came from. No prose or footer yet; Stop is the action.
    @Test func responseThinkingSummary() async throws {
        let now = ActivityThreads.now
        let snapshot = try Self.served(ActivityThreads.snapshot(Self.duoMessages(answered: false), running: true), live: [{
            var thinking = NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                                               blocks: [NativeThreadBlock(kind: .thinking, text: Self.summary)],
                                               status: "streaming", timestamp: now - 31_000, thinkingSeconds: 30)
            thinking.timing = NativeResponseTiming(sentAt: now - 31_400, firstEventAt: now - 30_000, firstThinkingAt: now - 30_000)
            return thinking
        }()])
        // In the thread, folded: "Thinking… · 30s" opens it, and Stop is the composer's action.
        let thread = ThreadFixture(snapshot)
        defer { thread.store.stop() }
        try await Preview.render("response-thinking-summary-thread", size: Self.visibilitySize,
                                 ready: { thread.store.ready && thread.store.rows.count == 4 }) {
            thread.thread(title: "Optimize Shepherd for iPhone Duo")
        }
        // Opened.
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.render("response-thinking-summary", size: Self.visibilitySize, ready: { store.ready && store.rows.count == 4 }) {
            VisibilityScene(store: store, openLiveThinking: true)
                .frame(width: Self.visibilitySize.width, height: Self.visibilitySize.height)
                .environment(\.composerModelDefaults, fixture.modelDefaults)
                .task { await store.run(request: fixture.request) }
        }
    }

    /// C: the finished reply with its footer shown (as on hover), the Response timing button
    /// after Copy and Retry, and the popover it opens, from the same reply's measured timing.
    @Test func responseTiming() async throws {
        let fixture = ThreadFixture(try Self.served(ActivityThreads.snapshot(Self.duoMessages(answered: true))))
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.render("response-timing-footer", size: Self.visibilitySize,
                                 ready: { store.ready && store.rows.last?.presentation?.timing != nil }) {
            VisibilityScene(store: store, hoverLast: true)
                .frame(width: Self.visibilitySize.width, height: Self.visibilitySize.height)
                .environment(\.composerModelDefaults, fixture.modelDefaults)
                .task { await store.run(request: fixture.request) }
        }
        let report = try #require(store.rows.last?.presentation?.timing)
        #expect(report.segments.map(\.text) == ["1.4s", "30.4s", "13.2s"] && report.total == "45.0s")
        try await Preview.render("response-timing-popover", size: CGSize(width: 340, height: 420)) {
            SHResponseTiming(SHResponseTimingModel(report))
                .shPopover()
                .padding(SH.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color.sh.bgWindow)
        }
    }
}

/// The actual header and composer around the real turn renderers, with disclosure/hover
/// seeded for visual inspection. Stop comes from the running store, not drawn mock controls.
private struct VisibilityScene: View {
    let store: NativeThreadStore
    var hoverLast = false
    var openLiveThinking = false
    @State private var input = ThreadInput()

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: "Optimize Shepherd for iPhone Duo")
            ZStack(alignment: .bottom) {
                VisibilityTurns(store: store, hoverLast: hoverLast, openLiveThinking: openLiveThinking)
                Composer(store: store, input: input, active: true, isFocused: false, agentName: "Optimize Shepherd for iPhone Duo",
                         hasTurns: true, gutter: AppLayout.gutter)
            }
        }
        .background(Color.sh.bgWindow)
    }
}

/// The store's rows as the thread draws them, with the last reply hovered or its live thinking
/// opened, as a person would have it: the states the board pins for review.
private struct VisibilityTurns: View {
    let store: NativeThreadStore
    var hoverLast = false
    var openLiveThinking = false

    var body: some View {
        let rows = store.rows
        VStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if row.isUser {
                    UserTurn(messages: row.turn.messages, caption: row.turn.messages.first?.timestamp.map { nativeClockText($0) })
                } else if let presentation = row.presentation {
                    let open: Set<String> = openLiveThinking ? Set(presentation.items.compactMap { item in
                        if case .thinking(let id, _, _, _, true, _) = item { id } else { nil }
                    }) : []
                    AgentTurn(presentation: presentation, live: row.live, startedAt: row.startedAt, retry: {}, review: { _ in },
                              thinking: row.live && store.showsThinking, wait: store.liveWait,
                              hover: MessageHover(hovering: hoverLast && index == rows.count - 1), openThinking: open)
                }
            }
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, AppLayout.gutter)
        .padding(.top, AppLayout.threadTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.sh.bgWindow)
    }
}
