import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A thread sent to another Mac in the sidebar (FleetSubthreads): it nests under the thread that sent it with its Mac and stage on a second line,
/// work with no thread yet has a row of its own, a sender says what it sent and folds more than two, a thread that is back leaves the tree, one
/// that asks you stays in Needs you too, and one whose sender isn't here is a flat "sent by" row. Both sidebar styles.
@Suite("Fleet sidebar sent threads")
@MainActor
struct FleetNestingTests {
    static let thisMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let miniFleet = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let miniLink = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let studioFleet = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    let space = Fixture.space("acme-web")
    let remoteSpace = Fixture.space("acme-web", path: "/srv/acme-web")

    func agent(_ name: String, _ status: AgentStatus, in space: Space, at: Double = 10, from: (host: UUID, name: String, agent: AgentID?)? = nil,
               title: String = "Speed up checkout CI", dispatch: UUID = UUID()) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.dispatchedFrom = from.map {
            DispatchedFrom(hostID: $0.host, hostName: $0.name, agentID: $0.agent, agentTitle: title, dispatchID: dispatch, at: at)
        }
        return agent
    }

    func record(_ state: FleetDispatchState, id: UUID = UUID(), parent: AgentID?, title: String = "Fix flaky payment test", target: UUID? = FleetNestingTests.miniFleet,
                host: String? = "Mac mini", kind: FleetDispatchRecord.Kind = .agentDispatch, at: Double = 10, clone: String? = nil,
                parentTitle: String = "Speed up checkout CI") -> FleetDispatchRecord {
        var record = FleetDispatchRecord(id: id, kind: kind, parentAgentID: parent, parentHostID: Self.thisMac, parentHostName: "MacBook Pro", parentTitle: parentTitle,
                                         targetHostID: target, targetHostName: host, state: state, title: title, task: "", repoKey: "github.com/acme/web",
                                         clone: clone.map { FleetCloneProgress(name: $0, source: "github.com/acme/web") }, createdAt: at)
        record.updatedAt = at
        return record
    }

    func host(_ agents: [Agent], fleetID: UUID? = FleetNestingTests.miniFleet, offline: Bool = false) -> SidebarSource.Host {
        SidebarSource.Host(id: Self.miniLink, name: "Mac mini", state: ShepherdState(spaces: [remoteSpace], agents: agents), offline: offline, fleetID: fleetID)
    }

    func source(local: [Agent], hosts: [SidebarSource.Host] = [], records: [FleetDispatchRecord] = [], next: String? = "Mac mini", cap: Int = 4) -> SidebarSource {
        SidebarSource(local: ShepherdState(spaces: [space], agents: local), localFleetID: Self.thisMac, hosts: hosts,
                      fleet: SidebarFleet(records: records, next: next, cap: cap))
    }

    func lists(_ source: SidebarSource, open: Set<String> = []) -> SidebarLists {
        SidebarDerivation.lists(source).presented(selected: nil, shortcuts: false, openFolds: open)
    }

    func line(_ row: SidebarListRow?) -> String? { row?.subtitle?.text }

    /// A sender on This Mac, and the threads it sent to the mini, each with the record its dispatch has.
    func sender(sending states: [FleetDispatchState], status: AgentStatus = .working) -> (sender: Agent, children: [Agent], records: [FleetDispatchRecord]) {
        let sender = agent("Speed up checkout CI", status, in: space)
        var children: [Agent] = [], records: [FleetDispatchRecord] = []
        for (index, state) in states.enumerated() {
            let dispatch = UUID()
            let title = "Task \(index + 1)"
            children.append(agent(title, state == .done ? .done : .working, in: remoteSpace, at: 20 + Double(index),
                                  from: (Self.thisMac, "MacBook Pro", sender.id), dispatch: dispatch))
            records.append(record(state, id: dispatch, parent: sender.id, title: title, at: 20 + Double(index)))
        }
        return (sender, children, records)
    }

    // MARK: Nesting

    @Test func aSentThreadSitsUnderItsSenderWithItsMacAndStage() {
        let (sender, children, records) = self.sender(sending: [.running])
        let other = agent("Migrate orders", .working, in: space, at: 30)
        let built = lists(source(local: [sender, other], hosts: [host(children)], records: records))
        #expect(built.working.map(\.title) == ["Migrate orders", "Speed up checkout CI", "Task 1"])
        let nested = built.working[2]
        #expect(nested.fleetNested && nested.accessory == .none && nested.leading == .dot(.running))
        #expect(nested.subtitle?.text == "mini · running" && nested.subtitle?.tone == .running && nested.subtitle?.since != nil)
        #expect(line(built.working[1]) == "1 sent", "the sender says what it sent")
        #expect(built.working[1].fold == nil, "a sender of one or two doesn't fold")
        #expect(built.working[1].accessibilityLabel.hasSuffix(", 1 sent") && nested.accessibilityLabel == "Task 1, sent thread, mini · running")
    }

    @Test func aThreadThatCameFromAnotherMacReadsItsOwnState() {
        // The sender is the mini's: this Mac has no record, so the thread's status says where it is.
        let sender = agent("Speed up checkout CI", .working, in: remoteSpace)
        let child = agent("Fix flaky payment test", .working, in: space, at: 50, from: (Self.miniFleet, "Mac mini", sender.id))
        let built = lists(source(local: [child], hosts: [host([sender])]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Fix flaky payment test"])
        #expect(line(built.working[1]) == "This Mac · running" && built.working[1].fleetNested)
    }

    @Test func aStageIsAsTheRecordSaysItWhateverTheThreadReads() {
        let (sender, children, records) = self.sender(sending: [.preparing, .delivering])
        var withClone = records
        withClone[0] = record(.preparing, id: records[0].id, parent: sender.id, title: "Task 1", at: 20, clone: "payments-web")
        let built = lists(source(local: [sender], hosts: [host(children)], records: withClone))
        #expect(built.working.dropFirst().map { line($0) } == ["mini · cloning payments-web", "mini · delivering"])
        #expect(built.working.dropFirst().map(\.leading) == [.dot(.running), .dot(.done)])
    }

    @Test func workWithNoThreadYetHasARowOfItsOwnUnderItsSender() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let records = [
            record(.placing, parent: sender.id, title: "Rebuild search index", target: nil, host: nil, at: 11),
            record(.waitingRoom, parent: sender.id, title: "Lint the monorepo", target: nil, host: nil, at: 12),
            record(.waitingWake, parent: sender.id, title: "Split slow UI tests", target: Self.studioFleet, host: "Mac Studio", at: 13),
            record(.heldLimit, parent: sender.id, title: "Audit feature flags", target: nil, host: nil, at: 14),
        ]
        let built = lists(source(local: [sender], records: records), open: [SidebarSent.foldKey(.local(sender.id))])
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Rebuild search index", "Lint the monorepo", "Split slow UI tests", "Audit feature flags"])
        #expect(built.working.dropFirst().map { line($0) } == ["placing · choosing a Mac", "no Mac has room · next: mini", "studio · goes when it wakes",
                                                               "held · 3 of 4 sends live"])
        #expect(built.working.dropFirst().allSatisfy { $0.leading == .dot(.idle) && $0.fleetNested })
        #expect(built.working.dropFirst().map(\.id) == records.map { .dispatch($0.id) })
        #expect(line(built.working[0]) == "4 sent")
    }

    @Test func aDispatchWithAThreadIsNeverAlsoARowOfItsOwn() {
        let (sender, children, records) = self.sender(sending: [.running])
        let built = lists(source(local: [sender], hosts: [host(children)], records: records))
        #expect(built.all.filter { $0.id.dispatchID != nil }.isEmpty)
    }

    @Test func aFailedDispatchShowsItsReasonInRedForADay() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        var failed = record(.failed, parent: sender.id, title: "Profile cold launch", target: Self.studioFleet, host: "Mac Studio", at: 15)
        failed.failureDetail = "xcodebuild exited 65"
        failed.updatedAt = Date().timeIntervalSince1970 * 1000
        var stale = record(.failed, parent: sender.id, title: "Old failure", at: 16)
        stale.updatedAt = 1
        let built = lists(source(local: [sender], records: [failed, stale]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Profile cold launch"])
        #expect(built.working[1].subtitle == .init("studio · xcodebuild exited 65", tone: .failed))
        #expect(built.working[1].leading == .dot(.failed))
    }

    // MARK: Back, asking, and a sender that isn't here

    @Test func aThreadThatIsBackLeavesTheTreeAndSaysWhoSentIt() {
        let (sender, children, records) = self.sender(sending: [.running, .done])
        let built = lists(source(local: [sender], hosts: [host(children)], records: records))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Task 1"])
        #expect(line(built.working[0]) == "2 sent · 1 back")
        let back = built.done.first
        #expect(back?.title == "Task 2" && back?.fleetNested == false && back?.accessory == .tag("mini"))
        #expect(back?.subtitle == .init("sent by Speed up checkout CI"))
    }

    @Test func aSentThreadThatAsksYouIsInNeedsYouToo() {
        let (sender, children, records) = self.sender(sending: [.running])
        var asking = children
        asking[0].status = .blocked
        asking[0].waitingOn = "Which shard count?"
        let built = lists(source(local: [sender], hosts: [host(asking)], records: records))
        let inTree = built.working.last
        #expect(inTree?.title == "Task 1" && inTree?.subtitle == .init("mini · asking you", tone: .attention) && inTree?.leading == .dot(.attention))
        let inNeedsYou = built.needsYou.first
        #expect(inNeedsYou?.title == "Task 1" && inNeedsYou?.subtitle == .init("from Speed up checkout CI", tone: .attention) && inNeedsYou?.fleetNested == false)
        #expect(line(built.working[0]) == "1 sent · asking you")
        // The two rows are one thread, so the list needs a different identity for each.
        let items = built.items(collapsed: [])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func aSenderThatIsntHereLeavesAFlatRowThatSaysWhoSentIt() {
        let gone = agent("Fix flaky payment test", .working, in: remoteSpace, at: 5, from: (Self.thisMac, "MacBook Pro", AgentID()))
        let elsewhere = agent("Profile cold launch", .working, in: remoteSpace, at: 6, from: (Self.studioFleet, "Mac Studio", AgentID()), title: "Release prep")
        let byYou = agent("Regenerate API client", .working, in: remoteSpace, at: 7, from: (Self.thisMac, "MacBook Pro", nil))
        let built = lists(source(local: [agent("Speed up checkout CI", .working, in: space)], hosts: [host([gone, elsewhere, byYou])]))
        #expect(built.working.count == 4 && built.working.allSatisfy { !$0.fleetNested })
        #expect(built.working.first { $0.title == "Fix flaky payment test" }?.subtitle == .init("sent by Speed up checkout CI"))
        #expect(built.working.first { $0.title == "Profile cold launch" }?.subtitle == .init("sent by Release prep · studio"))
        #expect(built.working.first { $0.title == "Regenerate API client" }?.subtitle == nil, "a thread you started has no sender to name")
        #expect(built.working.filter { $0.accessory == .tag("mini") }.count == 3, "each keeps its Mac's tag")
    }

    @Test func aUserThreadWaitingForRoomSaysAutoHasNowhereToSendIt() {
        let waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread, at: 12)
        let built = lists(source(local: [], records: [waiting]))
        let row = built.working.first
        #expect(row?.title == "Rebuild search index" && row?.id == .dispatch(waiting.id) && row?.fleetNested == false)
        #expect(row?.subtitle == .init("Auto · no Mac has room") && row?.leading == .dot(.idle))
        #expect(built.activity.isEmpty, "a dispatch with no thread is no thread to continue")
    }

    // MARK: A sender's rows

    @Test func moreThanTwoSentFoldUnderTheirSender() {
        let (sender, children, records) = self.sender(sending: [.running, .running, .delivering, .done])
        let source = source(local: [sender], hosts: [host(children)], records: records)
        let closed = lists(source)
        #expect(closed.working.map(\.title) == ["Speed up checkout CI"], "folded: only the sender, with its chevron")
        #expect(line(closed.working[0]) == "4 sent · 1 back" && closed.working[0].fold == SidebarFold(key: SidebarSent.foldKey(.local(sender.id)), open: false))
        let open = lists(source, open: [SidebarSent.foldKey(.local(sender.id))])
        #expect(open.working.map(\.title) == ["Speed up checkout CI", "Task 1", "Task 2", "Task 3"])
        #expect(open.working[0].fold?.open == true)
        #expect(open.working.dropFirst().allSatisfy { $0.fleetNested })
        #expect(open.done.map(\.title) == ["Task 4"], "the one that is back is in Done either way")
    }

    @Test func aThreadSentByASentThreadNestsFlatUnderTheTopSenderViaItsSender() {
        let top = agent("Speed up checkout CI", .working, in: space)
        let middle = agent("Split slow UI tests", .working, in: remoteSpace, at: 20, from: (Self.thisMac, "MacBook Pro", top.id), dispatch: UUID())
        let bottom = agent("Shard UI tests", .working, in: space, at: 30, from: (Self.miniFleet, "Mac mini", middle.id), title: "Split slow UI tests", dispatch: UUID())
        let built = lists(source(local: [top, bottom], hosts: [host([middle])]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Split slow UI tests", "Shard UI tests"])
        #expect(built.working.map(\.fleetNested) == [false, true, true], "one level, never a second indent")
        #expect(line(built.working[2]) == "via Split slow UI tests · This Mac · running")
        #expect(line(built.working[0]) == "2 sent", "the top sender counts what its senders sent")
    }

    @Test func anElevenSentSenderCountsThemAll() {
        let (sender, children, records) = self.sender(sending: Array(repeating: .running, count: 10) + [.done])
        let built = lists(source(local: [sender], hosts: [host(children)], records: records), open: [SidebarSent.foldKey(.local(sender.id))])
        #expect(line(built.working[0]) == "11 sent · 1 back" && built.working.count == 11)
    }

    @Test func aPinnedThreadSentToAnotherMacStaysWherePinned() {
        let (sender, children, records) = self.sender(sending: [.running])
        var pins = SidebarPins()
        pins.pin(.remote(RemoteAgentRef(hostID: Self.miniLink, agentID: children[0].id)))
        let built = SidebarDerivation.lists(source(local: [sender], hosts: [host(children)], records: records), pins: pins)
        #expect(built.pinned.map(\.title) == ["Task 1"] && built.pinned.first?.fleetNested == false)
        #expect(built.working.map(\.title) == ["Speed up checkout CI"])
    }

    // MARK: Spaces style

    @Test func theSpacesTreeNestsTheSameWay() {
        let (sender, children, records) = self.sender(sending: [.running])
        var source = source(local: [sender], hosts: [host(children)], records: records)
        source.hosts[0].state.spaces = [space]
        source.hosts[0].state.agents[0].spaceID = space.id
        let tree = SidebarDerivation.tree(source, options: SidebarTreeOptions())
        let rows = tree.projects.first?.rows ?? []
        #expect(rows.map(\.title) == ["Speed up checkout CI", "Task 1"])
        #expect(rows.map(\.fleetNested) == [false, true] && rows.map { line($0) } == ["1 sent", "mini · running"])
    }

    @Test func theSpacesTreeFoldsAndHoldsWorkWithNoThreadYet() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let records = (0..<3).map { record(.waitingRoom, parent: sender.id, title: "Task \($0 + 1)", target: nil, host: nil, at: Double($0)) }
        let tree = SidebarDerivation.tree(source(local: [sender], records: records), options: SidebarTreeOptions())
        let key = SidebarSent.foldKey(.local(sender.id))
        #expect(tree.visibleRows(collapsed: []).map(\.title) == ["Speed up checkout CI"])
        #expect(tree.visibleRows(collapsed: [key]).map(\.title) == ["Speed up checkout CI", "Task 1", "Task 2", "Task 3"])
        let items = tree.items(collapsed: [key], selected: nil, shortcuts: false, connected: [])
        let titles = items.compactMap { item -> String? in if case .row(let row) = item { row.title } else { nil } }
        #expect(titles == ["Speed up checkout CI", "Task 1", "Task 2", "Task 3"])
    }

    @Test func aUserThreadWaitingIsInItsSpaceWhenItWasStartedThere() {
        var waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread)
        waiting.spaceID = space.id
        let tree = SidebarDerivation.tree(source(local: [], records: [waiting]), options: SidebarTreeOptions())
        #expect(tree.projects.first?.rows.map(\.title) == ["Rebuild search index"])
        #expect(tree.projects.first?.rows.first?.subtitle == .init("Auto · no Mac has room"))
    }

    // MARK: Rows

    @Test func aDispatchRowIsNoShortcutAndNoPinTarget() {
        let waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread)
        let built = SidebarDerivation.lists(source(local: [agent("Other", .working, in: space)], records: [waiting]))
            .presented(selected: nil, shortcuts: true)
        #expect(built.working.first { $0.id.dispatchID != nil }?.accessory == SHSidebarRow.Accessory.none, "no ⌘-digit")
        #expect(built.working.first { $0.id.dispatchID != nil }?.pinnable == false)
        #expect(PinnedThread(.dispatch(waiting.id)) == nil)
    }
}
