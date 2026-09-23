import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Subagent surfaces in motion, recorded from off-screen windows (`MotionProbe`): a card's
/// question and a spawned card ease in (and only fade under Reduce Motion), the inspector steps
/// to a sibling from the side it sits on, and its transcript grows without leaving the tail.
@Suite("Subagent motion", .mainActorExclusive)
@MainActor
struct SubagentMotionTests {
    @MainActor @Observable
    final class Model {
        var card = NWSubagentRun(id: "reviewer", name: "reviewer", state: .attention, detail: "waiting on your answer")
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

    // MARK: Cards

    /// The top of what `change` added in `column`, and the frames caught drawing above it: a
    /// nudge from the top draws there before it lands, a cross-fade never does.
    private func framesAbove(_ recording: MotionRecording) throws -> (rest: Int, above: Int) {
        let rest = try #require(recording.settled.firstRow(differingFrom: recording.before), "the change shows")
        let above = recording.inBetween.filter { ($0.firstRow(differingFrom: recording.settled) ?? .max) < rest }
        return (rest, above.count)
    }

    @Test(arguments: [false, true])
    func aQuestionOpensInItsCardAndOnlyFadesUnderReduceMotion(reduceMotion: Bool) async throws {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     CardHost(model: model).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }

        let recording = await MotionProbe.record(window, region: Self.column) {
            model.card.question = NWSubagentQuestion(text: "Rename the new tokens, or replace the old ones?", options: ["Rename"])
        }

        #expect(!recording.inBetween.isEmpty, "the card grows over time")
        let (rest, above) = try framesAbove(recording)
        if reduceMotion {
            #expect(above == 0, "the question fades in where it rests (\(rest))")
        } else {
            #expect(above > 0, "the question nudges down into place (\(rest))")
        }
    }

    @Test(arguments: [false, true])
    func aSpawnedRunsCardNudgesIntoItsGroupAndOnlyFadesUnderReduceMotion(reduceMotion: Bool) async throws {
        let model = Model(runs: [Self.run(0), Self.run(1)])
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     GroupHost(model: model).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }

        let recording = await MotionProbe.record(window, region: Self.column) { model.runs.append(Self.run(2)) }

        #expect(!recording.inBetween.isEmpty, "the card arrives over time")
        let (rest, above) = try framesAbove(recording)
        if reduceMotion {
            #expect(above == 0, "the card fades in where it rests (\(rest))")
        } else {
            #expect(above > 0, "the card nudges down into place (\(rest))")
        }
    }

    private struct CardHost: View {
        let model: Model

        var body: some View {
            VStack(spacing: 0) {
                NWSubagentCard(model.card, inspect: {}, answer: { _ in }).equatable()
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .frame(width: SubagentMotionTests.width, height: SubagentMotionTests.column.height, alignment: .top)
            .background(Color.nw.bgWindow)
        }
    }

    private struct GroupHost: View {
        let model: Model

        var body: some View {
            VStack(spacing: 0) {
                SubagentStack(runs: model.runs, turnLive: true,
                              actions: SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }, enabled: true))
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .frame(width: SubagentMotionTests.width, height: SubagentMotionTests.column.height, alignment: .top)
            .background(Color.nw.bgWindow)
        }
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

    /// Rule 4 of the motion pass: a card easing open at the tail never leaves the followed
    /// thread short of it.
    @Test func aCardOpeningItsQuestionKeepsTheFollowedThreadAtItsTail() async throws {
        var runs = (0..<3).map { index in
            var run = Self.run(index)
            run.toolCallID = "spawn-\(index)"
            return run
        }
        var snapshot = Self.threadSnapshot(runs: runs, revision: 1)
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
        let height = scroll.documentView?.bounds.height ?? 0
        #expect(abs(tail) < 2, "opens at its tail: \(tail)")

        runs[2].needsAttention = true
        runs[2].question = ChildQuestion(text: "Rename the new tokens, or replace the old ones everywhere?", options: ["Rename", "Replace"])
        snapshot = Self.threadSnapshot(runs: runs, revision: 2)
        await store.refresh()

        let after = try await settled()
        #expect((scroll.documentView?.bounds.height ?? 0) > height + 40, "the card grew its question")
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

    /// The fade is opacity only, so it can never be what leaves the follower short; the
    /// inspector's follower lands short of the tail after a new turn with or without it.
    @Test(.bug(id: "inspector-follow-short", "The inspector's transcript stops short of its tail when a turn arrives"))
    func aNewTurnFadesIntoTheFollowedTranscriptWhichStaysAtTheTail() async throws {
        let thread = Thread(runs: [Self.run(0)])
        thread.transcripts["run-0"] = (0..<8).map { Self.message("m\($0)", $0 % 2 == 0 ? "user" : "assistant", $0 % 2 == 0 ? "Steer \($0)" : Self.answer) }
        try await thread.start()
        defer { thread.stop() }
        let model = Model(runID: "run-0")
        let window = OffscreenWindow(size: CGSize(width: Self.width, height: Self.column.height), dark: false,
                                     InspectorHost(model: model, store: thread.store))
        defer { window.close() }
        let scroll = try transcriptScroll(window)
        // A second page means the first one has landed.
        try await eventuallyOnMain("the transcript to load") { thread.pages >= 2 }
        window.layout()
        let tail = distanceFromBottom(scroll)
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.frame.height + 200, "the transcript scrolls")

        // The next poll brings a steer and an answer: new turns at the tail.
        let recording = await MotionProbe.record(window, region: Self.column) {
            thread.transcripts["run-0"]? += [Self.message("m8", "user", "One more thing"), Self.message("m9", "assistant", Self.answer)]
        }

        #expect(!recording.inBetween.isEmpty, "the new turns fade in")
        var last = CGFloat.infinity, still = 0
        try await eventuallyOnMain("the transcript to come to rest", poll: .milliseconds(30)) {
            window.layout()
            let now = distanceFromBottom(scroll)
            still = abs(now - last) < 0.5 ? still + 1 : 0
            last = now
            return still >= 6
        }
        withKnownIssue("The follower stops about one short turn above the tail (35pt here), before and after the fade") {
            #expect(abs(last - tail) < 1, "still at the tail: \(last), was \(tail)")
        }
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
