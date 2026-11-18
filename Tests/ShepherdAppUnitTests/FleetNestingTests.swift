import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A thread another thread started on another Mac, in the sidebar (FleetSubthreads): it nests under the thread that sent it with its Mac and stage on a second line,
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

    func source(local: [Agent], hosts: [SidebarSource.Host] = [], records: [FleetDispatchRecord] = [], macs: [UUID: String] = [:],
                dismissed: Set<UUID> = []) -> SidebarSource {
        SidebarSource(local: ShepherdState(spaces: [space], agents: local), localFleetID: Self.thisMac, hosts: hosts,
                      fleet: SidebarFleet(records: records, macs: macs, dismissed: dismissed))
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

    @Test func aThreadAThreadStartedSitsUnderItAsAnyThreadWithItsMacTag() {
        let (sender, children, records) = self.sender(sending: [.running])
        let other = agent("Migrate orders", .working, in: space, at: 30)
        let built = lists(source(local: [sender, other], hosts: [host(children)], records: records))
        #expect(built.working.map(\.title) == ["Migrate orders", "Speed up checkout CI", "Task 1"])
        let nested = built.working[2]
        #expect(nested.fleetNested && nested.leading == .dot(.running), "the dot a running thread has")
        #expect(nested.accessory == .tag("mini"), "the Mac that has it")
        // Its second line is the thread's own, whatever its dispatch record says.
        let alone = lists(source(local: [], hosts: [host(children)])).working.first
        #expect(nested.subtitle == alone?.subtitle && nested.accessibilityLabel == alone?.accessibilityLabel)
        #expect(line(built.working[1]) == line(lists(source(local: [sender])).working.first), "its starter says nothing of what it started")
        #expect(built.working[1].fold == nil, "one or two don't fold")
    }

    @Test func noRowSpeaksOfSendingOrDispatching() {
        let (sender, children, records) = self.sender(sending: [.running, .running, .delivering, .done])
        let waiting = [record(.placing, parent: sender.id, title: "Rebuild search index", target: nil, host: nil, at: 11),
                       record(.heldLimit, parent: sender.id, title: "Audit feature flags", target: nil, host: nil, at: 14),
                       record(.preparing, parent: nil, title: "Backfill totals", kind: .userThread, at: 15)]
        let built = lists(source(local: [sender], hosts: [host(children)], records: records + waiting), open: [SidebarSent.foldKey(.local(sender.id))])
        let words = built.all.flatMap { [$0.subtitle?.text, $0.accessibilityLabel, $0.help] }.compactMap { $0?.lowercased() }
        #expect(!words.contains { text in ["sent", "dispatch", "placing", "delivering", "held ·", "sends live"].contains { text.contains($0) } })
    }

    @Test func aThreadThatCameFromAnotherMacIsAsAnyThreadHere() {
        // The sender is the mini's: this Mac has no record, and the thread is as any thread here: no tag.
        let sender = agent("Speed up checkout CI", .working, in: remoteSpace)
        let child = agent("Fix flaky payment test", .working, in: space, at: 50, from: (Self.miniFleet, "Mac mini", sender.id))
        let built = lists(source(local: [child], hosts: [host([sender])]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Fix flaky payment test"])
        let alone = lists(source(local: [child])).working.first
        #expect(built.working[1].fleetNested && built.working[1].subtitle == alone?.subtitle && built.working[1].accessory == alone?.accessory)
    }

    // MARK: Starting

    @Test func workThatHasNoThreadYetIsANormalRowInAStartingState() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let records = [
            record(.placing, parent: sender.id, title: "Rebuild search index", target: nil, host: nil, at: 11),
            record(.waitingRoom, parent: sender.id, title: "Lint the monorepo", target: nil, host: nil, at: 12),
            record(.waitingWake, parent: sender.id, title: "Split slow UI tests", target: Self.studioFleet, host: "Mac Studio", at: 13),
            record(.heldLimit, parent: sender.id, title: "Audit feature flags", target: nil, host: nil, at: 14),
            record(.preparing, parent: sender.id, title: "Port the web client", at: 15, clone: "payments-web"),
            record(.preparing, parent: sender.id, title: "Backfill order totals", target: Self.thisMac, host: "MacBook Pro", at: 16),
        ]
        let built = lists(source(local: [sender], records: records), open: [SidebarSent.foldKey(.local(sender.id))])
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Rebuild search index", "Lint the monorepo", "Split slow UI tests", "Audit feature flags",
                                              "Port the web client", "Backfill order totals"])
        #expect(built.working.dropFirst().map { line($0) } == ["starting", "waiting for a Mac with room", "waiting for studio to wake",
                                                               "waiting for another thread to finish", "cloning payments-web on mini", "starting"])
        #expect(built.working.dropFirst().map(\.accessory) == [.none, .none, .tag("studio"), .none, .tag("mini"), .none], "the Mac as a tag, none for This Mac")
        #expect(built.working.dropFirst().map(\.leading) == [.dot(.idle), .dot(.idle), .dot(.idle), .dot(.idle), .dot(.running), .dot(.running)])
        #expect(built.working.dropFirst().allSatisfy { $0.fleetNested }, "a thread another thread started nests under it")
        #expect(built.working.dropFirst().map(\.id) == records.map { .dispatch($0.id) })
        #expect(line(built.working[0]) == line(lists(source(local: [sender])).working.first), "its starter keeps its own line")
    }

    @Test func aStartingRowBecomesTheRealThreadWhenItStarts() {
        let (sender, children, records) = self.sender(sending: [.preparing])
        // Before: the record only. After: the thread, drawn as itself and never twice.
        let before = lists(source(local: [sender], records: records))
        #expect(before.working.map(\.id) == [.local(sender.id), .dispatch(records[0].id)])
        let after = lists(source(local: [sender], hosts: [host(children)], records: records))
        #expect(after.all.filter { $0.id.dispatchID != nil }.isEmpty)
        #expect(after.working.map(\.title) == ["Speed up checkout CI", "Task 1"] && after.working[1].accessory == .tag("mini"))
    }

    @Test func aUserThreadWaitingForRoomIsANormalStartingRow() {
        let waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread, at: 12)
        let built = lists(source(local: [], records: [waiting]))
        let row = built.working.first
        #expect(row?.title == "Rebuild search index" && row?.id == .dispatch(waiting.id) && row?.fleetNested == false)
        #expect(row?.subtitle == .init("waiting for a Mac with room") && row?.leading == .dot(.idle))
        #expect(built.activity.isEmpty, "a thread that doesn't exist is no thread to continue")
    }

    // MARK: Failed

    @Test func aFailedThreadIsFinishedWithItsReasonInRedForADay() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        var failed = record(.failed, parent: sender.id, title: "Profile cold launch", target: Self.studioFleet, host: "Mac Studio", at: 15)
        failed.failure = FleetDispatchCode.snapshotFailed
        failed.failureDetail = "xcodebuild exited 65"
        failed.updatedAt = Date().timeIntervalSince1970 * 1000
        var stale = record(.failed, parent: sender.id, title: "Old failure", at: 16)
        stale.updatedAt = 1
        let built = lists(source(local: [sender], records: [failed, stale]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI"], "a failure is no work in progress, nor nested under its starter")
        #expect(built.done.map(\.title) == ["Profile cold launch"])
        #expect(built.done[0].subtitle == .init("xcodebuild exited 65", tone: .failed) && built.done[0].accessory == .tag("studio"))
        #expect(built.done[0].leading == .dot(.failed))
    }

    /// What the person saw: a thread started from New thread on a Mac that failed before it had a thread. The Mac is named by id on the record.
    func failedUserThread(asking mac: UUID?, detail: String? = "bearcli") -> FleetDispatchRecord {
        var failed = record(.failed, parent: nil, title: "test", target: nil, host: nil, kind: .userThread, at: 15)
        failed.requestedHost = mac?.uuidString
        failed.failure = FleetDispatchCode.hostNotReady
        failed.failureDetail = detail
        failed.updatedAt = Date().timeIntervalSince1970 * 1000
        return failed
    }

    @Test func aFailedThreadWithNoThreadIsDoneNotWorkingAndNamesItsMac() {
        let failed = failedUserThread(asking: Self.studioFleet)
        let macs = [Self.thisMac: "MacBook Pro", Self.studioFleet: "Mac Studio"]
        let built = lists(source(local: [agent("Other", .working, in: space)], records: [failed], macs: macs))
        #expect(built.working.map(\.title) == ["Other"], "it is not work in progress")
        let row = built.done.first
        #expect(built.done.count == 1 && row?.id == .dispatch(failed.id) && row?.title == "test")
        #expect(row?.leading == .dot(.failed) && row?.accessory == .tag("studio"))
        #expect(row?.subtitle == .init("bearcli isn't installed", tone: .failed))
        // The Mac has left the fleet: never its id.
        let gone = lists(source(local: [], records: [failed], macs: [Self.thisMac: "MacBook Pro"])).done.first
        #expect(gone?.subtitle == .init("a Mac that left · bearcli isn't installed", tone: .failed))
        #expect(gone?.accessibilityLabel.contains(Self.studioFleet.uuidString) == false && gone?.help.contains(Self.studioFleet.uuidString) == false)
        // And this one, asked for This Mac: no tag.
        let here = lists(source(local: [], records: [failedUserThread(asking: Self.thisMac)], macs: macs)).done.first
        #expect(here?.subtitle?.text == "bearcli isn't installed" && here?.accessory == SHSidebarRow.Accessory.none)
    }

    @Test func aFailedThreadStaysInDoneUntilItIsDeleted() {
        let failed = failedUserThread(asking: Self.studioFleet)
        let live = record(.preparing, parent: nil, title: "Rebuild search index", kind: .userThread, at: 16)
        let macs = [Self.studioFleet: "Mac Studio"]
        let shown = lists(source(local: [], records: [failed, live], macs: macs))
        #expect(shown.done.map(\.id) == [.dispatch(failed.id)])
        #expect(shown.working.map(\.id) == [.dispatch(live.id)])
        let deleted = lists(source(local: [], records: [failed, live], macs: macs, dismissed: [failed.id]))
        #expect(deleted.done.isEmpty && deleted.all.map(\.id) == [.dispatch(live.id)])
    }

    @Test func aFailedThreadAfterADayStaysGone() {
        var stale = failedUserThread(asking: Self.studioFleet)
        stale.updatedAt = 1
        #expect(lists(source(local: [], records: [stale])).all.isEmpty)
    }

    // MARK: Finished, asking, and a sender that isn't here

    @Test func aFinishedThreadLeavesTheTreeAsAnyFinishedThreadDoes() {
        let (sender, children, records) = self.sender(sending: [.running, .done])
        let built = lists(source(local: [sender], hosts: [host(children)], records: records))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Task 1"])
        let finished = built.done.first
        let alone = lists(source(local: [], hosts: [host(children)])).done.first
        #expect(finished?.title == "Task 2" && finished?.fleetNested == false && finished?.accessory == .tag("mini"))
        #expect(finished?.subtitle == alone?.subtitle, "a normal finished row: no \"sent by\", no \"back\"")
    }

    @Test func aThreadThatAsksYouIsInNeedsYouAndUnderItsStarter() {
        let (sender, children, records) = self.sender(sending: [.running])
        var asking = children
        asking[0].status = .blocked
        asking[0].waitingOn = "Which shard count?"
        let built = lists(source(local: [sender], hosts: [host(asking)], records: records))
        let alone = lists(source(local: [], hosts: [host(asking)])).needsYou.first
        let inTree = built.working.last
        #expect(inTree?.title == "Task 1" && inTree?.fleetNested == true && inTree?.subtitle == alone?.subtitle && inTree?.leading == alone?.leading)
        let inNeedsYou = built.needsYou.first
        #expect(inNeedsYou?.title == "Task 1" && inNeedsYou?.subtitle == alone?.subtitle && inNeedsYou?.fleetNested == false)
        // The two rows are one thread, so the list needs a different identity for each.
        let items = built.items(collapsed: [])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func aThreadWhoseStarterIsntHereIsAFlatNormalRow() {
        let gone = agent("Fix flaky payment test", .working, in: remoteSpace, at: 5, from: (Self.thisMac, "MacBook Pro", AgentID()))
        let elsewhere = agent("Profile cold launch", .working, in: remoteSpace, at: 6, from: (Self.studioFleet, "Mac Studio", AgentID()), title: "Release prep")
        let byYou = agent("Regenerate API client", .working, in: remoteSpace, at: 7, from: (Self.thisMac, "MacBook Pro", nil))
        let built = lists(source(local: [agent("Speed up checkout CI", .working, in: space)], hosts: [host([gone, elsewhere, byYou])]))
        let plain = lists(source(local: [], hosts: [host([agent("Fix flaky payment test", .working, in: remoteSpace, at: 5)])])).working.first
        #expect(built.working.count == 4 && built.working.allSatisfy { !$0.fleetNested })
        for title in ["Fix flaky payment test", "Profile cold launch", "Regenerate API client"] {
            let row = built.working.first { $0.title == title }
            #expect(row?.subtitle == plain?.subtitle && row?.accessory == .tag("mini"), "\(title): as any thread on the mini")
        }
    }

    // MARK: A starter's rows

    @Test func moreThanTwoFoldUnderTheirStarter() {
        let (sender, children, records) = self.sender(sending: [.running, .running, .delivering, .done])
        let source = source(local: [sender], hosts: [host(children)], records: records)
        let closed = lists(source)
        #expect(closed.working.map(\.title) == ["Speed up checkout CI"], "folded: only the starter, with its chevron")
        #expect(closed.working[0].fold == SidebarFold(key: SidebarSent.foldKey(.local(sender.id)), open: false))
        let open = lists(source, open: [SidebarSent.foldKey(.local(sender.id))])
        #expect(open.working.map(\.title) == ["Speed up checkout CI", "Task 1", "Task 2", "Task 3"])
        #expect(open.working[0].fold?.open == true)
        #expect(open.working.dropFirst().allSatisfy { $0.fleetNested })
        #expect(open.done.map(\.title) == ["Task 4"], "the one that is finished is in Done either way")
    }

    @Test func aThreadAThreadStartedNestsFlatUnderTheTopOne() {
        let top = agent("Speed up checkout CI", .working, in: space)
        let middle = agent("Split slow UI tests", .working, in: remoteSpace, at: 20, from: (Self.thisMac, "MacBook Pro", top.id), dispatch: UUID())
        let bottom = agent("Shard UI tests", .working, in: space, at: 30, from: (Self.miniFleet, "Mac mini", middle.id), title: "Split slow UI tests", dispatch: UUID())
        let built = lists(source(local: [top, bottom], hosts: [host([middle])]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Split slow UI tests", "Shard UI tests"])
        #expect(built.working.map(\.fleetNested) == [false, true, true], "one level, never a second indent")
        #expect(line(built.working[2]) == line(lists(source(local: [bottom])).working.first), "nothing of who started it: it is a thread")
    }

    @Test func aPinnedThreadOnAnotherMacStaysWherePinned() {
        let (sender, children, records) = self.sender(sending: [.running])
        var pins = SidebarPins()
        pins.pin(.remote(RemoteAgentRef(hostID: Self.miniLink, agentID: children[0].id)))
        let built = SidebarDerivation.lists(source(local: [sender], hosts: [host(children)], records: records), pins: pins)
        #expect(built.pinned.map(\.title) == ["Task 1"] && built.pinned.first?.fleetNested == false)
        #expect(built.working.map(\.title) == ["Speed up checkout CI"])
    }

    // MARK: Spaces style

    @Test func theSpacesTreeNestsNothing() {
        let (sender, children, records) = self.sender(sending: [.running])
        var source = source(local: [sender], hosts: [host(children)], records: records)
        source.hosts[0].state.spaces = [space]
        source.hosts[0].state.agents[0].spaceID = space.id
        let tree = SidebarDerivation.tree(source, options: SidebarTreeOptions())
        let rows = tree.projects.first?.rows ?? []
        #expect(Set(rows.map(\.title)) == ["Speed up checkout CI", "Task 1"])
        #expect(!rows.contains { $0.fleetNested })
    }

    @Test func theSpacesTreeHoldsWorkWithNoThreadYetInTheSendersSpace() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let records = (0..<3).map { record(.waitingRoom, parent: sender.id, title: "Task \($0 + 1)", target: nil, host: nil, at: Double($0)) }
        let tree = SidebarDerivation.tree(source(local: [sender], records: records), options: SidebarTreeOptions())
        #expect(Set(tree.visibleRows(collapsed: []).map(\.title)) == ["Speed up checkout CI", "Task 1", "Task 2", "Task 3"])
        #expect(!tree.visibleRows(collapsed: []).contains { $0.fleetNested })
    }

    // MARK: Threads a thread on the same Mac started (agent_spawn)

    func started(_ name: String, by sender: Agent, depth: Int = 1, status: AgentStatus = .working, at: Double = 20) -> Agent {
        var child = agent(name, status, in: space, at: at)
        child.startedBy = StartedBy(agentID: sender.id, agentTitle: sender.name, at: at, depth: depth)
        return child
    }

    @Test func aThreadAThreadStartedHereNestsUnderItInActivityAndLeavesWhenDone() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let child = started("Split slow UI tests", by: sender)
        let grandchild = started("Shard UI tests", by: child, depth: 2, at: 21)
        let finished = started("Bump Swift tools", by: sender, status: .done, at: 22)
        let built = lists(source(local: [sender, child, grandchild, finished]))
        // A chain sits flat under its top, in the order it was started.
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Split slow UI tests", "Shard UI tests"])
        #expect(built.working.map(\.fleetNested) == [false, true, true])
        #expect(built.done.map(\.title) == ["Bump Swift tools"])
    }

    @Test func aThreadAThreadStartedOnAnotherHostNestsUnderItThere() {
        let sender = agent("Speed up checkout CI", .working, in: remoteSpace)
        let child = started("Split slow UI tests", by: sender)
        let built = lists(source(local: [], hosts: [host([sender, child])]))
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Split slow UI tests"])
        #expect(built.working.last?.sentRoot == .remote(RemoteAgentRef(hostID: Self.miniLink, agentID: sender.id)))
    }

    @Test func aThreadWhoseStarterIsGoneIsAThreadOfItsOwn() {
        let sender = agent("Speed up checkout CI", .working, in: space)
        let built = lists(source(local: [started("Split slow UI tests", by: sender)]))
        #expect(built.working.map(\.title) == ["Split slow UI tests"] && built.working.first?.fleetNested == false)
    }

    @Test func aUserThreadWaitingIsInItsSpaceWhenItWasStartedThere() {
        var waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread)
        waiting.spaceID = space.id
        let tree = SidebarDerivation.tree(source(local: [], records: [waiting]), options: SidebarTreeOptions())
        #expect(tree.projects.first?.rows.map(\.title) == ["Rebuild search index"])
        #expect(tree.projects.first?.rows.first?.subtitle == .init("waiting for a Mac with room"))
    }

    // MARK: Rows

    @Test func aStartingRowIsNoShortcutAndNoPinTarget() {
        let waiting = record(.waitingRoom, parent: nil, title: "Rebuild search index", target: nil, host: nil, kind: .userThread)
        let built = SidebarDerivation.lists(source(local: [agent("Other", .working, in: space)], records: [waiting]))
            .presented(selected: nil, shortcuts: true)
        #expect(built.working.first { $0.id.dispatchID != nil }?.accessory == SHSidebarRow.Accessory.none, "no ⌘-digit")
        #expect(built.working.first { $0.id.dispatchID != nil }?.pinnable == false)
        #expect(PinnedThread(.dispatch(waiting.id)) == nil)
    }
}
