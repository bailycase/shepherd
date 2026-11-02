import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// End to end against real GitHub, opt-in: `SHEPHERD_LIVE_E2E=owner/name#number` and
/// `SHEPHERD_LIVE_GH=/path/to/gh`. The app and its trigger engine run on a scratch server with the
/// real `gh`; the test adds the label `shepherd-trigger-test` to that issue after the trigger's
/// baseline, and the real poll must start a worktree thread for it. The stub engine plays the
/// model. The label is removed again at the end. CI never sets these.
@Suite("Live GitHub trigger end to end", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LIVE_E2E"] != nil))
@MainActor
struct LiveGitHubTriggerAppTests {
    @Test(.timeLimit(.minutes(5)))
    func aRealLabelStartsAThread() async throws {
        try StubPi.installAsEngine()
        let env = ProcessInfo.processInfo.environment
        let target = try #require(env["SHEPHERD_LIVE_E2E"]), gh = try #require(env["SHEPHERD_LIVE_GH"])
        let parts = target.split(separator: "#")
        let repo = String(parts[0]), number = try #require(Int(parts[1]))
        let label = "shepherd-trigger-test"
        @Sendable func runGH(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CommandFailure("gh \(args.joined(separator: " "))", "exit \(process.terminationStatus)") }
        }
        try? runGH(["issue", "edit", String(number), "--repo", repo, "--remove-label", label])
        defer { try? runGH(["issue", "edit", String(number), "--repo", repo, "--remove-label", label]) }

        let checkout = try makeScratchRepo()
        let app = try AppHarness(triggerSource: .gh(ghPath: gh))
        defer { app.stop() }
        let space = Fixture.space(path: checkout.path)
        var state = Fixture.state(spaces: [space], agents: [])
        let automation = Automation(name: "live loop", prompt: "Say hello.", cwd: checkout.path,
                                    trigger: .github([GitHubTrigger(repo: repo, events: [.issueLabeled], labels: [label])]))
        state.automations = [automation]
        let vm = try await app.start(with: state)
        let triggers = app.server.automationTriggers
        await triggers.tick()
        #expect(await triggers.status(of: automation).state == .active)
        #expect(vm.state.agents.isEmpty, "nothing before the baseline fires")

        try runGH(["issue", "edit", String(number), "--repo", repo, "--add-label", label])
        // The next real poll (at most a minute on) sees it.
        try await eventuallyOnMain("the real label to start a thread", timeout: .seconds(180)) {
            Task { await triggers.tick() }
            return vm.state.agents.contains { $0.automationOrigin?.automationID == automation.id }
        }
        let run = try #require(vm.state.agents.first { $0.automationOrigin?.automationID == automation.id })
        #expect(run.name.hasPrefix("#\(number) "))
        #expect(run.worktreeBranch?.hasPrefix("automation/issue-\(number)-") == true)
        #expect(run.automationOrigin?.triggerURL == "https://github.com/\(repo)/issues/\(number)")
        print("LIVE run", run.name, run.worktreeBranch ?? "", run.automationOrigin?.trigger ?? "")
    }
}
