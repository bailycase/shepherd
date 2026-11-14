import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Automations page's model (NavAutomations): This Mac and every host in one table, the
/// filter and the selection, each row's last run, what can be changed from here, and the
/// selected automation's detail.
@Suite("Automations page")
@MainActor
struct AutomationsPageTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private let remoteID = UUID()
    /// Sep 24 2026 02:00 UTC.
    private let night: Double = 1_790_215_200

    private func host(_ id: UUID, _ name: String, automations: [Automation], agents: [Agent] = [], spaces: [Space] = [],
                      connected: Bool = true, manageable: Bool = true) -> AutomationHost {
        AutomationHost(id: id, name: name, connected: connected, manageable: manageable,
                       state: ShepherdState(spaces: spaces, agents: agents, automations: automations))
    }

    private func make(_ hosts: [AutomationHost], runs: [AutomationKey: [AutomationRun]] = [:], selection: AutomationKey? = nil,
                      filter: String = "", pending: Set<AutomationKey> = []) -> AutomationsPageModel {
        AutomationsPageModel.make(hosts: hosts, runs: runs, selection: selection, filter: filter, pending: pending,
                                  now: Date(timeIntervalSince1970: night + 3600), timeZone: utc, locale: locale)
    }

    @Test func everyHostsAutomationsShareOneTableThisMacFirst() {
        let local = Automation(name: "Triage new issues", prompt: "triage", cwd: "/tmp/shepherd")
        let remote = Automation(name: "Nightly migrations dry run", prompt: "migrate", cwd: "/srv/orders")
        let model = make([host(PageHost.localID, PageHost.localName, automations: [local]),
                          host(remoteID, "build-01", automations: [remote])])
        #expect(model.rows.map(\.name) == ["Triage new issues", "Nightly migrations dry run"])
        #expect(model.rows.map(\.host) == ["This Mac", "build-01"])
        #expect(model.rows.map(\.selected) == [true, false], "nothing chosen: the first row is selected")
        #expect(model.total == 2 && model.emptyText == nil)
    }

    @Test func theFilterMatchesNameHostOrPromptAndTheSelectionFollowsIt() {
        let a = Automation(name: "Triage new issues", prompt: "look at sentry", cwd: "/tmp/a")
        let b = Automation(name: "Stale branch cleanup", prompt: "delete merged branches", cwd: "/tmp/b")
        let hosts = [host(PageHost.localID, PageHost.localName, automations: [a]), host(remoteID, "horizon", automations: [b])]
        let keyA = AutomationKey(host: PageHost.localID, automation: a.id)
        #expect(make(hosts, filter: "HORIZON").rows.map(\.name) == ["Stale branch cleanup"])
        #expect(make(hosts, filter: "sentry").rows.map(\.name) == ["Triage new issues"])
        // The selected row filtered out: the first kept row is selected and shown.
        let filtered = make(hosts, selection: keyA, filter: "merged")
        #expect(filtered.rows.map(\.selected) == [true])
        #expect(filtered.detail?.name == "Stale branch cleanup")
        let none = make(hosts, filter: "deploy")
        #expect(none.rows.isEmpty && none.detail == nil && none.total == 2)
        #expect(none.emptyText?.contains("deploy") == true)
        #expect(make([host(PageHost.localID, PageHost.localName, automations: [])]).emptyText?.hasPrefix("No automations yet") == true)
    }

    @Test func lastRunIsEmptyUntilTheRunsAreReadThenSaysHowTheLastOneWent() {
        let automation = Automation(name: "Nightly", prompt: "p", cwd: "/tmp/n", enabled: true)
        let key = AutomationKey(host: remoteID, automation: automation.id)
        let hosts = [host(remoteID, "build-01", automations: [automation])]
        #expect(make(hosts).rows.first?.lastRun == nil)
        let runs = [AutomationRun(startedAt: night - 86_400, settledAt: night - 86_400 + 40, endedAt: night - 86_400 + 60, result: .finished),
                    AutomationRun(startedAt: night, endedAt: night + 660, result: .interrupted)]
        let last = make(hosts, runs: [key: runs]).rows.first?.lastRun
        #expect(last == SHRunOutcome("interrupted", state: .failed, clock: .ago(Date(timeIntervalSince1970: night + 660))))
        #expect(make(hosts, runs: [key: []]).rows.first?.lastRun == SHRunOutcome("not run yet"))
        #expect(make(hosts, runs: [key: [AutomationRun(startedAt: night, endedAt: night + 5, result: .stopped)]]).rows.first?.lastRun?.state == nil,
                "a stopped run is quiet")
    }

    /// A run's agent on the host decides: working counts up, asking glows, a settled one is done.
    @Test(arguments: [(AgentStatus.working, "running", AgentState?.some(.running)), (.blocked, "asked you", .attention),
                      (.done, "finished", .done)])
    func aLiveRunReadsFromItsAgent(status: AgentStatus, word: String, state: AgentState?) {
        let space = Space(name: "Automations", path: "~", hidden: true)
        let pane = LeafPane(cwd: "/tmp")
        let agent = Agent(name: "Nightly", spaceID: space.id, tabID: TabID(), paneID: pane.id, status: status, nameIsFinal: true)
        let automation = Automation(name: "Nightly", prompt: "p", cwd: "/tmp", enabled: true, agentID: agent.id)
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        let run = AutomationRun(startedAt: night, settledAt: status == .done ? night + 30 : nil, result: .running, agentID: agent.id)
        let row = make([host(PageHost.localID, PageHost.localName, automations: [automation], agents: [agent], spaces: [space])],
                       runs: [key: [run]]).rows.first
        #expect(row?.lastRun?.text == word)
        #expect(row?.lastRun?.state == state)
        #expect(row?.run == FleetRef(host: PageHost.localID, agent: agent.id))
        #expect(row?.live == (status != .done))
        #expect(row?.canStop == (status != .done) && row?.canRun == (status == .done))
    }

    /// An offline host's automations and an older host's are read-only; a change on its way
    /// holds that one row's controls.
    @Test func whatCanBeChangedFollowsTheHost() {
        let a = Automation(name: "a", prompt: "p", cwd: "/tmp"), b = Automation(name: "b", prompt: "p", cwd: "/tmp")
        let offline = make([host(remoteID, "horizon", automations: [a], connected: false)])
        let row = offline.rows.first
        #expect(row?.lastRun == SHRunOutcome("host offline"))
        #expect(row?.canToggle == false && row?.canRun == false && row?.canEdit == false)
        #expect(row?.disabledReason == "Host offline", "the row's menu says why Edit and Delete are off")
        #expect(offline.detail?.readOnlyReason == "Host offline")
        #expect(offline.detail?.runsNote == "Runs aren't available from this host.")

        let older = make([host(remoteID, "horizon", automations: [a], manageable: false)])
        #expect(older.rows.first?.canToggle == false)
        #expect(older.detail?.readOnlyReason?.hasPrefix("Update Shepherd on horizon") == true)

        let keyA = AutomationKey(host: PageHost.localID, automation: a.id)
        let pending = make([host(PageHost.localID, PageHost.localName, automations: [a, b])], pending: [keyA])
        #expect(pending.rows.map(\.canToggle) == [false, true])
        #expect(pending.rows.map(\.canRun) == [false, true])
    }

    @Test func theDetailSaysWhatItStartsWhereAndItsRunsNewestFirst() throws {
        let space = Space(name: "Automations", path: "~", hidden: true)
        let pane = LeafPane(cwd: "/srv/orders")
        var agent = Agent(name: "Nightly", spaceID: space.id, tabID: TabID(), paneID: pane.id, status: .done, nameIsFinal: true)
        agent.model = "claude-sonnet"
        let automation = Automation(name: "Nightly migrations dry run", prompt: "Run every pending migration.", cwd: "/srv/orders",
                                    enabled: true, agentID: agent.id)
        let key = AutomationKey(host: remoteID, automation: automation.id)
        let runs = [AutomationRun(startedAt: night - 86_400, settledAt: night - 86_400 + 240, result: .finished),
                    AutomationRun(startedAt: night, settledAt: night + 190, result: .finished, agentID: agent.id)]
        let model = make([host(remoteID, "build-01", automations: [automation], agents: [agent], spaces: [space])], runs: [key: runs])
        let detail = try #require(model.detail)
        #expect(detail.summary == "Starts a thread on build-01 when Shepherd starts")
        #expect(detail.prompt == "Run every pending migration.")
        #expect(detail.facts.map(\.label) == ["When", "Host", "Folder", "Model"])
        #expect(detail.facts.map(\.value) == ["When Shepherd starts", "build-01", "/srv/orders", "claude-sonnet"])
        #expect(detail.runs.map(\.started) == ["Sep 24 02:00", "Sep 23 02:00"])
        #expect(detail.runs.map(\.duration) == ["3m", "4m"])
        #expect(detail.runs.map(\.thread) == [FleetRef(host: remoteID, agent: agent.id), nil], "only a run whose thread exists opens")
        #expect(detail.runsNote == nil && !detail.live && detail.canRun && detail.canEdit)

        let local = Automation(name: "Off one", prompt: "p", cwd: NSHomeDirectory() + "/code", enabled: false)
        let localDetail = make([host(PageHost.localID, PageHost.localName, automations: [local])]).detail
        #expect(localDetail?.summary == "Starts a thread on this Mac when you run it")
        #expect(localDetail?.facts.map(\.value) == ["By hand", "This Mac", "~/code"])
        #expect(localDetail?.runsNote == "Reading runs…")
        let read = make([host(PageHost.localID, PageHost.localName, automations: [local])],
                        runs: [AutomationKey(host: PageHost.localID, automation: local.id): []]).detail
        #expect(read?.runsNote == "No runs yet.")
    }
}
