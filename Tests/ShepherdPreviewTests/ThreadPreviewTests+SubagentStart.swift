import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Subagent starts in a thread, in light and dark: the row of a refused start with its reason after the title,
/// and helpers the parent labelled, in the record's started line and the tray's rows.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    private static var startedThread: NativeThreadSnapshot {
        let now = ActivityThreads.now, t0 = now - 4 * 60_000
        func start(_ id: String, _ args: [String: Any], output: String, error: Bool = false, at: Double) -> NativeThreadMessage {
            ActivityThreads.tool(id, "shepherd_child_start", args, output: output, error: error, start: at, end: at + 200)
        }
        let rules = ChildRun(runID: "native-rules", label: "card-network-rules: Read the card network rules for refunds", state: "running",
                             startedAt: t0 + 3_000, role: "worker", name: "card-network-rules",
                             lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "read", preview: "docs/network-rules.md", at: now - 3_000),
                             toolCallID: "spawn-rules", task: "Read the card network rules for refunds")
        let providers = ChildRun(runID: "native-providers", label: "provider-requirements: List what each provider requires", state: "complete",
                                 startedAt: t0 + 4_000, endedAt: now - 60_000, role: "worker", name: "provider-requirements",
                                 result: ChildResultSummary(files: 0, added: 0, removed: 0, tools: 6, tokens: 12_000),
                                 toolCallID: "spawn-providers", task: "List what each provider requires", output: "Four providers need a refund reason code.")
        var value = ActivityThreads.snapshot([
            ActivityThreads.user("u1", "Research the card network rules, provider requirements and industry practice for refunds in acme-web.", at: t0),
            ActivityThreads.assistant("a1", "Starting the research helpers.", at: t0 + 1_000),
            start("bad-agent", ["role": "reviewr", "task": "Compare industry practice for refund windows"],
                  output: "Unknown agent \"reviewr\". Did you mean reviewer? Pass agent: \"reviewer\", and name: \"reviewr\" if it is only a label. Roles: scout, reviewer, planner, worker. Profiles: none discovered. shepherd_child_agents lists each with its source.",
                  error: true, at: t0 + 2_000),
            start("bad-model", ["task": "Compare industry practice for refund windows", "model": "gpt-x"],
                  output: "Model gpt-x isn't loaded. The model argument names gpt-x, but no provider of this Pi lists \"gpt-x\"; name a model as provider/id. Providers this Pi has: anthropic, openai. Pass model as one of those, or omit model to use the thread's.",
                  error: true, at: t0 + 2_500),
            start("spawn-rules", ["agent": "worker", "name": "card-network-rules", "task": "Read the card network rules for refunds"],
                  output: #"{"id":"native-rules","name":"card-network-rules","role":"worker"}"#, at: t0 + 3_000),
            start("spawn-providers", ["role": "provider-requirements", "task": "List what each provider requires"],
                  output: #"{"id":"native-providers","name":"provider-requirements","role":"worker","note":"No agent profile"}"#, at: t0 + 4_000),
        ], running: true)
        value.subagents = [rules, providers]
        return value
    }

    @Test func refusedAndLabelledSubagentStarts() async throws {
        let fixture = ThreadFixture(Self.startedThread)
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("thread-subagent-start", size: CGSize(width: 1180, height: 760), ready: {
            fixture.store.ready && !fixture.store.rows.isEmpty && fixture.store.subagents.count == 2
        }) {
            fixture.thread(title: "Research refund rules for acme-web")
        }
    }
}
