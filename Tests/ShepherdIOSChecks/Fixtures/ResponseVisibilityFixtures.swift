import Foundation
import UIKit
import ShepherdProtocol
import ShepherdRemote

/// Response visibility through the production remote store and mobile thread. All host data
/// and accessibility actions stay inside the isolated fixture app; no provider is contacted.
enum ResponseVisibilityFixtures {
    static var screens: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.extensions)
        return [
            FixtureScreen(name: "response-waiting", hosts: hosts(.waiting), routes: [.thread(ref)], prepare: checkWaiting),
            FixtureScreen(name: "response-started", hosts: hosts(.started), routes: [.thread(ref)], prepare: checkWaiting),
            FixtureScreen(name: "response-thinking", hosts: hosts(.thinking), routes: [.thread(ref)], prepare: openSummary),
            FixtureScreen(name: "response-generating", hosts: hosts(.generating), routes: [.thread(ref)], prepare: checkGenerating),
            FixtureScreen(name: "response-retrying", hosts: hosts(.retrying), routes: [.thread(ref)]),
            FixtureScreen(name: "response-footer", hosts: hosts(.finished), routes: [.thread(ref)], prepare: checkFooter),
            FixtureScreen(name: "response-timing", hosts: hosts(.finished), routes: [.thread(ref)], prepare: openTiming),
        ]
    }

    enum State { case waiting, started, thinking, generating, retrying, finished }

    static let summary = """
        **Adapting to the available space**

        Checking the thread and composer at narrow and wide scene sizes. The live summary must wrap without widening the thread, and expanding it must leave a detached reader in place.

        The response timing uses the host’s locally measured events, not another provider request.
        """

    static func hosts(_ state: State) -> [FixtureHostData] {
        let now = Date.now.timeIntervalSince1970 * 1000
        let sent = now - 32_000
        var user = FixtureData.user("visibility-user", "Keep response progress readable when the window changes size.")
        user.timestamp = sent
        var snapshot = FixtureData.snapshot([user], running: state != .finished)
        snapshot.liveRequest = NativeResponseTiming(sentAt: sent, firstEventAt: state == .waiting ? nil : sent + 1_400)
        switch state {
        case .waiting, .started: break
        case .thinking:
            var thought = FixtureData.assistant("provisional:assistant:visibility", "", thinking: summary, seconds: 30, status: "streaming")
            thought.timestamp = sent + 1_400
            thought.timing = NativeResponseTiming(sentAt: sent, firstEventAt: sent + 1_400, firstThinkingAt: sent + 1_400)
            snapshot.provisional = [thought]
        case .generating:
            var call = FixtureData.tool("visibility-write", "write", args: #"{"path":"App/iOS/Thread/ResponseVisibility.swift"}"#, status: "streaming")
            call.entryID = "provisional:tool:visibility-write"
            call.startedAt = now - 6_000
            call.argumentBytes = 18 * 1024
            snapshot.provisional = [call]
        case .retrying:
            var failure = FixtureData.assistant("visibility-error", #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: "error")
            failure.timestamp = now - 2_000
            failure.provider = "anthropic"
            snapshot.messages.append(failure)
            snapshot.retry = NativeThreadRetry(attempt: 2, maxAttempts: 3, retryAt: now + 60_000)
        case .finished:
            var reply = FixtureData.assistant("visibility-reply", "The response controls follow the available space. Open Response timing below to inspect the measured phases.", thinking: summary, seconds: 20)
            reply.timestamp = now
            reply.timing = NativeResponseTiming(sentAt: sent, headersAt: sent + 1_200, firstEventAt: sent + 1_400,
                                                firstThinkingAt: sent + 1_400, firstTextAt: sent + 21_400, endedAt: now,
                                                inputTokens: 14_200, outputTokens: 2_900, provider: "anthropic", model: "claude-opus-4-5")
            snapshot.messages.append(reply)
            snapshot.liveRequest = nil
        }
        return ThreadFixtures.hosts(running: snapshot)
    }

    @MainActor static func check(_ condition: Bool, _ message: String) {
        FixtureCheck.report("FIXTURE CHECK \(condition ? "ok" : "FAILED"): response visibility \(message)")
    }

    @MainActor static func ready() async {
        SidebarAutomationsCheck.enableAccessibility()
        await FixtureWindows.wait("response thread", seconds: 8) {
            SidebarAutomationsCheck.labels().contains { $0.contains("response") || $0.contains("Thinking") || $0.contains("Writing") }
        }
    }

    @MainActor static func checkWaiting(_ app: MobileApp) async {
        await ready()
        let wait = app.threads.store(for: FixtureData.ref(FixtureData.extensions)).liveWait
        await FixtureWindows.wait("wait line", seconds: 5) { SidebarAutomationsCheck.labels().contains { $0.contains(wait.title) } }
        check(SidebarAutomationsCheck.labels().contains { $0.contains(wait.title) }, "shows \(wait.title) with a measured clock")
    }

    @MainActor static func checkGenerating(_ app: MobileApp) async {
        await ready()
        await FixtureWindows.wait("received bytes", seconds: 5) { SidebarAutomationsCheck.labels().contains { $0.contains("18 KB received") } }
        check(SidebarAutomationsCheck.labels().contains { $0.contains("18 KB received") }, "announces streamed argument progress")
    }

    @MainActor static func checkFooter(_ app: MobileApp) async {
        await ready()
        await FixtureWindows.wait("timing action", seconds: 5) { SidebarAutomationsCheck.labels().contains("Response timing") }
        let button = SidebarAutomationsCheck.all.first { $0.accessibilityLabel == "Response timing" && $0.accessibilityTraits.contains(.button) }
        check(button != nil, "timing action is visible without hover")
        if let button {
            check(button.accessibilityFrame.width >= 44 && button.accessibilityFrame.height >= 44, "timing action has a 44pt touch target")
        }
    }

    @MainActor static func openTiming(_ app: MobileApp) async {
        await checkFooter(app)
        let button = SidebarAutomationsCheck.all.first { $0.accessibilityLabel == "Response timing" && $0.accessibilityTraits.contains(.button) }
        check(button?.accessibilityActivate() == true, "timing action opens through accessibility")
        await FixtureWindows.wait("timing details", seconds: 5) { SidebarAutomationsCheck.labels().contains { $0.contains("Response ended") } }
        check(SidebarAutomationsCheck.labels().contains { $0.contains("Response ended") }, "timing details show measured marks")
    }

    @MainActor static func openSummary(_ app: MobileApp) async {
        await ready()
        await FixtureWindows.wait("live summary", seconds: 5) {
            SidebarAutomationsCheck.all.contains { $0.accessibilityLabel?.contains("Thinking") == true && $0.accessibilityTraits.contains(.button) }
        }
        let button = SidebarAutomationsCheck.all.first { $0.accessibilityLabel?.contains("Thinking") == true && $0.accessibilityTraits.contains(.button) }
        check(button?.accessibilityActivate() == true, "live summary opens through accessibility")
        await FixtureWindows.wait("summary content", seconds: 5) { SidebarAutomationsCheck.labels().contains { $0.contains("Adapting to the available space") } }
        check(SidebarAutomationsCheck.labels().contains { $0.contains("Adapting to the available space") }, "model-exposed summary is readable")
    }
}
