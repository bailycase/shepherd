import Foundation
import ShepherdCore
import ShepherdProtocol

// Home track's screens. Each waits for Home's thread digests before its shot, so Needs you and
// Recents show what the snapshots say.
extension FixtureCatalog {
    static var home: [FixtureScreen] {
        let settle: @MainActor (MobileApp) async -> Void = { app in await HomeFeed.of(app.hosts).refresh() }
        let fleet = HomeFixtureData.fleet()
        return [
            FixtureScreen(name: "home", prepare: settle),
            FixtureScreen(name: "home-fleet", hosts: fleet, prepare: settle),
            FixtureScreen(name: "home-empty", hosts: []),
            FixtureScreen(name: "home-quiet", hosts: HomeFixtureData.quiet(), prepare: settle),
            FixtureScreen(name: "needsyou", hosts: fleet, routes: [.home(.needsYou)], prepare: settle),
            FixtureScreen(name: "needsyou-empty", hosts: HomeFixtureData.quiet(), routes: [.home(.needsYou)], prepare: settle),
            FixtureScreen(name: "automations", hosts: fleet, routes: [.home(.automations)], prepare: settle),
            FixtureScreen(name: "more", hosts: fleet, routes: [.home(.more)], prepare: settle),
            // The laptop is up but refuses the phone's token, instead of being unreachable.
            FixtureScreen(name: "home-refused", hosts: FixtureData.refusingLaptop(fleet), prepare: settle),
            FixtureScreen(name: "more-refused", hosts: FixtureData.refusingLaptop(fleet), routes: [.home(.more)], prepare: settle),
            FixtureScreen(name: "recents", hosts: fleet, routes: [.home(.recents)], prepare: settle),
            // iPad: the sidebar over a portrait thread (run with --sidebar).
            FixtureScreen(name: "home-sidebar", hosts: fleet, routes: [.thread(FixtureData.ref(FixtureData.preview))], prepare: settle),
        ]
    }
}

/// Hosts for Home's screens: every kind of Needs you item, threads running with a command, an
/// automation run, and a host offline.
enum HomeFixtureData {
    static let restyle = AgentID(rawValue: "agent-restyle")
    static let triage = AgentID(rawValue: "agent-triage")
    static let merge = AgentID(rawValue: "agent-merge")
    static let migrations = AgentID(rawValue: "agent-migrations")
    static let hiddenSpace = Space(id: SpaceID(rawValue: "space-automations"), name: "Automations", path: "/Users/dev", hidden: true)

    static func fleet() -> [FixtureHostData] {
        let started = Date().timeIntervalSince1970 * 1000
        return [
            FixtureHostData(id: FixtureData.studio, name: "Studio", state: ShepherdState(
                spaces: [FixtureData.shepherdSpace, FixtureData.horizonSpace, hiddenSpace],
                agents: [
                    FixtureData.agent(FixtureData.preview, "Investigate SwiftUI live preview", .working),
                    FixtureData.agent(FixtureData.extensions, "Plan shepherd extensions", .working),
                    FixtureData.agent(FixtureData.dock, "Dock review pane", .blocked),
                    FixtureData.agent(FixtureData.deletion, "Fix remote subagent deletion", .done, space: FixtureData.horizonSpace),
                    FixtureData.agent(merge, "Merge PR #24 after CI", .working, space: hiddenSpace),
                ],
                automations: [
                    Automation(id: AutomationID(rawValue: "auto-merge"), name: "Merge PR #24 after CI", prompt: "Merge PR #24 once CI is green",
                               cwd: "/Users/dev/Shepherd", agentID: merge),
                    Automation(id: AutomationID(rawValue: "auto-cleanup"), name: "Stale branch cleanup", prompt: "Delete merged branches",
                               cwd: "/Users/dev/horizon", enabled: false),
                ]),
                threads: [
                    FixtureData.preview: command("git push origin main", startedAgo: 21_000, at: started),
                    FixtureData.extensions: command("swift build", startedAgo: 130_000, at: started),
                    FixtureData.dock: question(at: started),
                    FixtureData.deletion: finished(at: started - 3_700_000),
                    merge: command("gh pr checks 24 --watch", startedAgo: 240_000, at: started),
                ]),
            FixtureHostData(id: FixtureData.buildBox, name: "build-01", state: ShepherdState(
                spaces: [FixtureData.shepherdSpace, hiddenSpace],
                agents: [
                    FixtureData.agent(restyle, "Restyle native UI", .working),
                    FixtureData.agent(FixtureData.buffer, "Fix terminal output buffer", .idle),
                    FixtureData.agent(triage, "Triage new Sentry issues", .blocked, space: hiddenSpace),
                    FixtureData.agent(migrations, "Nightly migrations dry run", .done),
                ],
                automations: [
                    Automation(id: AutomationID(rawValue: "auto-triage"), name: "Triage new Sentry issues", prompt: "Triage new issues",
                               cwd: "/srv/checkout-svc", agentID: triage),
                    Automation(id: AutomationID(rawValue: "auto-bump"), name: "Weekly dependency bump", prompt: "Bump dependencies",
                               cwd: "/srv/checkout-svc"),
                ]),
                threads: [
                    restyle: subagentAsking(at: started),
                    FixtureData.buffer: finished(at: started - 7_200_000),
                    triage: FixtureData.snapshot([
                        FixtureData.user("t1", "Triage the new Sentry issues in checkout-svc.", at: started - FixtureData.start - 3_660_000),
                        FixtureData.assistant("t2", "NilPointer in PlaceOrder started 40 minutes after #231 merged.",
                                              at: started - FixtureData.start - 3_600_000),
                    ], running: true, dialogs: [NativeThreadDialog(id: "d-triage", kind: .confirm, title: "Is this a regression from #231?",
                                                                   message: "NilPointer in PlaceOrder started 40 minutes after #231 merged.")]),
                    migrations: finished(at: started - 43_200_000),
                ]),
            FixtureHostData(id: FixtureData.laptop, name: "MacBook Air", state: ShepherdState(), online: false),
        ]
    }

    /// Two hosts with threads and nothing waiting on the user.
    static func quiet() -> [FixtureHostData] {
        let started = Date().timeIntervalSince1970 * 1000
        return [
            FixtureHostData(id: FixtureData.studio, name: "Studio", state: ShepherdState(spaces: [FixtureData.shepherdSpace], agents: [
                FixtureData.agent(FixtureData.preview, "Investigate SwiftUI live preview", .idle),
                FixtureData.agent(FixtureData.extensions, "Plan shepherd extensions", .working),
            ]), threads: [
                FixtureData.preview: finished(at: started - 600_000),
                FixtureData.extensions: command("swift test --filter ThreadRows", startedAgo: 45_000, at: started),
            ]),
            FixtureHostData(id: FixtureData.buildBox, name: "build-01", state: ShepherdState()),
        ]
    }

    /// A thread running `command`, started `startedAgo` ms before `now` (ms since epoch).
    static func command(_ command: String, startedAgo: Double, at now: Double) -> NativeThreadSnapshot {
        let begin = now - FixtureData.start - startedAgo
        let args = String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        return FixtureData.snapshot([
            FixtureData.user("c1", "Keep going.", at: begin - 5_000),
            FixtureData.tool("c2", "bash", args: args, output: "", status: "running", at: begin + 2_000),
        ], running: true)
    }

    /// A finished thread whose last message landed at `at` (ms since epoch).
    static func finished(at: Double) -> NativeThreadSnapshot {
        FixtureData.snapshot([
            FixtureData.user("f1", "Fix it.", at: at - FixtureData.start - 60_000),
            FixtureData.assistant("f2", "Done.", at: at - FixtureData.start),
        ])
    }

    /// The foundation's question thread, asked 14 minutes before `now` (ms since epoch).
    static func question(at now: Double) -> NativeThreadSnapshot {
        var snapshot = FixtureData.questionThread()
        let shift = now - FixtureData.start - 840_000
        snapshot.messages = snapshot.messages.map { message in
            var message = message
            message.timestamp = message.timestamp.map { $0 + shift }
            return message
        }
        return snapshot
    }

    /// A running thread whose reviewer subagent asks a question.
    static func subagentAsking(at now: Double) -> NativeThreadSnapshot {
        let reviewer = ChildRun(runID: "run-reviewer", label: "reviewer", state: "running", startedAt: now - 120_000,
                                needsAttention: true, attentionText: "Two token names collide. Rename the new ones, or replace the old ones everywhere?",
                                role: "reviewer")
        return FixtureData.snapshot([
            FixtureData.user("s1", "Restyle the native UI on the new tokens."),
            FixtureData.assistant("s2", "Waiting on worker and reviewer.", at: now - FixtureData.start - 120_000),
        ], running: true, subagents: [reviewer])
    }
}
