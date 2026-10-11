import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Pinned: the first, exclusive sidebar group, and what it does to the
/// order, the digits and the walk.
@Suite("Sidebar Pinned")
@MainActor
struct SidebarPinnedTests {
    private let space = Fixture.space("shepherd")
    private let host = UUID()

    private func agent(_ name: String, status: AgentStatus = .idle, at: Double? = nil, waiting: String? = nil) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.waitingOn = waiting
        return agent
    }

    private func local(_ agent: Agent) -> PinnedThread { .local(agent.id) }
    private func remote(_ agent: Agent, on host: UUID? = nil) -> PinnedThread {
        .remote(RemoteAgentRef(hostID: host ?? self.host, agentID: agent.id))
    }

    private func derive(_ local: [Agent], remote: [Agent] = [], offline: Bool = false, pins: [PinnedThread]) -> SidebarLists {
        SidebarDerivation.lists(
            SidebarSource(local: ShepherdState(spaces: [space], agents: local),
                          hosts: remote.isEmpty ? [] : [SidebarSource.Host(id: host, name: "horizon",
                                                                            state: ShepherdState(spaces: [space], agents: remote),
                                                                            offline: offline)]),
            pins: SidebarPins(pins))
    }

    @Test func nothingPinnedHasNoPinnedSection() {
        let lists = derive([agent("a", at: 2), agent("b", at: 1)], pins: [])
        #expect(lists.pinned.isEmpty)
        #expect(lists.recents.map(\.title) == ["a", "b"])
    }

    /// Needs you, then Pinned (the board draws no Pinned, so it never displaces a drawn group), then Recents, one row per thread.
    @Test func pinnedThreadsSitFirstAndLeaveRecents() {
        var asking = agent("asks", status: .blocked, at: 50, waiting: "Ship it?")
        asking.waitingReason = "ship it?"
        let old = agent("old", at: 10), new = agent("new", at: 30), middle = agent("middle", at: 20)
        let lists = derive([asking, old, new, middle], pins: [local(old)])
        #expect(lists.needsYou.map(\.title) == ["asks"])
        #expect(lists.pinned.map(\.title) == ["old"])
        #expect(lists.recents.map(\.title) == ["new", "middle"])
        #expect(lists.all.map(\.title) == ["asks", "old", "new", "middle"])
        #expect(Set(lists.all.map(\.id)).count == lists.all.count)
    }

    /// In the order they were pinned, not by activity: a turn doesn't move a pinned row.
    @Test func pinnedThreadsKeepTheOrderTheyWerePinnedIn() {
        let a = agent("a", at: 30), b = agent("b", at: 20), c = agent("c", at: 10)
        #expect(derive([a, b, c], pins: [local(c), local(a), local(b)]).pinned.map(\.title) == ["c", "a", "b"])
        var busy = a
        busy.lastActiveAt = 99
        #expect(derive([busy, b, c], pins: [local(c), local(a), local(b)]).pinned.map(\.title) == ["c", "a", "b"])
    }

    /// Pinning wins. Status changes update the row without moving it out of Pinned.
    @Test func aPinnedThreadThatNeedsYouStaysPinned() {
        let other = agent("other", at: 5)
        var pinned = agent("pinned", status: .blocked, at: 9, waiting: "Approve the plan?")
        let asking = derive([pinned, other], pins: [local(pinned), local(other)])
        #expect(asking.needsYou.isEmpty)
        #expect(asking.pinned.first?.pinned == true)
        #expect(asking.pinned.first?.accessory == .reason("Approve the…"))
        #expect(asking.pinned.map(\.title) == ["pinned", "other"])
        #expect(asking.recents.isEmpty)
        pinned.status = .working
        pinned.waitingOn = nil
        let answered = derive([pinned, other], pins: [local(pinned), local(other)])
        #expect(answered.needsYou.isEmpty)
        #expect(answered.pinned.map(\.title) == ["pinned", "other"])
    }

    /// A remote thread pins like a local one, keeps its host's tag and reads "on horizon".
    @Test func aPinnedRemoteThreadWearsItsHostTag() {
        let remote = agent("remote", status: .working, at: 1)
        let lists = derive([agent("here", at: 2)], remote: [remote], pins: [self.remote(remote)])
        #expect(lists.pinned.map(\.title) == ["remote"])
        #expect(lists.pinned.first?.id == .remote(RemoteAgentRef(hostID: host, agentID: remote.id)))
        #expect(lists.pinned.first?.accessory == .tag("horizon"))
        #expect(lists.pinned.first?.accessibilityLabel == "remote, running, on horizon, pinned")
        #expect(lists.recents.map(\.title) == ["here"])
    }

    /// A host that dropped keeps its threads as it last sent them: pinned, dimmed, no longer asking.
    @Test func aPinnedThreadOnAnOfflineHostStaysPinnedAndDimmed() {
        var asking = agent("asks", status: .blocked, at: 3, waiting: "Ship it?")
        asking.waitingReason = "ship it?"
        let lists = derive([], remote: [asking], offline: true, pins: [remote(asking)])
        #expect(lists.needsYou.isEmpty)
        #expect(lists.pinned.map(\.title) == ["asks"])
        #expect(lists.pinned.first?.offline == true)
    }

    /// The same agent id on another host, or on This Mac, is another thread.
    @Test func aPinNamesItsHostAndNoOther() {
        let twin = agent("twin", at: 1)
        let lists = derive([twin], remote: [twin], pins: [remote(twin)])
        #expect(lists.pinned.map(\.id) == [.remote(RemoteAgentRef(hostID: host, agentID: twin.id))])
        #expect(lists.recents.map(\.id) == [.local(twin.id)])
        #expect(derive([twin], remote: [twin], pins: [remote(twin, on: UUID())]).pinned.isEmpty)
    }

    /// A pin whose thread isn't listed (deleted, or its host not reached yet) lists nothing and
    /// costs the others nothing.
    @Test func aPinWithNoThreadListsNothing() {
        let there = agent("there", at: 1), gone = agent("gone")
        let lists = derive([there], pins: [local(gone), local(there)])
        #expect(lists.pinned.map(\.title) == ["there"])
        #expect(lists.recents.isEmpty)
    }

    @Test func automationRunsAndDesignsAreNeverPinned() {
        let run = agent("Nightly", status: .done, at: 1)
        let automation = Automation(name: "Nightly", prompt: "p", cwd: "/tmp", agentID: run.id)
        var drawer = agent("Dashboard", at: 2)
        let design = Design(name: "Dashboard", agentID: drawer.id, createdAt: 1_000, lastActiveAt: 55, boardCount: 4)
        drawer.designID = design.id
        var state = ShepherdState(spaces: [space], agents: [run, drawer], designs: [design])
        state.automations = [automation]
        let remoteRun = agent("Remote run", at: 3)
        var remoteState = ShepherdState(spaces: [space], agents: [remoteRun])
        remoteState.automations = [Automation(name: "Remote run", prompt: "p", cwd: "/tmp", agentID: remoteRun.id)]
        let lists = SidebarDerivation.lists(
            SidebarSource(local: state, hosts: [SidebarSource.Host(id: host, name: "horizon", state: remoteState)],
                          designs: true),
            pins: SidebarPins([local(run), remote(remoteRun), .local(drawer.id)]))
        #expect(lists.pinned.isEmpty)
        #expect(lists.all.count == 3)
        #expect(lists.done.map(\.title) == ["Nightly"])
        #expect(lists.designs.map(\.title) == ["Dashboard"])
        #expect(lists.all.allSatisfy { !$0.pinnable && !$0.pinned })
    }

    @Test func everyOtherThreadRowIsPinnableAndOnlyAPinnedOneIsPinned() {
        let a = agent("a", at: 2), b = agent("b", at: 1)
        let remote = agent("remote", at: 0)
        let lists = derive([a, b], remote: [remote], pins: [local(a)])
        #expect(lists.pinned.first?.pinned == true && lists.pinned.first?.pinnable == true)
        let rows = Dictionary(uniqueKeysWithValues: lists.recents.map { ($0.title, $0) })
        #expect(rows["b"]?.pinnable == true && rows["b"]?.pinned == false)
        #expect(rows["remote"]?.pinnable == true && rows["remote"]?.pinned == false)
        #expect(rows["b"]?.accessibilityLabel == "b, idle")
        #expect(lists.pinned.first?.accessibilityLabel == "a, idle, pinned")
    }

    // MARK: Digits and the walk

    /// ⌘1–9 follow the order on screen: Needs you takes none, so Pinned's rows take the first
    /// digits, then Recents'.
    @Test func pinnedRowsTakeTheFirstDigitsAndRecentsFollow() {
        let recents = (0..<8).map { agent("r\($0)", at: Double(100 - $0)) }
        let first = agent("first", at: 1), second = agent("second", at: 2)
        var asking = agent("asks", status: .blocked, at: 200, waiting: "Ship it?")
        asking.waitingReason = "ship it?"
        let lists = derive(recents + [first, second, asking], pins: [local(first), local(second)])
        #expect(lists.shortcutRows.prefix(4).map(\.title) == ["first", "second", "r0", "r1"])
        let presented = lists.presented(selected: nil, shortcuts: true)
        #expect(presented.pinned.map(\.accessory) == [.shortcut("⌘1"), .shortcut("⌘2")])
        #expect(presented.recents.prefix(7).map(\.accessory) == (3...9).map { .shortcut("⌘\($0)") })
        #expect(presented.recents.dropFirst(7).allSatisfy { $0.accessory == NWSidebarRow.Accessory.none })
        #expect(presented.needsYou.first?.accessory == .reason("ship it?"))
    }

    @Test func tenPinnedThreadsTakeAllNineDigitsAndRecentsNone() {
        let pinned = (0..<10).map { agent("p\($0)", at: Double($0)) }
        let other = agent("other", at: 100)
        let lists = derive(pinned + [other], pins: pinned.map(local))
        #expect(lists.shortcutRows.count == 11)
        let presented = lists.presented(selected: nil, shortcuts: true)
        #expect(presented.pinned.prefix(9).map(\.accessory) == (1...9).map { .shortcut("⌘\($0)") })
        #expect(presented.pinned.last?.accessory == NWSidebarRow.Accessory.none)
        #expect(presented.recents.allSatisfy { $0.accessory == NWSidebarRow.Accessory.none })
    }

    @Test func aDesignStillTakesNoDigitBesidePinnedThreads() {
        let pinned = agent("pinned", at: 1)
        let drawer = agent("Dashboard", at: 2)
        let design = Design(name: "Dashboard", agentID: drawer.id, createdAt: 1_000, lastActiveAt: 55, boardCount: 4)
        var drawerWithDesign = drawer
        drawerWithDesign.designID = design.id
        let lists = SidebarDerivation.lists(
            SidebarSource(local: ShepherdState(spaces: [space], agents: [pinned, drawerWithDesign], designs: [design]), designs: true),
            pins: SidebarPins([local(pinned)]))
        #expect(lists.shortcutRows.map(\.title) == ["pinned"])
    }

    @Test func theWalkRunsNeedsYouThenPinnedThenRecents() {
        let asking = agent("asks", status: .blocked, at: 9, waiting: "?")
        let pinned = agent("pinned", at: 1)
        let recent = agent("recent", at: 5)
        #expect(derive([recent, pinned, asking], pins: [local(pinned)]).all.map(\.title) == ["asks", "pinned", "recent"])
    }

    @Test func theSelectedRowIsMarkedWherePinnedShowsIt() {
        let pinned = agent("pinned", at: 1), other = agent("other", at: 2)
        let presented = derive([pinned, other], pins: [local(pinned)]).presented(selected: .local(pinned.id), shortcuts: false)
        #expect(presented.pinned.map(\.selected) == [true])
        #expect(presented.recents.map(\.selected) == [false])
    }

    // MARK: A launch, the New thread page and the palette

    /// A launch shows what needs you, else the most recently active thread, pinned or not, as
    /// before; the sidebar's own order puts pinned threads first.
    @Test func aLaunchShowsTheMostRecentlyActiveThreadWhateverIsPinned() {
        let old = agent("old", at: 1), new = agent("new", at: 9)
        let lists = derive([old, new], pins: [local(old)])
        #expect(lists.activity.map(\.title) == ["new", "old"])
        #expect(lists.all.map(\.title) == ["old", "new"])
        var asking = agent("asks", status: .blocked, at: 0, waiting: "?")
        asking.waitingReason = "?"
        #expect(derive([old, new, asking], pins: [local(old)]).activity.map(\.title) == ["asks", "new", "old"])
    }

    @Test func withoutPinsTheActivityOrderIsTheSidebarOrder() {
        let asking = agent("asks", status: .blocked, at: 0, waiting: "?")
        let lists = derive([agent("a", at: 1), asking, agent("b", at: 2)], pins: [])
        #expect(lists.activity.map(\.id) == lists.all.map(\.id))
    }
}

/// Where Pin is offered and what it says.
@Suite("Pin words and palette")
@MainActor
struct PinPaletteTests {
    @Test(arguments: [(false, "Pin", "pin", "Pin thread"), (true, "Unpin", "pin.slash", "Unpin thread")])
    func theMenuItemAndThePaletteCommandAreNamedForWhatTheyDoNow(pinned: Bool, menu: String, symbol: String, palette: String) {
        #expect(PinWords.menuTitle(pinned: pinned) == menu)
        #expect(PinWords.symbol(pinned: pinned) == symbol)
        #expect(PinWords.paletteTitle(pinned: pinned) == palette)
    }

    /// One command in This thread, named for the thread's state, with no chord.
    @Test(arguments: [(false, "Pin thread", "pin"), (true, "Unpin thread", "pin.slash")])
    func thePaletteOffersOneCommandForAThreadOnScreen(pinned: Bool, title: String, icon: String) throws {
        let items = ShepherdViewModel.pinPaletteItems(target: .local(AgentID(rawValue: "a")), pinned: pinned)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == title && item.icon == icon)
        #expect(item.section == .thisThread && item.kind == .action("togglePin"))
        #expect(item.shortcut == nil, "no new chord")
    }

    @Test func thePaletteOffersNothingWithoutAThreadToPin() {
        #expect(ShepherdViewModel.pinPaletteItems(target: nil, pinned: false).isEmpty)
        #expect(ShepherdViewModel.pinPaletteItems(target: nil, pinned: true).isEmpty)
    }

    @Test(arguments: ["pin", "unpin", "pin thr"])
    func aQueryFindsTheCommand(query: String) {
        let items = ShepherdViewModel.pinPaletteItems(target: .local(AgentID(rawValue: "a")), pinned: query.hasPrefix("un"))
        #expect(PaletteSearch.filter(items, query: query, scope: .all).count == 1)
    }

    /// The thread options menu redraws when the thread is pinned or unpinned, and when Pin stops
    /// being offered.
    @Test func theToolbarReadsThePinState() {
        let store = NativeThreadStore()
        func header(pinned: Bool?, toggle: Bool) -> ThreadHeader {
            ThreadHeader(store: store, project: "p", title: "t", pinned: pinned, togglePin: toggle ? {} : nil)
        }
        #expect(header(pinned: false, toggle: true) == header(pinned: false, toggle: true))
        #expect(header(pinned: false, toggle: true) != header(pinned: true, toggle: true))
        #expect(header(pinned: false, toggle: true) != header(pinned: nil, toggle: false))
    }
}
