import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Recents: every agent, local and remote, most recently active first, in an order that only a
/// turn starting or ending (or a send) moves.
@Suite("Sidebar Recents")
@MainActor
struct SidebarRecentsTests {
    private let space = Fixture.space("shepherd")
    private let host = UUID()

    private func agent(_ name: String, status: AgentStatus = .idle, at: Double? = nil, waiting: String? = nil) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.waitingOn = waiting
        return agent
    }

    private func source(_ local: [Agent], remote: [Agent] = [], children: [AgentID: [ChildRun]] = [:],
                        remoteChildren: [AgentID: [ChildRun]] = [:]) -> SidebarSource {
        SidebarSource(local: ShepherdState(spaces: [space], agents: local), localChildren: children,
                      hosts: remote.isEmpty ? [] : [SidebarSource.Host(id: host, name: "horizon",
                                                                        state: ShepherdState(spaces: [space], agents: remote),
                                                                        children: remoteChildren)])
    }

    @Test func recentsAreMostRecentlyActiveFirstAcrossHosts() {
        let lists = SidebarDerivation.lists(source(
            [agent("old", at: 10), agent("new", at: 30), agent("untimed")],
            remote: [agent("remote", at: 20), agent("remote untimed")]))
        #expect(lists.recents.map(\.title) == ["new", "remote", "old", "untimed", "remote untimed"])
    }

    /// Agents no host has timed follow, newest created first.
    @Test func untimedAgentsFollowNewestCreatedFirst() {
        let lists = SidebarDerivation.lists(source([agent("first"), agent("second"), agent("third")]))
        #expect(lists.recents.map(\.title) == ["third", "second", "first"])
    }

    /// A status report or a streamed token changes a row, never the order: only `lastActiveAt`
    /// orders.
    @Test func aStatusChangeAloneKeepsTheOrder() {
        let a = agent("a", at: 20), b = agent("b", at: 10)
        var working = b
        working.status = .working
        let before = SidebarDerivation.lists(source([a, b])).recents.map(\.id)
        let after = SidebarDerivation.lists(source([a, working])).recents.map(\.id)
        #expect(before == after)
    }

    /// Turns starting and ending move an agent up; asking and being answered happen inside a
    /// turn, and a repeated report is no change at all.
    @Test(arguments: [
        (AgentStatus.idle, AgentStatus.working, true), (.done, .working, true), (.working, .done, true),
        (.working, .idle, true), (.blocked, .done, true), (.working, .blocked, false), (.blocked, .working, false),
        (.working, .working, false), (.idle, .idle, false), (.done, .idle, false),
    ])
    func turnsStartingAndEndingMoveAnAgentUp(from: AgentStatus, to: AgentStatus, moves: Bool) {
        #expect(AgentStatus.movesRecents(from: from, to: to) == moves)
    }

    @Test func rowsCarryTheirStateAndTrailingWord() {
        let since = Date(timeIntervalSince1970: 100)
        var failed = agent("failed", at: 5)
        failed.status = .done
        let running = agent("running", status: .working, at: 4)
        let lists = SidebarDerivation.lists(SidebarSource(
            local: ShepherdState(spaces: [space], agents: [failed, running, agent("idle", at: 3), agent("done", status: .done, at: 2)]),
            failedTurns: [failed.id], statusSince: [running.id: since],
            hosts: [SidebarSource.Host(id: host, name: "horizon",
                                       state: ShepherdState(spaces: [space], agents: [agent("remote", status: .working, at: 1)]),
                                       children: [:])]))
        let rows = Dictionary(uniqueKeysWithValues: lists.recents.map { ($0.title, $0) })
        #expect(rows["failed"]?.leading == .dot(.failed))
        #expect(rows["failed"]?.accessory == NWSidebarRow.Accessory.none)
        #expect(rows["running"]?.leading == .dot(.running))
        #expect(rows["running"]?.accessory == .elapsed(since: since))
        #expect(rows["idle"]?.leading == .dot(.idle))
        #expect(rows["done"]?.leading == .dot(.done))
        // A remote thread carries its host's name as a tag; This Mac's carry none.
        #expect(rows["remote"]?.leading == .dot(.running))
        #expect(rows["remote"]?.accessory == .tag("horizon"))
        #expect(rows["remote"]?.accessibilityLabel == "remote, running, on horizon")
    }

    /// An automation's run is in Recents with the bolt, and "done" once it settles.
    @Test func automationRunsAreRecentsWithTheirBolt() {
        let run = agent("Nightly", status: .done, at: 1)
        let automation = Automation(name: "Nightly", prompt: "p", cwd: "/tmp", agentID: run.id)
        var state = ShepherdState(spaces: [space], agents: [run])
        state.automations = [automation]
        let settled = AutomationRun(startedAt: 0, settledAt: 1, result: .finished, agentID: run.id)
        let lists = SidebarDerivation.lists(SidebarSource(local: state, openRuns: [automation.id: settled]))
        let row = lists.recents.first
        #expect(row?.leading == .glyph("bolt", attention: false))
        #expect(row?.accessory == .text("done"))
        #expect(row?.automation == automation.id)
        #expect(row?.automationLive == false)
        #expect(row?.accessibilityLabel == "Nightly, automation, done")
    }

    @Test func theSelectedRowAndTheFirstNineRecentsWearTheirMarks() {
        let agents = (0..<11).map { agent("a\($0)", at: Double(100 - $0)) }
        var blocked = agent("asks", status: .blocked, at: 200)
        blocked.waitingOn = "Ship it?"
        let lists = SidebarDerivation.lists(source(agents + [blocked]))
        let presented = lists.presented(selected: .local(agents[2].id), shortcuts: true)
        #expect(presented.recents.map(\.selected) == (0..<11).map { $0 == 2 })
        #expect(presented.recents.prefix(9).map(\.accessory) == (1...9).map { .shortcut("⌘\($0)") })
        #expect(presented.recents.dropFirst(9).allSatisfy { $0.accessory == NWSidebarRow.Accessory.none })
        // ⌘1–9 are Recents': Needs you keeps its reason.
        #expect(presented.needsYou.first?.accessory == .reason("Ship it?"))
    }
}

/// Needs you: everything waiting on you, with the short reason why.
@Suite("Sidebar Needs you")
@MainActor
struct SidebarNeedsYouTests {
    private let space = Fixture.space("shepherd")

    @Test func blockedAgentsAndAskingSubagentsNeedYouAndLeaveRecents() {
        var blocked = Fixture.agent("blocked", in: space).agent
        blocked.status = .blocked
        blocked.waitingOn = "Retention: 30 days or 13 months?"
        let parent = Fixture.agent("parent", in: space).agent
        var reviewer = Fixture.child("r1", attention: true)
        reviewer.role = "reviewer"
        let quiet = Fixture.agent("quiet", in: space).agent
        let lists = SidebarDerivation.lists(SidebarSource(
            local: ShepherdState(spaces: [space], agents: [blocked, parent, quiet]),
            localChildren: [parent.id: [reviewer], quiet.id: [Fixture.child("live")]]))
        #expect(Set(lists.needsYou.map(\.title)) == ["blocked", "parent"])
        #expect(lists.recents.map(\.title) == ["quiet"])
        let rows = Dictionary(uniqueKeysWithValues: lists.needsYou.map { ($0.title, $0) })
        #expect(rows["blocked"]?.leading == .dot(.attention))
        #expect(rows["blocked"]?.accessory == .reason("Retention…"))
        #expect(rows["parent"]?.accessory == .reason("reviewer"))
    }

    /// The question's own text, else the subagent asking, else ASK.
    @Test func theReasonIsTheQuestionThenTheSubagentThenAsk() {
        var named = Fixture.child("run", attention: true)
        named.role = "planner"
        #expect(SidebarDerivation.reason(question: "approve plan", children: [named]) == "approve plan")
        #expect(SidebarDerivation.reason(question: "  ", children: [named]) == "planner")
        #expect(SidebarDerivation.reason(question: nil, children: [Fixture.child("labelled", attention: true)]) == "labelled")
        #expect(SidebarDerivation.reason(question: nil, children: [Fixture.child("live")]) == "ASK")
        #expect(SidebarDerivation.reason(question: nil, children: []) == "ASK")
    }

    @Test(arguments: [
        ("retention?", "retention?"),
        ("approve plan", "approve plan"),
        ("Which base branch should I use?", "Which base…"),
        ("Supercalifragilistic", "Supercalifrag…"),
        ("two\nlines", "two lines"),
    ])
    func aReasonIsOneShortLine(text: String, reason: String) {
        #expect(SidebarDerivation.shortened(text) == reason)
        #expect(SidebarDerivation.shortened(text).count <= NWSidebarMetrics.reasonLength)
    }

    /// An automation run that asks leads with its bolt in lantern; a remote one keeps its reason
    /// rather than its host's tag.
    @Test func automationRunsAndRemoteThreadsNeedYouToo() {
        var run = Fixture.agent("Nightly", in: space).agent
        run.status = .blocked
        var state = ShepherdState(spaces: [space], agents: [run])
        state.automations = [Automation(name: "Nightly", prompt: "p", cwd: "/tmp", agentID: run.id)]
        var remote = Fixture.agent("remote", in: space).agent
        remote.status = .blocked
        remote.waitingOn = "merge?"
        let lists = SidebarDerivation.lists(SidebarSource(local: state, hosts: [
            SidebarSource.Host(id: UUID(), name: "horizon", state: ShepherdState(spaces: [space], agents: [remote]), children: [:]),
        ]))
        let rows = Dictionary(uniqueKeysWithValues: lists.needsYou.map { ($0.title, $0) })
        #expect(rows["Nightly"]?.leading == .glyph("bolt", attention: true))
        #expect(rows["Nightly"]?.accessory == .reason("ASK"))
        #expect(rows["remote"]?.accessory == .reason("merge?"))
        #expect(rows["remote"]?.accessibilityLabel == "remote, needs you, on horizon")
    }
}

/// The destinations never move; More holds Hosts and Extensions. Missions, Designs, Design
/// systems and Archive are not built, so they are not shown.
@Suite("Sidebar destinations")
struct SidebarDestinationTests {
    @Test func closedMoreShowsThreeDestinations() {
        let rows = SidebarDerivation.destinations(shown: nil, moreOpen: false, offlineHosts: 1, newThreadChord: "⌘N")
        #expect(rows.map(\.title) == ["New thread", "Automations", "More"])
        #expect(rows[0].trailing == .keycaps("⌘N"))
        #expect(rows[0].icon == .newThread)
        #expect(rows[2].icon == .disclosure(open: false))
        #expect(rows.allSatisfy { !$0.selected })
    }

    @Test func openMoreHoldsHostsWithTheOfflineCountAndExtensions() {
        let rows = SidebarDerivation.destinations(shown: .hosts, moreOpen: true, offlineHosts: 2, newThreadChord: "⌘N")
        #expect(rows.map(\.title) == ["New thread", "Automations", "More", "Hosts", "Extensions"])
        #expect(rows[3].trailing == .alert("2 offline"))
        #expect(rows[3].selected && rows[3].child && rows[4].child)
        #expect(rows[4].target == .extensions)
        #expect(!rows.contains { ["Missions", "Designs", "Design systems", "Archive"].contains($0.title) })
    }

    @Test func noOfflineHostsMeansNoBadge() {
        let rows = SidebarDerivation.destinations(shown: .newThread, moreOpen: true, offlineHosts: 0, newThreadChord: "⇧⌘N")
        #expect(rows[3].trailing == .none)
        #expect(rows[0].selected && rows[0].trailing == .keycaps("⇧⌘N"))
    }

    @Test(arguments: [("build-01", "This Mac · build-01"), ("  ", "This Mac"), (nil, "This Mac")] as [(String?, String)])
    func theFooterSaysThisMacAndItsName(computer: String?, detail: String) {
        #expect(SidebarDerivation.footerDetail(computerName: computer) == detail)
    }

    @Test(arguments: [("Baily Case", "B"), ("  ada", "A"), ("", "")])
    func theFootersAvatarIsTheInitial(name: String, initial: String) {
        #expect(NWSidebarFooter.initial(name) == initial)
    }
}

/// The New thread page's workplace chip: every host's projects (nested spaces flattened), the
/// chosen one checked, "Add folder…" on each host.
@Suite("New thread workplace")
struct NewThreadPlacesTests {
    private let mono = Fixture.space("mono", path: "/Users/dev/mono")
    private let sub = Fixture.space("sub", path: "/Users/dev/mono/sub")
    private let web = Fixture.space("web", path: "/Users/dev/web")
    private let hostID = UUID()

    private var hosts: [NewThreadPlaces.Host] {
        [NewThreadPlaces.Host(id: nil, name: "This Mac", spaces: [mono, sub]),
         NewThreadPlaces.Host(id: hostID, name: "horizon", spaces: [web])]
    }

    @Test func everyHostsProjectsAreListedFlatWithTheChosenOneChecked() {
        let sections = NewThreadPlaces.sections(hosts, chosen: NewThreadPlace(host: nil, space: sub.id))
        #expect(sections.map(\.title) == ["This Mac", "horizon"])
        #expect(sections[0].options.map(\.title) == ["mono", "sub"])
        #expect(sections[0].options.map(\.detail) == ["~/mono", "~/mono/sub"])
        #expect(sections[0].options.map(\.isCurrent) == [false, true])
        #expect(sections.allSatisfy { $0.addTitle == "Add folder…" })
        #expect(NewThreadPlaces.place(sections[1].options[0]) == NewThreadPlace(host: hostID, space: web.id))
        #expect(NewThreadPlaces.host(of: sections[0]) == nil)
        #expect(NewThreadPlaces.host(of: sections[1]) == hostID)
    }

    @Test func theChipSaysProjectAndHost() {
        #expect(NewThreadPlaces.chip(hosts, chosen: NewThreadPlace(host: hostID, space: web.id)) == ("web", "horizon"))
        #expect(NewThreadPlaces.chip(hosts, chosen: nil) == ("Choose a project", "This Mac"))
    }

    /// The chosen project while it exists, else the last thread's, else This Mac's first, else a
    /// host's.
    @Test func thePageOpensOnAProjectThatExists() {
        let gone = NewThreadPlace(host: nil, space: SpaceID())
        let recent = NewThreadPlace(host: hostID, space: web.id)
        #expect(NewThreadPlaces.fallback(hosts, chosen: NewThreadPlace(host: nil, space: sub.id), recent: recent)
            == NewThreadPlace(host: nil, space: sub.id))
        #expect(NewThreadPlaces.fallback(hosts, chosen: gone, recent: recent) == recent)
        #expect(NewThreadPlaces.fallback(hosts, chosen: gone, recent: nil) == NewThreadPlace(host: nil, space: mono.id))
        let remoteOnly = [NewThreadPlaces.Host(id: nil, name: "This Mac", spaces: []), hosts[1]]
        #expect(NewThreadPlaces.fallback(remoteOnly, chosen: nil, recent: nil) == recent)
        #expect(NewThreadPlaces.fallback([NewThreadPlaces.Host(id: nil, name: "This Mac", spaces: [])], chosen: nil, recent: nil) == nil)
    }
}

@Suite("Sidebar words")
@MainActor
struct SidebarWordTests {
    @Test(arguments: [
        (AgentStatus.working, "running"), (.blocked, "needs you"), (.idle, "idle"), (.done, "done"),
    ])
    func statusWordsMatchTheStatusLanguage(status: AgentStatus, word: String) {
        #expect(AgentRow.statusWord(status) == word)
    }

    /// A failed turn qualifies only a finished agent: the sidebar row, the palette's subtitle,
    /// and an automation's row all read failed until the next turn starts.
    @Test(arguments: [
        (AgentStatus.done, "failed", AgentState.failed),
        (.working, "running", .running),
        (.blocked, "needs you", .attention),
    ])
    func aFailedTurnReadsFailedEverywhereItsStatusShows(status: AgentStatus, word: String, state: AgentState) {
        #expect(AgentRow.statusWord(status, turnFailed: true) == word)
        var agent = Fixture.agent("Nightly run", in: Fixture.space("s")).agent
        agent.status = status
        let run = AutomationRun(startedAt: 0, settledAt: 1, result: .finished, agentID: agent.id)
        #expect(AutomationRow.stateWord(agent, run: run, turnFailed: true) == word)
        #expect(AutomationRow.state(agent, run: run, turnFailed: true) == state)
    }

    /// Its menu offers Stop while the run is going, by the rule the host refuses Run Now by: a
    /// run whose pi is still starting (idle before any turn settled) reads running and stops,
    /// and only a settled run reads done and runs again (replacing it), like one that is stopped.
    @Test(arguments: [
        (AgentStatus?.none, false, "stopped", AgentState.idle, false),
        (.idle, false, "running", .running, true),
        (.working, false, "running", .running, true),
        (.blocked, false, "needs you", .attention, true),
        (.idle, true, "done", .done, false),
        (.working, true, "running", .running, true),
        (.blocked, true, "needs you", .attention, true),
        (.done, true, "done", .done, false),
    ])
    func anAutomationRowReadsItsRunsStatus(status: AgentStatus?, settled: Bool, word: String, state: AgentState, live: Bool) {
        let agent = status.map { status in
            var agent = Fixture.agent("Nightly run", in: Fixture.space("s")).agent
            agent.status = status
            return agent
        }
        let run = agent.map { AutomationRun(startedAt: 0, settledAt: settled ? 1 : nil, result: .running, agentID: $0.id) }
        #expect(AutomationRow.stateWord(agent, run: run, turnFailed: false) == word)
        #expect(AutomationRow.state(agent, run: run, turnFailed: false) == state)
        #expect(AutomationRow.isLive(agent, run: run) == live)
    }

    @Test func eachSpaceListsOnlyItsOwnAgents() {
        let a = Fixture.space("a")
        let b = Fixture.space("b")
        let state = ShepherdState(spaces: [a, b], agents: [
            Fixture.agent("one", in: a).agent, Fixture.agent("two", in: b).agent, Fixture.agent("three", in: a).agent,
        ])
        #expect(ShepherdViewModel.agents(in: state, space: a.id).map(\.name) == ["one", "three"])
        #expect(ShepherdViewModel.agents(in: state, space: SpaceID()).isEmpty)
    }
}
