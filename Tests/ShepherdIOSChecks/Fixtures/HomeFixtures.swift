import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UIKit

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
            // The sidebar's Automations group (run with --sidebar): runs of two hosts, one waiting on you (in Needs you only),
            // a long name and the empty case. The first also presses the header and a run through accessibility.
            FixtureScreen(name: "sidebar-automations", hosts: HomeFixtureData.withRuns(), routes: [.thread(FixtureData.ref(FixtureData.preview))],
                          prepare: { app in await settle(app); await SidebarAutomationsCheck.run(app) }),
            FixtureScreen(name: "sidebar-automations-long", hosts: HomeFixtureData.withRuns(longName: true),
                          routes: [.thread(FixtureData.ref(FixtureData.preview))], prepare: settle),
            FixtureScreen(name: "sidebar-automations-none", hosts: HomeFixtureData.quiet(),
                          routes: [.thread(FixtureData.ref(FixtureData.preview))], prepare: { app in
                              await settle(app)
                              SidebarAutomationsCheck.enableAccessibility()
                              try? await Task.sleep(for: .seconds(1))
                              let labels = SidebarAutomationsCheck.labels()
                              // The destination row reads "Automations"; a group header would read "Automations, <n>".
                              FixtureCheck.report(labels.contains("Automations") && !labels.contains { $0.hasPrefix("Automations,") }
                                  ? "FIXTURE CHECK ok: no Automations group without runs" : "FIXTURE CHECK FAILED: the empty sidebar's labels \(labels.filter { $0.hasPrefix("Automations") })")
                          }),
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

    /// The fleet with a second live run on build-01 (and, with `longName`, a very long name on Studio's), so the group lists
    /// the runs of two connected hosts beside the attention run (triage), which stays in Needs you only.
    static func withRuns(longName: Bool = false) -> [FixtureHostData] {
        var hosts = fleet()
        let started = Date().timeIntervalSince1970 * 1000
        hosts[1].state.agents[3] = FixtureData.agent(migrations, "Nightly migrations dry run", .working, space: hiddenSpace)
        hosts[1].state.automations.append(Automation(id: AutomationID(rawValue: "auto-migrations"), name: "Nightly migrations dry run",
                                                     prompt: "Dry-run migrations", cwd: "/srv/checkout-svc", agentID: migrations))
        hosts[1].threads[migrations] = command("make migrate-dry-run", startedAgo: 95_000, at: started)
        if longName {
            hosts[0].state.agents[4].name = "Merge the release pull request after every required check on every platform has finished"
        }
        return hosts
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

    /// A running thread whose reviewer subagent asked its parent a question, offering two answers.
    /// It is the parent's to answer, so the thread is not in Needs you.
    static func subagentAsking(at now: Double) -> NativeThreadSnapshot {
        let text = "Two token names collide. Rename the new ones, or replace the old ones everywhere?"
        var reviewer = ChildRun(runID: "run-reviewer", label: "reviewer", state: "running", startedAt: now - 120_000,
                                needsAttention: true, attentionText: text, role: "reviewer")
        reviewer.question = ChildQuestion(text: text, options: ["Replace everywhere", "Rename new ones"])
        return FixtureData.snapshot([
            FixtureData.user("s1", "Restyle the native UI on the new tokens."),
            FixtureData.assistant("s2", SubagentFixtures.spawnNote, at: now - FixtureData.start - 120_000),
        ], running: true, subagents: [reviewer])
    }
}

/// The iPad sidebar's Automations group, read and pressed through the accessibility tree (no touches, no focus).
@MainActor enum SidebarAutomationsCheck {
    static func elements(under object: NSObject, into found: inout [NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        if let view = object as? UIView {
            if view.isAccessibilityElement { found.append(view) }
            if let list = view.accessibilityElements { for item in list { if let item = item as? NSObject { elements(under: item, into: &found, depth: depth + 1) } } }
            else if !view.isAccessibilityElement {
                let count = view.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count { if let item = view.accessibilityElement(at: index) as? NSObject { elements(under: item, into: &found, depth: depth + 1) } }
                }
            }
            for subview in view.subviews { elements(under: subview, into: &found, depth: depth + 1) }
        } else {
            found.append(object)
            if let list = object.accessibilityElements { for item in list { if let item = item as? NSObject { elements(under: item, into: &found, depth: depth + 1) } } }
        }
    }

    /// Each element once, whichever path of the tree reached it.
    static var all: [NSObject] {
        var found: [NSObject] = []
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { elements(under: window, into: &found) }
        }
        var seen = Set<ObjectIdentifier>()
        return found.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    static func labels() -> [String] { all.compactMap(\.accessibilityLabel) }

    /// SwiftUI draws its accessibility tree only while an assistive client is attached. The Debug fixture app asks for
    /// the automation mode XCUITest uses (the same private switch, in a build no one ships).
    static func enableAccessibility() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return print("FIXTURE ACCESSIBILITY unavailable") }
        typealias Setter = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: Setter.self)(true)
    }

    static func run(_ app: MobileApp) async {
        enableAccessibility()
        try? await Task.sleep(for: .seconds(1))
        print("FIXTURE ACCESSIBILITY \(all.count) elements, \(labels().count) labelled")
        for element in all.filter({ $0.accessibilityLabel?.contains("Triage") == true || $0.accessibilityLabel?.hasPrefix("Automations") == true }) {
            print("FIXTURE ELEMENT \(type(of: element)) \(element.accessibilityLabel ?? "") frame=\(element.accessibilityFrame)")
        }
        let model = HomeFeed.of(app.hosts).model
        let runs = model.automations.filter { $0.run != nil }
        let waiting = Set(model.needsYou.map(\.ref))
        func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }
        let attention = runs.filter { $0.run.map(waiting.contains) == true }
        check(attention.count == 1, "the store has one run waiting on you (\(attention.count))")
        let listed = runs.filter { $0.run.map { !waiting.contains($0) } == true }
        check(Set(listed.map(\.hostName)) == ["Studio", "build-01"], "the group spans both connected hosts (\(listed.map { "\($0.hostName): \($0.name)" }))")
        let titles = labels()
        let triage = titles.filter { $0.contains("Triage new Sentry issues") }
        check(triage.count == 1, "the attention run is drawn once, in Needs you (\(triage.count): \(triage))")
        // The destination row above ("Automations, 5") counts every definition; the group's header counts the runs listed.
        let header = all.first { $0.accessibilityLabel == "Automations, \(listed.count)" }
        check(header != nil, "the group header reads \"Automations, \(listed.count)\", not counting the attention run (labels: \(titles.filter { $0.hasPrefix("Automations") }))")
        check(header?.accessibilityTraits.contains(.header) == true && header?.accessibilityHint == "Opens Automations", "it is a header that says what it opens (\(String(describing: header?.accessibilityHint)))")
        if let frame = header?.accessibilityFrame { check(frame.height >= 44, "its hit area is at least 44pt (\(Int(frame.height))pt)") }
        // Press the header the way VoiceOver activates it.
        let opened = header?.accessibilityActivate() ?? false
        await FixtureCheck.wait("the Automations screen to open", seconds: 5) { app.navigator.padPath.last == .home(.automations) }
        check(opened && app.navigator.padPath.last == .home(.automations), "activating the header opens Automations")
        // Press a run: it opens its thread.
        app.navigator.open(.thread(FixtureData.ref(FixtureData.preview)))
        try? await Task.sleep(for: .seconds(1))
        if let run = listed.first?.run, let row = all.first(where: { $0.accessibilityLabel?.contains(listed[0].name) == true }) {
            let pressed = row.accessibilityActivate()
            await FixtureCheck.wait("the run's thread to open", seconds: 5) { app.navigator.selectedThread == AgentRef(host: run.host, agent: run.agent) }
            check(pressed && app.navigator.selectedThread == AgentRef(host: run.host, agent: run.agent), "activating a run opens its thread")
        } else {
            check(false, "a run row to activate (labels: \(labels().prefix(40)))")
        }
        app.navigator.open(.thread(FixtureData.ref(FixtureData.preview)))
    }
}
