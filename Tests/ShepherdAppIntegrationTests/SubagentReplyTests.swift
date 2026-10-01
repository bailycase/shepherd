import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A subagent that asked its parent has its Steer action called Reply (decided by the user,
/// 2026-10-01), and every run that did not ask keeps Steer. It is the same command, so these press
/// what VoiceOver reaches (`ControlPress`) and check what each one asked of its run. SwiftUI draws
/// the accessibility tree only for a process an assistive client is attached to, so each scenario
/// runs in a process of its own.
@Suite("Reply on a subagent that asked its parent", .integrationTimeLimit)
struct SubagentReplyTests {
    @Test func aTrayRowThatAskedOffersReplyAndTheOthersKeepSteer() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheTray() }
        }
    }

    @Test func theInspectorOffersReplyOnlyForARunThatAsked() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.readingTheInspector() }
        }
    }

    @Test func theInspectorSendsAReplyAsTheSteerCommandThatEndsTheQuestion() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.replying() }
        }
    }

    // MARK: Runs

    private static let working = ChildRun(
        runID: "native-worker", label: "worker: restyle", state: "running", startedAt: 1_000, currentTool: "edit", role: "worker",
        lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/Thread.swift", at: 2_000),
        task: "Restyle the thread view.")

    private static let asked = ChildRun(
        runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: 1_000, needsAttention: true,
        role: "reviewer", lastActivity: ChildActivity(tool: "shepherd_parent_message", at: 2_000),
        question: ChildQuestion(text: "Rename the new token names, or replace the old ones everywhere?",
                                options: ["Replace everywhere", "Rename new ones"]),
        task: "Check each step against the spec.")

    /// What the tray's actions reached.
    @MainActor
    private final class Log {
        var steered: [String] = []
        var opened: [String] = []
        var commands: [String] = []
    }

    // MARK: Tray

    /// A worker that is running and a reviewer that asked its parent. A tray row is one element
    /// whose controls (the hover buttons, which only a pointer reaches) are its accessibility
    /// actions, so VoiceOver's action menu is what is pressed: the worker's Steer is Steer, the
    /// reviewer's is Reply, and each reaches the steer handler for its own run. Stop stays Stop and
    /// closes the reviewer's question; a run that asked has nothing to Pause.
    @MainActor
    static func pressingTheTray() async throws {
        AccessibilityNode.enable()
        let runs = [working, asked]
        let rows = SubagentPresentation.tray(NativeSubagentTray(runs)).rows
        let log = Log()
        let actions = SubagentActions(
            inspect: { log.opened.append($0.runID) },
            command: { run, action, _, _ in log.commands.append("\(action.rawValue) \(run.runID)") },
            steer: { log.steered.append($0.runID) })
        let window = OffscreenWindow(size: CGSize(width: 760, height: 120), dark: true, VStack(spacing: 0) {
            ForEach(rows) { row in
                SubagentTrayRow(value: row, run: runs.first { $0.id == row.id }!, selected: false, actions: actions)
                    .equatable()
            }
        }
        .background(Color.nw.bgWindow))
        defer { window.close() }
        window.layout()

        let worker = Set(ControlPress.actions(onLabelContaining: "worker", under: window.host))
        let reviewer = Set(ControlPress.actions(onLabelContaining: "reviewer", under: window.host))
        #expect(worker == ["Open", "Steer", "Pause", "Stop"], "a running run offers Steer: \(worker)")
        #expect(reviewer == ["Open", "Reply", "Stop"], "a run that asked its parent offers Reply, not Steer or Pause: \(reviewer)")

        try ControlPress.perform("Reply", onLabelContaining: "reviewer", under: window.host)
        #expect(log.steered == ["native-reviewer"], "Reply is the Steer command of its own run")
        try ControlPress.perform("Steer", onLabelContaining: "worker", under: window.host)
        #expect(log.steered == ["native-reviewer", "native-worker"])
        try ControlPress.perform("Stop", onLabelContaining: "reviewer", under: window.host)
        #expect(log.commands == ["cancel native-reviewer"], "Stop closes the question of a run that asked")
        #expect(throws: ControlPressError.self, "a run that did not ask has no Reply") {
            try ControlPress.perform("Reply", onLabelContaining: "worker", under: window.host)
        }
        #expect(log.steered.count == 2 && log.commands.count == 1, "the refused press ran nothing")
    }

    // MARK: Inspector

    /// A thread store serving live runs, and recording the commands it was asked to run.
    @MainActor
    private final class Thread {
        let store = NativeThreadStore()
        private var task: Task<Void, Never>?
        let runs: [ChildRun]
        private(set) var commands: [NativeThreadRequest] = []

        init(runs: [ChildRun]) { self.runs = runs }

        func start() async throws {
            task = Task { [store] in
                await store.run { [weak self] request in
                    guard let self else { return .failure(code: "gone", message: "released") }
                    if case .subagentTranscript(_, let runID, _) = request {
                        return .transcript(value: NativeSubagentTranscript(runID: runID, messages: []))
                    }
                    if case .subagentCommand = request { self.commands.append(request) }
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

    @MainActor
    private static func inspector(_ thread: Thread, run: ChildRun, draft: String = "") -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 480, height: 560), dark: false,
                        SubagentInspector(store: thread.store, runID: run.runID, active: true, close: {}, select: { _ in }, draft: draft)
                            .background(Color.nw.bgWindow))
    }

    /// The inspector's field and its button say Reply for the run that asked and Steer for the
    /// other, each disabled until something is typed, and each with a desktop hit area.
    @MainActor
    static func readingTheInspector() async throws {
        AccessibilityNode.enable()
        let thread = Thread(runs: [working, asked])
        try await thread.start()
        defer { thread.stop() }

        let reviewer = SubagentPresentation.names(asked).name, worker = SubagentPresentation.names(working).name
        for (run, verb, field, absent) in [(asked, "Reply", "Reply to \(reviewer)", "Steer"), (working, "Steer", "Steer \(worker)", "Reply")] {
            let window = inspector(thread, run: run)
            defer { window.close() }
            try await eventuallyOnMain("the inspector to draw its \(verb) field") { window.element(field) != nil }
            let button = try #require(window.controls().first { $0.label == verb }, "the inspector offers \(verb): \(window.controls())")
            #expect(!button.isEnabled, "\(verb) waits for words to send")
            #expect(!window.controls().contains { $0.label == absent }, "and not \(absent)")
            #expect(ControlPress.undersized([button], minimum: .desktop).isEmpty, "\(verb) has a desktop hit area: \(button)")
        }
    }

    /// With words in the field Reply lights up, and pressing it sends the steer command (`message`
    /// delivered as a steer) to that run alone: the command that also ends its question on the host.
    @MainActor
    static func replying() async throws {
        AccessibilityNode.enable()
        let thread = Thread(runs: [working, asked])
        try await thread.start()
        defer { thread.stop() }

        let words = "Replace everywhere, and keep the old names as aliases."
        let window = inspector(thread, run: asked, draft: words)
        defer { window.close() }
        let name = SubagentPresentation.names(asked).name
        try await eventuallyOnMain("the inspector to draw its Reply field") { window.element("Reply to \(name)") != nil }
        try #require(window.controls().first { $0.label == "Reply" }?.isEnabled == true, "Reply is lit once there are words")

        try window.press("Reply")
        try await eventuallyOnMain("the host to be sent the reply") { !thread.commands.isEmpty }
        guard case .subagentCommand(_, _, _, let runID, let action, let text, let mode) = thread.commands[0] else {
            Issue.record("the request was not a subagent command: \(thread.commands)")
            return
        }
        #expect(runID == "native-reviewer")
        #expect(action == .message && mode == .steer, "Reply is the steer message, the command that ends the question")
        #expect(text == words)
    }
}
