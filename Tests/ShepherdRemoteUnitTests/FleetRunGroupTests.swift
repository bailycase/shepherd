import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A triggered automation's run threads fold under one row per automation in the iPhone and iPad sidebars, as in the
/// Mac's Spaces mode: count, unread, a running or needs-you rollup, paused, and closed until opened.
@Suite("Fleet sidebar: run groups")
struct FleetRunGroupTests {
    typealias F = FleetTests
    typealias S = FleetSidebarTests
    static let loop = AutomationID(rawValue: "pr-loop")
    static let standup = AutomationID(rawValue: "standup")
    static let automations = [
        Automation(id: loop, name: "pr-loop", prompt: "p", cwd: "/src",
                   trigger: .github([GitHubTrigger(repo: "acme/x", events: [.issueLabeled], labels: ["shepherd"])])),
        Automation(id: standup, name: "standup", prompt: "p", cwd: "/src",
                   trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"))),
    ]

    static func run(_ id: String, _ status: AgentStatus, of automation: AutomationID, active: Double? = nil) -> Agent {
        var agent = S.agent(id, status, active: active)
        agent.automationOrigin = AutomationOrigin(automationID: automation)
        return agent
    }

    static func key(_ automation: AutomationID) -> AutomationKey { AutomationKey(host: F.studio, automation: automation) }

    @Test func eachAutomationsRunsFoldUnderOneRowNewestFirstAndLeaveTheThreadGroups() {
        let agents = [Self.run("r1", .done, of: Self.loop, active: 10), Self.run("r2", .working, of: Self.loop, active: 20),
                      Self.run("s1", .idle, of: Self.standup, active: 30), Self.run("r3", .idle, of: Self.loop, active: 5),
                      S.agent("plain", .idle, active: 1)]
        let hosts = S.hosts(agents, automations: Self.automations)
        let groups = S.observed(agents).groups(FleetModel(hosts: hosts, digests: [:]))
        #expect(groups.working.isEmpty && groups.done.isEmpty, "runs are not loose rows in Working or Done")
        #expect(S.refs(groups.recents) == ["plain"])
        // pr-loop has the running (newest) run, so it leads.
        #expect(groups.runs.map(\.name) == ["pr-loop", "standup"])
        let loop = groups.runs[0]
        #expect(S.refs(loop.rows) == ["r2", "r1", "r3"] && loop.count == 3)
        #expect(loop.rollup == .running && !loop.expanded && !loop.paused && loop.unread == 0)
        #expect(groups.runs[1].rollup == .quiet)
    }

    @Test func unreadPausedAndAWaitingRunRollUp() {
        let agents = [Self.run("r1", .done, of: Self.loop, active: 10), Self.run("r2", .idle, of: Self.loop, active: 20),
                      Self.run("ask", .blocked, of: Self.loop)]
        let hosts = S.hosts(agents, automations: Self.automations)
        let groups = S.observed(agents).groups(FleetModel(hosts: hosts, digests: [:]),
                                               unread: [F.ref("r1"), F.ref("elsewhere")], paused: [Self.key(Self.loop)])
        let loop = try! #require(groups.runs.first)
        #expect(loop.unread == 1 && loop.paused)
        // The waiting run is answered in Needs you, once; its group says one of its runs needs you.
        #expect(groups.needsYou.map(\.ref) == [F.ref("ask")] && S.refs(loop.rows) == ["r2", "r1"])
        #expect(loop.rollup == .waiting)
    }

    @Test func groupsStartClosedOpenOnTheirRowAndGoWithTheirHost() {
        let agents = [Self.run("r1", .idle, of: Self.loop)]
        let hosts = S.hosts(agents, automations: Self.automations)
        let model = FleetModel(hosts: hosts, digests: [:])
        var state = S.observed(agents)
        #expect(state.groups(model).runs.first?.expanded == false)
        state.toggleRunGroup(Self.key(Self.loop))
        #expect(state.groups(model).runs.first?.expanded == true)
        state.toggleRunGroup(Self.key(Self.loop))
        state.openRunGroup(Self.key(Self.loop))
        #expect(state.openRunGroups == [Self.key(Self.loop)])
        state.reconcile([], sessions: [:])
        #expect(state.openRunGroups.isEmpty, "a forgotten host's groups are forgotten")
    }

    @Test func aPinnedRunStaysPinnedAndARunOfAGoneAutomationIsAnOrdinaryThread() {
        let agents = [Self.run("pinned", .idle, of: Self.loop), Self.run("orphan", .idle, of: AutomationID(rawValue: "gone"))]
        let hosts = S.hosts(agents, automations: Self.automations)
        let groups = S.observed(agents, pins: [F.ref("pinned")]).groups(FleetModel(hosts: hosts, digests: [:]))
        #expect(groups.pinned.map(\.ref) == [F.ref("pinned")] && groups.runs.isEmpty)
        #expect(S.refs(groups.recents) == ["orphan"])
    }
}
