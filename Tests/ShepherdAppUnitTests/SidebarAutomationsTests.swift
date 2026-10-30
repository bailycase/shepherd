import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// Activity's Automations group (the user's request): one row per active automation, as Designs and Projects list
/// theirs, with its run threads folded under it.
@Suite("Sidebar automations")
@MainActor
struct SidebarAutomationsTests {
    private let space = Fixture.space("shepherd", path: "/code/shepherd")
    private let github = AutomationTrigger.github([GitHubTrigger(events: [.issueOpened])])
    private let daily = AutomationTrigger.schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"))

    private func run(_ name: String, of automation: Automation, status: AgentStatus = .idle, at: Double = 0) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.automationOrigin = AutomationOrigin(automationID: automation.id)
        agent.status = status
        agent.lastActiveAt = at
        return agent
    }

    private func local(_ id: AutomationID) -> AutomationKey { AutomationKey(host: PageHost.localID, automation: id) }

    @Test func onlyActiveAutomationsGetARow() {
        let watching = Automation(name: "pr-loop", prompt: "p", cwd: space.path, trigger: github)
        let off = Automation(name: "off", prompt: "p", cwd: space.path, enabled: false, trigger: daily)
        let project = Automation(name: "project's", prompt: "p", cwd: space.path, projectID: ProjectID(), trigger: daily)
        var watcher = Fixture.agent("deps", in: space).agent
        watcher.status = .working
        let live = Automation(name: "deps", prompt: "p", cwd: space.path, agentID: watcher.id)
        var settled = Fixture.agent("idle manual", in: space).agent
        settled.status = .done
        let idle = Automation(name: "idle manual", prompt: "p", cwd: space.path, agentID: settled.id)
        let never = Automation(name: "never run", prompt: "p", cwd: space.path)
        let offRun = run("#3 Old", of: off, status: .done, at: 5)
        let state = ShepherdState(spaces: [space], agents: [watcher, settled, offRun],
                                  automations: [watching, off, project, live, idle, never])
        let lists = SidebarDerivation.lists(SidebarSource(local: state))
        #expect(lists.automationRows.map(\.name) == ["deps", "pr-loop"])
        #expect(lists.automations.map(\.title) == ["deps"], "a live watcher's run folds under it")
        // A run of an automation that isn't active is a thread like any other.
        #expect(lists.done.map(\.title).sorted() == ["#3 Old", "idle manual"])
        #expect(lists.done.first { $0.title == "#3 Old" }?.pinnable == true)
        let items = lists.items(collapsed: [])
        #expect(items.contains(.header(.automations, count: 2, collapsed: false)))
        #expect(SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space], automations: [off, idle])))
            .items(collapsed: []).allSatisfy { if case .header(.automations, _, _) = $0 { false } else { true } },
                "hidden while none is active")
    }

    @Test func askingFirstThenRunningThenTheRestByLatestRunThenName() {
        let asking = Automation(name: "zeta", prompt: "p", cwd: space.path, trigger: github)
        let running = Automation(name: "yak", prompt: "p", cwd: space.path, trigger: github)
        let recent = Automation(name: "xray", prompt: "p", cwd: space.path, trigger: daily)
        let quietB = Automation(name: "beta", prompt: "p", cwd: space.path, trigger: daily)
        let quietA = Automation(name: "alpha", prompt: "p", cwd: space.path, trigger: github)
        let agents = [run("asks", of: asking, status: .blocked, at: 1), run("works", of: running, status: .working, at: 2),
                      run("old", of: running, at: 50), run("finished", of: recent, status: .done, at: 40)]
        let state = ShepherdState(spaces: [space], agents: agents, automations: [quietB, recent, quietA, running, asking])
        let lists = SidebarDerivation.lists(SidebarSource(local: state))
        #expect(lists.automationRows.map(\.name) == ["zeta", "yak", "xray", "alpha", "beta"])
        #expect(lists.needsYou.map(\.title) == ["asks"], "a run waiting on you is still in Needs you")
        #expect(lists.automations.map(\.title) == ["old", "works", "finished"], "runs sit under their automation, newest first")
        #expect(lists.automations.map(\.foldedUnder) == [local(running.id), local(running.id), local(recent.id)])
        #expect(lists.automationRows.map(\.runs) == [0, 2, 1, 0, 0])
    }

    @Test func theTrailingWordSaysHowItStands() {
        let schedule = Automation(name: "n", prompt: "p", cwd: "/", trigger: daily)
        let watch = Automation(name: "w", prompt: "p", cwd: "/", trigger: github)
        let manual = Automation(name: "m", prompt: "p", cwd: "/")
        func word(_ automation: Automation, running: Int = 0, asking: Bool = false, _ status: AutomationTriggerStatus? = nil,
                  allPaused: Bool = false) -> String {
            let result = SidebarDerivation.automationWord(automation, running: running, asking: asking, status: status, allPaused: allPaused)
            return result.word + (result.tone.map { " (\($0))" } ?? "")
        }
        // 09:00 UTC on Sep 24 2025.
        let next = AutomationTriggerStatus(state: .active, nextRunAt: 1_758_704_400, timeZone: "UTC")
        #expect(word(schedule, asking: true) == "asked you (attention)")
        #expect(word(schedule, running: 2) == "2 running (running)")
        #expect(word(manual, running: 1) == "running (running)")
        #expect(word(schedule, next) == "next 09:00")
        #expect(word(schedule) == "scheduled", "before the first status read")
        #expect(word(watch, AutomationTriggerStatus(state: .active)) == "watching")
        #expect(word(watch, AutomationTriggerStatus(state: .paused)) == "paused")
        #expect(word(watch, AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in.")) == "paused (failed)")
        #expect(word(schedule, next, allPaused: true) == "paused")
        #expect(word(watch, AutomationTriggerStatus(state: .retrying, reason: "rate limited")) == "retrying")
    }

    @Test func aRowCarriesItsUnreadRunsReasonAndMenuState() throws {
        let automation = Automation(name: "pr-loop", prompt: "p", cwd: space.path, trigger: github)
        let key = local(automation.id)
        let state = ShepherdState(spaces: [space], agents: [run("#9", of: automation, status: .done, at: 3)], automations: [automation])
        let lists = SidebarDerivation.lists(SidebarSource(
            local: state, triggerStatuses: [key: AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in.")],
            unreadRunCounts: [key: 2]))
        let row = try #require(lists.automationRows.first)
        #expect(row.word == "paused" && row.tone == .failed && row.unread == 2 && row.paused && row.triggered && !row.live)
        #expect(row.help == "pr-loop: gh isn't signed in.")
        #expect(row.accessibilityLabel == "pr-loop, automation, paused, 2 unread, 1 run")
    }

    @Test func runsFoldClosedAndOpenUnderTheirRow() throws {
        let automation = Automation(name: "pr-loop", prompt: "p", cwd: space.path, trigger: github)
        var mine = Fixture.agent("mine", in: space).agent
        mine.lastActiveAt = 20
        let state = ShepherdState(spaces: [space], agents: [run("#12", of: automation, status: .working, at: 30), mine],
                                  automations: [automation])
        let lists = SidebarDerivation.lists(SidebarSource(local: state))
        let key = local(automation.id)
        let closed = lists.items(collapsed: [])
        #expect(closed.compactMap { if case .automation(let row, let expanded) = $0 { "\(row.name) \(String(describing: expanded))" } else { nil } }
            == ["pr-loop Optional(false)"], "groups start closed")
        #expect(!lists.visibleRows(collapsed: []).contains { $0.foldedUnder != nil }, "a closed group's runs are out of ⌘↑/↓'s reach")
        let open: Set<String> = [SidebarLists.runGroupKey(key)]
        let titles = lists.items(collapsed: [], openRunGroups: open).compactMap { if case .row(let row) = $0 { row.title } else { nil } }
        #expect(titles == ["#12", "mine"])
        #expect(lists.items(collapsed: [], selectedAutomation: key).contains {
            if case .automation(let row, _) = $0 { row.selected } else { false }
        })
    }

    @Test func automationsSitAfterProjectsAndBeforeThreads() {
        let automation = Automation(name: "pr-loop", prompt: "p", cwd: space.path, trigger: github)
        var asking = Fixture.agent("asks", in: space).agent
        asking.status = .blocked
        let design = Design(name: "Dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4)
        let lists = SidebarDerivation.lists(SidebarSource(
            local: ShepherdState(spaces: [space], agents: [asking], automations: [automation], designs: [design]), designs: true))
        let headers = lists.items(collapsed: []).compactMap { if case .header(let section, _, _) = $0 { section } else { nil } }
        #expect(headers == [.designs, .projects, .automations, .needsYou])
    }

    @Test func aHostsActiveAutomationsJoinWhileItIsConnected() throws {
        let hostID = UUID()
        let remote = Automation(name: "nightly", prompt: "p", cwd: "/srv", trigger: daily)
        var hostRun = Fixture.agent("Scheduled run", in: space).agent
        hostRun.automationOrigin = AutomationOrigin(automationID: remote.id)
        hostRun.status = .working
        let hostState = ShepherdState(spaces: [space], agents: [hostRun], automations: [remote])
        func lists(offline: Bool) -> SidebarLists {
            SidebarDerivation.lists(SidebarSource(local: ShepherdState(),
                                                  hosts: [.init(id: hostID, name: "build-01", state: hostState, offline: offline)]))
        }
        let online = lists(offline: false)
        let row = try #require(online.automationRows.first)
        #expect(row.key == AutomationKey(host: hostID, automation: remote.id) && row.word == "1 running")
        #expect(row.accessibilityLabel.hasPrefix("nightly on build-01, automation"))
        #expect(online.automations.map(\.title) == ["Scheduled run"] && online.working.isEmpty)
        let offline = lists(offline: true)
        #expect(offline.automationRows.isEmpty, "an offline host's automations aren't shown")
        #expect(offline.recents.map(\.title) == ["Scheduled run"])

        // A host's manual watcher idles both while starting and once settled: the run last read tells them apart.
        var watcher = Fixture.agent("deps run", in: space).agent
        watcher.status = .idle
        let manual = Automation(name: "deps", prompt: "p", cwd: "/srv", agentID: watcher.id)
        let key = AutomationKey(host: hostID, automation: manual.id)
        func manualLists(_ run: AutomationRun?) -> SidebarLists {
            SidebarDerivation.lists(SidebarSource(local: ShepherdState(), hostRuns: run.map { [key: $0] } ?? [:], hosts: [
                .init(id: hostID, name: "build-01", state: ShepherdState(spaces: [space], agents: [watcher], automations: [manual]))]))
        }
        #expect(manualLists(nil).automationRows.map(\.word) == ["running"])
        #expect(manualLists(AutomationRun(startedAt: 0, settledAt: 1, result: .finished, agentID: watcher.id)).automationRows.isEmpty)
    }
}
