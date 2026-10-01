import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The sidebar organized by project (Sidebar — Projects): a folder per project in the spaces'
/// order, its threads newest activity first, rolled up while collapsed; idle threads leave after
/// Keep idle threads; hidden projects, the reserved spaces and designs never show; a host's
/// threads join their project by name, or sit in a section per host.
@Suite("Sidebar projects")
@MainActor
struct SidebarProjectsTests {
    private let shepherd = Fixture.space("shepherd", path: "/code/shepherd")
    private let dashboard = Fixture.space("dashboard-web", path: "/code/dashboard-web")
    private let host = UUID()

    private func agent(_ name: String, in space: Space, status: AgentStatus = .idle, at: Double? = nil,
                       waiting: String? = nil) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.waitingOn = waiting
        return agent
    }

    private func tree(_ state: ShepherdState, hosts: [SidebarSource.Host] = [], groupByHost: Bool = false,
                      cutoff: Double? = nil) -> SidebarTree {
        SidebarDerivation.tree(SidebarSource(local: state, hosts: hosts),
                               options: SidebarTreeOptions(groupByHost: groupByHost, idleCutoff: cutoff))
    }

    private func titles(_ project: SidebarProject?) -> [String] { project?.rows.map(\.title) ?? [] }

    // MARK: Grouping and order

    /// Projects keep the spaces' order (the drag order; new ones are added on top), an empty
    /// project still shows, and inside one the newest activity comes first.
    @Test func projectsFollowTheSpacesOrderAndThreadsTheNewestFirst() {
        let empty = Fixture.space("dotfiles")
        let state = ShepherdState(spaces: [dashboard, shepherd, empty], agents: [
            agent("old", in: shepherd, at: 10), agent("new", in: shepherd, at: 30), agent("untimed", in: shepherd),
            agent("funnel", in: dashboard, at: 20),
        ])
        let projects = tree(state).projects
        #expect(projects.map(\.name) == ["dashboard-web", "shepherd", "dotfiles"])
        #expect(titles(projects[1]) == ["new", "old", "untimed"])
        #expect(projects[2].rows.isEmpty)
        #expect(tree(state).sections.map(\.header) == [.projects])
    }

    /// Needs you rows stay in their project with the amber dot and the question; a collapsed
    /// project rolls up amber while something waits, a running dot while something runs.
    @Test func needsYouStaysInItsProjectAndRollsUp() {
        let quiet = Fixture.space("dotfiles")
        let state = ShepherdState(spaces: [shepherd, dashboard, quiet], agents: [
            agent("asks", in: shepherd, status: .blocked, at: 5, waiting: "Approve the plan?"),
            agent("runs", in: shepherd, status: .working, at: 4),
            agent("runs too", in: dashboard, status: .working, at: 3),
            agent("done", in: quiet, status: .done, at: 2),
        ])
        let projects = tree(state).projects
        #expect(projects.map(\.rollup) == [.waiting, .running, .quiet])
        let asks = projects[0].rows.first
        #expect(asks?.title == "asks" && asks?.leading == .dot(.attention))
        #expect(asks?.accessory == .reason(SidebarDerivation.reason(question: "Approve the plan?")))
    }

    // MARK: Leaving the tree

    /// After Keep idle threads, idle and finished threads leave the tree; running ones, ones
    /// waiting on you, and ones no host has timed stay.
    @Test func idleThreadsLeaveAfterTheCutoffButRunningAndWaitingStay() {
        let state = ShepherdState(spaces: [shepherd], agents: [
            agent("recent", in: shepherd, status: .done, at: 200),
            agent("stale idle", in: shepherd, status: .idle, at: 50),
            agent("stale done", in: shepherd, status: .done, at: 60),
            agent("stale running", in: shepherd, status: .working, at: 40),
            agent("stale asking", in: shepherd, status: .blocked, at: 30, waiting: "Ship it?"),
            agent("untimed", in: shepherd),
        ])
        #expect(titles(tree(state, cutoff: 100).projects.first) == ["recent", "stale running", "stale asking", "untimed"])
        #expect(tree(state).projects.first?.rows.count == 6, "Forever keeps them all")
    }

    @Test(arguments: [(0, nil), (7, 1_000_000.0 * 3600 * 1000 - 7 * 86_400_000)] as [(Int, Double?)])
    func theCutoffIsDaysBeforeNowToTheHour(days: Int, cutoff: Double?) {
        let now = Date(timeIntervalSince1970: 1_000_000 * 3600 + 1_799)
        #expect(SidebarTreeOptions.idleCutoff(days: days, now: now) == cutoff)
    }

    /// Hide from Sidebar takes a project and its threads out of the tree and lists it for the +
    /// beside Projects; the reserved spaces are never projects.
    @Test func hiddenProjectsAndTheReservedSpacesAreNotInTheTree() {
        var tucked = Fixture.space("dotfiles")
        tucked.sidebarHidden = true
        let automations = Space(name: "Automations", path: "~", hidden: true)
        let designs = Space.designs()
        let state = ShepherdState(spaces: [shepherd, tucked, automations, designs], agents: [
            agent("kept", in: shepherd, at: 1), agent("tucked away", in: tucked, at: 2),
            agent("orphan run", in: automations, at: 3), agent("design chat", in: designs, at: 4),
        ])
        let built = tree(state)
        #expect(built.projects.map(\.name) == ["shepherd"])
        #expect(titles(built.projects.first) == ["kept"])
        #expect(built.hiddenProjects.map(\.id) == [tucked.id])
    }

    /// Designs stay under Designs and in ⌘K (the user's decision, 2026-09-26): neither a design
    /// nor its agent is a row, even with the Design tool on.
    @Test func designsAreNotInTheTree() {
        let designs = Space.designs()
        var chat = agent("design chat", in: designs, at: 5)
        let design = Design(name: "Checkout", agentID: chat.id, createdAt: 1)
        chat.designID = design.id
        var build = agent("system build", in: shepherd, at: 6)
        build.designID = DesignID()
        var state = ShepherdState(spaces: [shepherd, designs], agents: [chat, build, agent("thread", in: shepherd, at: 1)])
        state.designs = [design]
        let built = SidebarDerivation.tree(SidebarSource(local: state, designs: true), options: SidebarTreeOptions())
        #expect(built.projects.map(\.name) == ["shepherd"])
        #expect(titles(built.projects.first) == ["thread"])
    }

    /// An automation's run lives in the project its folder is in (the deepest that holds it),
    /// with its bolt; one whose folder no project holds is not in the tree.
    @Test func automationRunsLiveInTheProjectTheirFolderIsIn() {
        let nested = Fixture.space("web", path: "/code/shepherd/web")
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let inWeb = agent("Nightly", in: runs, status: .done, at: 3)
        let inRoot = agent("Merge PR", in: runs, status: .done, at: 2)
        let nowhere = agent("Elsewhere", in: runs, status: .done, at: 1)
        var state = ShepherdState(spaces: [shepherd, nested, runs], agents: [inWeb, inRoot, nowhere])
        state.automations = [
            Automation(name: "Nightly", prompt: "p", cwd: "/code/shepherd/web/app", agentID: inWeb.id),
            Automation(name: "Merge PR", prompt: "p", cwd: "/code/shepherd/", agentID: inRoot.id),
            Automation(name: "Elsewhere", prompt: "p", cwd: "/code/shepherd-daemon", agentID: nowhere.id),
        ]
        let projects = tree(state).projects
        #expect(titles(projects.first { $0.name == "shepherd" }) == ["Merge PR"])
        #expect(titles(projects.first { $0.name == "web" }) == ["Nightly"])
        #expect(projects.first { $0.name == "web" }?.rows.first?.leading == .glyph("bolt", attention: false))
    }

    // MARK: Hosts

    private func remoteHost(_ name: String = "horizon", spaces: [Space], agents: [Agent], offline: Bool = false,
                            id: UUID? = nil) -> SidebarSource.Host {
        SidebarSource.Host(id: id ?? host, name: name, state: ShepherdState(spaces: spaces, agents: agents),
                           offline: offline)
    }

    /// Not grouped, a host's threads sit in the project of the same name, tagged with the host
    /// like Recents; a project only a host has follows This Mac's, by name.
    @Test func aHostsThreadsJoinTheirProjectByNameWithTheHostAsATag() {
        let theirs = Fixture.space("shepherd", path: "/srv/shepherd")
        let daemon = Fixture.space("shepherd-daemon", path: "/srv/daemon")
        let state = ShepherdState(spaces: [shepherd], agents: [agent("mine", in: shepherd, at: 10)])
        let built = tree(state, hosts: [remoteHost(spaces: [theirs, daemon], agents: [
            agent("theirs", in: theirs, at: 20), agent("daemon work", in: daemon, status: .working, at: 5),
        ])])
        #expect(built.projects.map(\.id) == [.local(shepherd.id), .named("shepherd-daemon")])
        #expect(titles(built.projects.first) == ["theirs", "mine"])
        #expect(built.projects.first?.rows.first?.accessory == .tag("horizon"))
        #expect(built.projects.first?.places == [nil: shepherd.id, host: theirs.id])
        #expect(built.projects.last?.rollup == .running)
    }

    /// Grouped, a section per host, This Mac first, each with its projects; the rows lose the
    /// host's tag, and an unreachable host says so and dims what it last sent.
    @Test func groupedByHostEachHostIsASectionThisMacFirst() {
        let theirs = Fixture.space("shepherd", path: "/srv/shepherd")
        let state = ShepherdState(spaces: [shepherd], agents: [agent("mine", in: shepherd, at: 10)])
        let away = UUID()
        let built = tree(state, hosts: [
            remoteHost("build-01", spaces: [theirs], agents: [agent("theirs", in: theirs, at: 20)]),
            remoteHost("horizon", spaces: [dashboard], agents: [agent("stale", in: dashboard, at: 1)], offline: true, id: away),
        ], groupByHost: true)
        #expect(built.sections.map(\.header) == [
            .host(name: "This Mac", id: nil, unreachable: false),
            .host(name: "build-01", id: host, unreachable: false),
            .host(name: "horizon", id: away, unreachable: true),
        ])
        #expect(built.sections.map { $0.projects.map(\.id) } == [
            [.local(shepherd.id)], [.remote(hostID: host, theirs.id)], [.remote(hostID: away, dashboard.id)],
        ])
        #expect(built.sections[1].projects.first?.rows.first?.accessory == NWSidebarRow.Accessory.none)
        #expect(built.sections[2].projects.first?.dimmed == true)
        #expect(built.sections[2].projects.first?.rows.first?.offline == true)
    }

    // MARK: Presentation

    /// Closed projects show no threads (their rows are not built); the row on screen is marked,
    /// and while ⌘ is held the first nine visible threads wear their digit.
    @Test func collapsedProjectsHideTheirThreadsAndDigitsSkipThem() {
        let rows = (0..<6).map { agent("s\($0)", in: shepherd, at: Double(100 - $0)) }
            + (0..<6).map { agent("d\($0)", in: dashboard, at: Double(50 - $0)) }
        let built = tree(ShepherdState(spaces: [shepherd, dashboard], agents: rows))
        let open = built.items(collapsed: [], selected: .local(rows[7].id), shortcuts: true, connected: [])
        #expect(open.count == 1 + 2 + 12)
        let threads = open.compactMap { if case .row(let row) = $0 { row } else { nil } }
        #expect(threads.prefix(9).map(\.accessory) == (1...9).map { .shortcut("⌘\($0)") })
        #expect(threads.filter(\.selected).map(\.title) == ["d1"])

        let closed = built.items(collapsed: [SidebarProjectID.local(shepherd.id).key], selected: nil, shortcuts: true, connected: [])
        let visible = closed.compactMap { if case .row(let row) = $0 { row.title } else { nil } }
        #expect(visible == (0..<6).map { "d\($0)" })
        #expect(built.visibleRows(collapsed: [SidebarProjectID.local(shepherd.id).key]).map(\.title) == visible)
        if case .project(let project)? = closed.dropFirst().first {
            #expect(!project.expanded && project.count == 6 && project.movable)
        } else {
            Issue.record("the first project's row follows the header")
        }
    }

    /// + and New thread start in the project on the host its newest thread runs on, else This
    /// Mac, else a connected host that has it.
    @Test func aNewThreadStartsOnTheHostOfTheNewestThread() {
        let theirs = Fixture.space("shepherd", path: "/srv/shepherd")
        let hostAgents = [agent("theirs", in: theirs, at: 20)]
        let state = ShepherdState(spaces: [shepherd], agents: [agent("mine", in: shepherd, at: 10)])
        let project = tree(state, hosts: [remoteHost(spaces: [theirs], agents: hostAgents)]).projects.first
        #expect(project?.newThreadPlace(connected: [host])?.host == host)
        #expect(project?.newThreadPlace(connected: [host])?.space == theirs.id)
        #expect(project?.newThreadPlace(connected: [])?.host == nil, "the host is away: This Mac")
        let remoteOnly = tree(ShepherdState(), hosts: [remoteHost(spaces: [theirs], agents: [])]).projects.first
        #expect(remoteOnly?.newThreadPlace(connected: [host])?.space == theirs.id)
        #expect(remoteOnly?.newThreadPlace(connected: []) == nil)
    }

    /// A drag's offset lands the project before the one under the pointer, or last; a drop where
    /// it already is changes nothing.
    @Test(arguments: [
        (0, 3.0, "c"), (0, 10.0, nil), (2, -4.0, "a"), (2, -2.0, "b"), (0, 0.4, "none"), (1, 1.0, "none"),
    ] as [(Int, Double, String?)])
    func aDraggedProjectLandsBeforeTheOneUnderThePointer(dragged: Int, rows: Double, before: String?) throws {
        let spaces = ["a", "b", "c"].map { Fixture.space($0) }
        let agents = spaces.map { agent("in \($0.name)", in: $0, at: 1) }
        let items = tree(ShepherdState(spaces: spaces, agents: agents)).items(collapsed: [], selected: nil, shortcuts: false, connected: [])
        let pitch: CGFloat = 29
        let plan = ProjectDrop.plan(ProjectDrag(id: .local(spaces[dragged].id), offset: CGFloat(rows) * pitch), items: items, pitch: pitch)
        switch before {
        case "none": #expect(plan == nil)
        case nil:
            #expect(plan?.before == nil && plan?.edge == .bottom)
            #expect(plan?.line == items.last?.id)
        case let name?:
            let target = try #require(spaces.first { $0.name == name })
            #expect(plan?.before == target.id && plan?.edge == .top)
        }
    }
}
