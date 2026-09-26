import Foundation
import ShepherdCore
import ShepherdProtocol

// Subagents track's screens: the tray above the composer (MobileSteer), the list (MobileSubagents), a
// running run with its steer field (MobileSubagent), a run waiting on you (iPadSteer) and a
// finished group with a finished run (iPadSubagents). Transcripts come from the host's
// `subagentTranscript` answers below.
extension FixtureCatalog {
    static var subagents: [FixtureScreen] {
        let live = SubagentFixtures.ref(SubagentFixtures.restyle)
        let done = SubagentFixtures.ref(SubagentFixtures.restyled)
        return [
            FixtureScreen(name: "subagents-thread", hosts: SubagentFixtures.hosts(), routes: [.thread(live)]),
            // MobileSteer, iPadSteer: the subagents, then Up next, in one card.
            FixtureScreen(name: "subagents-queue", hosts: SubagentFixtures.hosts(queued: true), routes: [.thread(live)]),
            FixtureScreen(name: "subagents", hosts: SubagentFixtures.hosts(), routes: [.thread(live), .subagents(.list(live))]),
            FixtureScreen(name: "subagent-run", hosts: SubagentFixtures.hosts(),
                          routes: [.thread(live), .subagents(.run(live, runID: SubagentFixtures.worker))]),
            FixtureScreen(name: "subagent-question", hosts: SubagentFixtures.hosts(),
                          routes: [.thread(live), .subagents(.run(live, runID: SubagentFixtures.reviewer))]),
            // The tray's Answer: the reviewer's question in the composer's place, its answers,
            // Something else… and Answer (MobileQuestion's layout, the question dock's rules).
            FixtureScreen(name: "subagent-answer", hosts: SubagentFixtures.hosts(), routes: [.thread(live)],
                          prepare: { _ in ComposerStates.shared.state(for: live).answeringRun = SubagentFixtures.reviewer }),
            // Opened from Needs you or the palette while another thread is on screen.
            FixtureScreen(name: "subagent-question-elsewhere", hosts: SubagentFixtures.hosts(),
                          routes: [.thread(done), .subagents(.run(live, runID: SubagentFixtures.reviewer))]),
            FixtureScreen(name: "subagents-finished", hosts: SubagentFixtures.hosts(), routes: [.thread(done)]),
            FixtureScreen(name: "subagent-finished-run", hosts: SubagentFixtures.hosts(),
                          routes: [.thread(done), .subagents(.run(done, runID: SubagentFixtures.tests))]),
        ]
    }
}

enum SubagentFixtures {
    static let restyle = AgentID(rawValue: "agent-restyle")
    static let restyled = AgentID(rawValue: "agent-restyled")
    static let worker = "run-worker"
    static let reviewer = "run-reviewer"
    static let tests = "run-tests"

    static func ref(_ agent: AgentID) -> AgentRef { FixtureData.ref(agent) }

    /// Now, in milliseconds: live runs count from a few minutes before launch.
    static var now: Double { Date().timeIntervalSince1970 * 1000 }

    /// The default hosts, with two more agents on Studio: one whose turn waits on three live
    /// runs, one whose three runs have finished.
    static func hosts(queued: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        hosts[index].state.agents.insert(FixtureData.agent(restyle, "Restyle native UI", .working), at: 0)
        hosts[index].state.agents.insert(FixtureData.agent(restyled, "Restyle to spec", .idle), at: 1)
        var live = liveThread()
        if queued {
            live.queue = NativeQueue(items: [
                NativeQueuedMessage(id: UUID(), text: "Keep the sidebar at 232pt when a pane opens.", sentAt: FixtureData.start, state: .steering),
                NativeQueuedMessage(id: UUID(), text: "Then re-run the snapshot tests.", sentAt: FixtureData.start),
            ])
        }
        hosts[index].threads[restyle] = live
        hosts[index].threads[restyled] = finishedThread()
        hosts[index].reply = { request in
            guard case .nativeThread(let id, _, .subagentTranscript(_, let runID, _)) = request else { return nil }
            return .nativeThread(id: id, result: .transcript(value: transcript(runID)))
        }
        return hosts
    }

    // MARK: Threads

    static let spawnNote = "Splitting into three: a worker for the restyle, a reviewer that checks each step against the spec, and a tests run in parallel."

    /// The MobileSteer board: the turn spawned three runs and waits on two of them. An earlier
    /// turn's runs finished an hour ago.
    static func liveThread() -> NativeThreadSnapshot {
        let started = now - FixtureData.start - 45 * 60_000
        return FixtureData.snapshot([
            FixtureData.user("e1", "Fix the agent model selection and audit the spec.", at: started - 2 * 3_600_000),
            FixtureData.assistant("e2", "Two runs: one for the model header, one to audit the spec.", at: started - 2 * 3_600_000 + 4_000),
            FixtureData.tool("e3", "shepherd_child_start", args: #"{"role":"claude-header-path"}"#, at: started - 2 * 3_600_000 + 6_000),
            FixtureData.tool("e4", "shepherd_child_start", args: #"{"role":"spec-audit"}"#, at: started - 2 * 3_600_000 + 7_000),
            FixtureData.assistant("e5", "Both finished: the header path is fixed and the audit listed 11 gaps.", at: started - 3_600_000),
            FixtureData.user("m1", "Restyle all of Shepherd's native UI to match the design spec. Split it up if that's faster.", at: started),
            FixtureData.assistant("m2", spawnNote, at: started + 5_000),
            FixtureData.tool("m3", "shepherd_child_start", args: #"{"workflow":"restyle"}"#, at: started + 8_000),
            // It waits on them: that call runs, so the thread's own tail stays still (MobileSteer).
            FixtureData.tool("m4", "shepherd_child_wait", args: "{}", status: "running", at: started + 9_000),
        ], running: true, subagents: liveRuns() + earlierRuns())
    }

    /// The iPadSubagents board: all three runs finished and the parent wrapped up.
    static func finishedThread() -> NativeThreadSnapshot {
        FixtureData.snapshot([
            FixtureData.user("f1", "Restyle the app to the new spec. Split the work however you like."),
            FixtureData.assistant("f2", spawnNote, at: 4_000),
            FixtureData.tool("f3", "shepherd_child_start", args: #"{"workflow":"restyle"}"#, at: 6_000),
            FixtureData.assistant("f4", "All three handed off. The test suite is green on both platforms; the branch is ready for review.",
                                  at: 2_760_000),
        ], subagents: finishedRuns())
    }

    // MARK: Runs

    static func liveRuns() -> [NativeSubagent] {
        let now = now
        return [
            ChildRun(runID: worker, label: "worker: restyle", state: "running", startedAt: now - 37 * 60_000, currentTool: "bash", role: "worker",
                     model: "anthropic/fable-5-1", thinking: "high", context: "background", step: ChildStep(index: 1, total: 3),
                     turns: 78, toolCalls: 82, tokens: 922_000, contextPercent: 34,
                     lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "bash", preview: "swift build --target ShepherdRemote", at: now - 11_000),
                     toolCallID: "call-m3",
                     task: "Restyle the desktop native thread view and the iOS app to match the spec. No fake affordances; system fonts at spec sizes."),
            ChildRun(runID: reviewer, label: "reviewer: check", state: "running", startedAt: now - 30 * 60_000, needsAttention: true,
                     attentionText: "Two token names collide", role: "reviewer", model: "anthropic/opus", context: "async", turns: 3,
                     tokens: 40_000,
                     lastActivity: ChildActivity(tool: "shepherd_parent_message", at: now - 2 * 60_000),
                     question: ChildQuestion(text: "Two token names collide with existing `Tokens.textSecondary`. Rename or replace the token names?",
                                             options: ["Replace everywhere", "Rename new ones"]),
                     toolCallID: "call-m3", task: "Check each step of the restyle against the spec and flag deviations."),
            ChildRun(runID: tests, label: "tests: run", state: "complete", startedAt: now - 25 * 60_000,
                     endedAt: now - 25 * 60_000 + 242_000, role: "tests", model: "anthropic/sonnet", context: "async", turns: 9,
                     toolCalls: 19, tokens: 118_000, result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000),
                     toolCallID: "call-m3", task: "Cover the presentation layer on both simulators.",
                     summary: "Added 6 presentation tests · 14 pass."),
        ]
    }

    static func earlierRuns() -> [NativeSubagent] {
        let now = now
        return [
            ChildRun(runID: "run-header", label: "claude-header-path", state: "complete", startedAt: now - 2 * 3_600_000,
                     endedAt: now - 3_600_000 - 60_000, role: "worker", result: ChildResultSummary(files: 1, added: 12, removed: 4, tools: 8, tokens: 30_000),
                     toolCallID: "call-e3", summary: "Fix agent model selection."),
            ChildRun(runID: "run-audit", label: "spec-audit", state: "complete", startedAt: now - 2 * 3_600_000,
                     endedAt: now - 2 * 3_600_000 + 20 * 60_000, role: "reviewer", toolCallID: "call-e4", summary: "Listed 11 spec gaps."),
        ]
    }

    static func finishedRuns() -> [NativeSubagent] {
        let start = FixtureData.start
        return [
            ChildRun(runID: worker, label: "worker: restyle", state: "complete", startedAt: start + 6_000, endedAt: start + 6_000 + 41 * 60_000,
                     role: "worker", model: "anthropic/fable-5-1", turns: 78, toolCalls: 82, tokens: 922_000,
                     result: ChildResultSummary(files: 5, added: 190, removed: 58, tools: 82, tokens: 922_000), toolCallID: "call-f3",
                     task: "Restyle the thread, sidebar, composer and iOS app to the spec.",
                     summary: "Restyled thread, sidebar, composer and iOS to the spec."),
            ChildRun(runID: reviewer, label: "reviewer: check", state: "complete", startedAt: start + 7_000, endedAt: start + 7_000 + 12 * 60_000,
                     role: "reviewer", model: "anthropic/opus", turns: 14, toolCalls: 26, tokens: 180_000,
                     result: ChildResultSummary(files: 0, added: 32, removed: 3, tools: 26, tokens: 180_000), toolCallID: "call-f3",
                     task: "Check each step of the restyle against the spec.",
                     summary: "2 spec deviations fixed · you chose replace everywhere."),
            ChildRun(runID: tests, label: "tests: run", state: "complete", startedAt: start + 8_000, endedAt: start + 8_000 + 4 * 60_000,
                     role: "tests", model: "anthropic/claude-sonnet", turns: 11, toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), toolCallID: "call-f3",
                     task: "Cover the presentation layer: preview text per tool kind, DiffStat counts, duration formatting. Run on both simulators.",
                     summary: "Added 6 presentation tests · 14 pass."),
        ]
    }

    // MARK: Transcripts

    static func transcript(_ runID: String) -> NativeSubagentTranscript {
        switch runID {
        case worker:
            return NativeSubagentTranscript(runID: runID, messages: [
                FixtureData.user("w1", "Restyle the desktop native thread view and the iOS app to match the spec."),
                FixtureData.assistant("w2", "Tokens landed. Now moving the tool-row derivations into a shared presentation file so macOS and iOS use the same previews.",
                                      at: 60_000),
                FixtureData.tool("w3", "read", args: #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, output: "import Foundation",
                                 at: 90_000),
                FixtureData.tool("w4", "edit", args: #"{"path":"Sources/ShepherdRemote/ToolPreview.swift","oldText":"a\nb","newText":"x"}"#,
                                 output: "Edited", at: 120_000),
                // The build in flight is the run's own last call: a session file holds finished calls only.
            ], earlierCount: 0)
        case reviewer:
            return NativeSubagentTranscript(runID: runID, messages: [
                FixtureData.user("r1", "Check each step of the restyle against the spec and flag deviations."),
                FixtureData.tool("r2", "read", args: #"{"path":"docs/spec.md"}"#, output: "# Spec", at: 30_000),
                FixtureData.tool("r3", "grep", args: #"{"pattern":"textSecondary"}"#, output: "Tokens.swift:12", at: 50_000),
                FixtureData.assistant("r4", "Two new token names collide with existing ones. Asking the parent before renaming anything.", at: 80_000),
            ])
        default:
            return NativeSubagentTranscript(runID: runID, messages: [
                FixtureData.user("t1", "Add presentation tests for the new tool-row derivations. Don't touch app code.", at: 60_000),
                FixtureData.assistant("t2", "Reading the presentation file first to see which derivations are pure and testable.", at: 70_000),
                FixtureData.tool("t3", "read", args: #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, output: "import Foundation",
                                 at: 80_000),
                FixtureData.tool("t4", "edit", args: #"{"path":"Tests/ShepherdRemoteUnitTests/ToolRowTests.swift","oldText":"a","newText":"b"}"#,
                                 output: "Edited", at: 150_000),
                FixtureData.tool("t5", "bash", args: #"{"command":"swift test --filter ToolRowTests"}"#,
                                 output: "✔ Test run with 14 tests in 2 suites passed after 0.3 seconds.", at: 220_000),
                FixtureData.assistant("t6", "All 14 pass on macOS.", at: 240_000),
                FixtureData.user("t7", "Run the iOS simulator variant too.", at: 250_000),
                FixtureData.assistant("t8", "Running them on the iPhone simulator.", at: 260_000),
                // The user's own steer, from the inspector: not "from parent".
                { var steer = FixtureData.user("t9", "Include the iPad simulator.", at: 270_000); steer.origin = .user; return steer }(),
                FixtureData.assistant("t10", "All 14 pass on macOS, the iPhone and the iPad simulators.", at: 300_000),
            ], earlierCount: 0)
        }
    }
}
