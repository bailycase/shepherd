import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Subagent surfaces in motion, recorded from off-screen windows (`MotionProbe`): the tray
/// arriving above the composer leaves the followed thread at its tail, the inspector steps to a
/// sibling from the side it sits on, and its transcript grows without leaving the tail.
@Suite("Subagent motion", .mainActorExclusive, .timingSensitive)
@MainActor
struct SubagentMotionTests {
    @MainActor @Observable
    final class Model {
        var runs: [ChildRun]
        var runID: String

        init(runs: [ChildRun] = [], runID: String = "") {
            self.runs = runs
            self.runID = runID
        }
    }

    private static let width: CGFloat = 480
    /// A column through a card's middle, clear of its state pill.
    private static let column = CGRect(x: 200, y: 0, width: 1, height: 360)

    private static func run(_ index: Int, state: String = "running") -> ChildRun {
        ChildRun(runID: "run-\(index)", label: "worker \(index)", state: state, startedAt: 1_000 + Double(index), role: "worker \(index)",
                 turns: 3 + index, tokens: 40_000, lastActivity: ChildActivity(tool: "edit", preview: "Sources/File\(index).swift", at: 1_000),
                 task: "Restyle part \(index) of the thread.")
    }

    // MARK: Inspector

    /// A thread store serving live runs and each run's transcript.
    @MainActor
    private final class Thread {
        let store = NativeThreadStore()
        var runs: [ChildRun]
        var transcripts: [String: [NativeThreadMessage]] = [:]
        /// Transcript pages served so far.
        private(set) var pages = 0
        private var task: Task<Void, Never>?

        init(runs: [ChildRun]) {
            self.runs = runs
        }

        func start() async throws {
            task = Task { [store] in
                await store.run { [weak self] request in
                    guard let self else { return .failure(code: "gone", message: "released") }
                    if case .subagentTranscript(_, let runID, _) = request {
                        self.pages += 1
                        return .transcript(value: NativeSubagentTranscript(runID: runID, messages: self.transcripts[runID] ?? []))
                    }
                    return .snapshot(value: NativeThreadSnapshot(
                        piSessionID: "s", generation: "g", revision: 1, running: true, supportedActions: ["send", "subagents"],
                        dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, subagents: self.runs))
                }
            }
            try await eventuallyOnMain("the thread to connect") { store.ready && store.subagents.count == runs.count }
        }

        func stop() {
            task?.cancel()
            store.stop()
        }
    }

    private struct InspectorHost: View {
        let model: Model
        let store: NativeThreadStore

        var body: some View {
            SubagentInspector(store: store, runID: model.runID, active: true, close: {}, select: { model.runID = $0.runID })
                .frame(width: SubagentMotionTests.width, height: SubagentMotionTests.column.height)
                .background(Color.nw.bgWindow)
        }
    }

    /// The header's glyph and title row.
    private static let header = CGRect(x: 0, y: 8, width: width, height: 28)

    @Test(arguments: [(from: 0, to: 1, edge: Edge.trailing), (from: 2, to: 1, edge: .leading)])
    func steppingToASiblingNudgesItInFromItsSide(from: Int, to: Int, edge: Edge) async throws {
        let thread = Thread(runs: (0..<3).map { Self.run($0) })
        try await thread.start()
        defer { thread.stop() }
        let model = Model(runID: "run-\(from)")
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     InspectorHost(model: model, store: thread.store))
        defer { window.close() }

        let recording = await MotionProbe.record(window, region: Self.header) { model.runID = "run-\(to)" }

        let glyph = try #require(recording.settled.firstColumn(drawingOver: (x: 2, y: 0)), "the header draws its glyph")
        let away = recording.inBetween.flatMap { $0.columnsAway(from: recording.before, recording.settled, empty: (x: 2, y: 0)) }
        #expect(!away.isEmpty, "the new run moves into place")
        if edge == .leading {
            #expect(away.contains { $0 < glyph }, "an earlier sibling arrives from the leading side: \(Set(away).sorted().prefix(8))")
        } else {
            #expect(!away.contains { $0 < glyph }, "a later sibling arrives from the trailing side: \(Set(away).sorted().prefix(8))")
        }
    }

    @Test func underReduceMotionSteppingToASiblingOnlyCrossFades() async throws {
        let thread = Thread(runs: (0..<3).map { Self.run($0) })
        try await thread.start()
        defer { thread.stop() }
        let model = Model(runID: "run-0")
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     InspectorHost(model: model, store: thread.store).environment(\._accessibilityReduceMotion, true))
        defer { window.close() }

        let recording = await MotionProbe.record(window, region: Self.header) { model.runID = "run-1" }

        #expect(!recording.inBetween.isEmpty, "the runs cross-fade")
        let away = recording.inBetween.flatMap { $0.columnsAway(from: recording.before, recording.settled, empty: (x: 2, y: 0)) }
        #expect(away.isEmpty, "nothing moves: \(Set(away).sorted().prefix(8))")
    }

    // MARK: In the thread

    /// A long conversation whose last turn spawned three subagents, as the thread shows it.
    private static func threadSnapshot(runs: [ChildRun], revision: UInt64) -> NativeThreadSnapshot {
        let history = (0..<16).map { message("h\($0)", $0 % 2 == 0 ? "user" : "assistant", $0 % 2 == 0 ? "Question \($0)" : answer) }
        let spawns = runs.map { run in
            NativeThreadMessage(entryID: "t-\(run.runID)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "{}")],
                                toolName: "shepherd_child_start", toolCallID: run.toolCallID, argumentsText: "{\"task\":\"part\"}", status: "complete")
        }
        return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: true,
                                    supportedActions: ["send", "abort", "subagents"], dialogsSupported: true, dialogs: [],
                                    messages: history + [message("u", "user", "Split it up"), message("a", "assistant", "Splitting in three.")] + spawns,
                                    provisional: [], clipped: false, subagents: runs)
    }

    /// Rule 4 of the motion pass: the tray arriving above the composer (the thread's inset
    /// grows under it) never leaves the followed thread short of its tail.
    @Test func theTrayArrivingKeepsTheFollowedThreadAtItsTail() async throws {
        let runs = (0..<3).map { index in
            var run = Self.run(index)
            run.toolCallID = "spawn-\(index)"
            return run
        }
        var snapshot = Self.threadSnapshot(runs: [], revision: 1)
        let store = NativeThreadStore()
        let request: NativeThreadStore.Request = { _ in .snapshot(value: snapshot) }
        let window = OffscreenWindow(size: CGSize(width: 800, height: 600), dark: false,
                                     ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "subagents",
                                                inspectSubagent: { _ in }))
        defer {
            store.stop()
            window.close()
        }
        let scroll = try transcriptScroll(window)
        func settled() async throws -> CGFloat {
            var last = CGFloat.infinity, still = 0
            try await eventuallyOnMain("the thread to come to rest", poll: .milliseconds(30)) {
                window.layout()
                let now = distanceFromBottom(scroll)
                still = abs(now - last) < 0.5 ? still + 1 : 0
                last = now
                return still >= 6
            }
            return last
        }
        try await eventuallyOnMain("the thread to load") { store.ready }
        let tail = try await settled()
        #expect(abs(tail) < 2, "opens at its tail: \(tail)")

        snapshot = Self.threadSnapshot(runs: runs, revision: 2)
        await store.refresh()
        try await eventuallyOnMain("the tray to show") { store.tray != nil }

        let after = try await settled()
        #expect(abs(after - tail) < 2, "still at the tail: \(after), was \(tail)")
    }

    // MARK: Inspector transcript

    private static func message(_ id: String, _ role: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)])
    }

    private static let answer = Array(repeating: "A paragraph long enough to wrap onto a second line in the inspector's column.",
                                      count: 3).joined(separator: "\n\n")

    /// The transcript's scroll view: the tallest one in the pane.
    private func transcriptScroll(_ window: OffscreenWindow) throws -> NSScrollView {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(all)
        }
        return try #require(all(window.host).max { $0.frame.height < $1.frame.height })
    }

    private func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        return (scroll.documentView?.bounds.height ?? 0) - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom)
    }

    /// A live run's transcript, a steer and a long answer at a time, in an inspector following it.
    private func followedTranscript() async throws -> (Thread, OffscreenWindow, NSScrollView) {
        let thread = Thread(runs: [Self.run(0)])
        thread.transcripts["run-0"] = (0..<8).map { Self.message("m\($0)", $0 % 2 == 0 ? "user" : "assistant", $0 % 2 == 0 ? "Steer \($0)" : Self.answer) }
        try await thread.start()
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     InspectorHost(model: Model(runID: "run-0"), store: thread.store))
        let scroll = try transcriptScroll(window)
        // A second page means the first one has landed.
        try await eventuallyOnMain("the transcript to load") { thread.pages >= 2 }
        window.layout()
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.frame.height + 200, "the transcript scrolls")
        return (thread, window, scroll)
    }

    private func newTurns(_ thread: Thread) {
        thread.transcripts["run-0"]? += [Self.message("m8", "user", "One more thing"), Self.message("m9", "assistant", Self.answer)]
    }

    /// The next poll brings a steer and an answer: they fade in by opacity alone.
    @Test func aNewTurnFadesIntoTheFollowedTranscript() async throws {
        let (thread, window, _) = try await followedTranscript()
        defer {
            thread.stop()
            window.close()
        }

        let recording = await MotionProbe.record(window, region: Self.column) { newTurns(thread) }

        #expect(!recording.inBetween.isEmpty, "the new turns fade in")
    }

    /// The fade is opacity only, so it is not what leaves the follower short: the base
    /// inspector's `scrollTo` of its bottom row lands short of the lazy stack's estimated
    /// heights too. Following the bottom edge with a `ScrollPosition` lands exactly, but then
    /// the new turns are laid out below the fold before the scroll reaches them, and their fade
    /// is spent where no one sees it.
    @Test(.disabled("bug: the inspector's transcript stops about one turn short of its tail when a turn arrives while following"))
    func theFollowedTranscriptStaysAtItsTailWhenATurnArrives() async throws {
        let (thread, window, scroll) = try await followedTranscript()
        defer {
            thread.stop()
            window.close()
        }
        func settled() async throws -> CGFloat {
            var last = CGFloat.infinity, still = 0
            try await eventuallyOnMain("the transcript to come to rest", poll: .milliseconds(30)) {
                window.layout()
                let now = distanceFromBottom(scroll)
                still = abs(now - last) < 0.5 ? still + 1 : 0
                last = now
                return still >= 6
            }
            return last
        }
        let tail = try await settled()

        newTurns(thread)
        try await eventuallyOnMain("the new turns to land") { thread.pages >= 3 }

        let after = try await settled()
        #expect(abs(after - tail) < 1, "still at the tail: \(after), was \(tail)")
    }

    @Test func textStreamingIntoTheLastTurnNeverAnimates() async throws {
        let thread = Thread(runs: [Self.run(0)])
        thread.transcripts["run-0"] = [Self.message("m0", "user", "Restyle the thread"), Self.message("m1", "assistant", "Reading the view")]
        try await thread.start()
        defer { thread.stop() }
        let model = Model(runID: "run-0")
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     InspectorHost(model: model, store: thread.store))
        defer { window.close() }
        // A second page means the first one has landed.
        try await eventuallyOnMain("the transcript to load") { thread.pages >= 2 }

        let recording = await MotionProbe.record(window, region: Self.column) {
            thread.transcripts["run-0"]?[1] = Self.message("m1", "assistant", "Reading the view, then the composer, its menus, and its chips")
        }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the text grows")
        #expect(recording.inBetween.isEmpty, "the text lands at once")
    }
}
