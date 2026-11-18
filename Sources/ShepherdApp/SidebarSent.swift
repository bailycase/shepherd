import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A thread another thread started on any Mac is a thread like any other (FleetSubthreads): the same dot, second line and menu as one that is here, tagged
// with the Mac that has it. The one relationship a row shows is that it nests under the thread that started it while it works. Work that has no
// thread yet is a row in a starting state ("starting on mini") that becomes the real thread when it starts. Plain values derived with the lists,
// never in a view's body.

/// Who started a thread: what the tree needs to nest its row.
struct SidebarSentInfo: Equatable {
    /// The row of the thread that started it, when this Mac can name it.
    var sender: SidebarRowID?
    /// When it was started, in epoch milliseconds: a thread lists the ones it started in this order.
    var at: Double
}

extension AgentState {
    init(_ mark: FleetSentStage.Mark) {
        switch mark {
        case .hollow: self = .idle
        case .running: self = .running
        case .failed: self = .failed
        case .done: self = .done
        }
    }
}

extension SHSidebarRow.Subtitle.Tone {
    init(_ mark: FleetSentStage.Mark?) {
        switch mark {
        case .running?: self = .running
        case .failed?: self = .failed
        case .hollow?, .done?, nil: self = .quiet
        }
    }
}

extension SidebarDerivation {
    /// The tree facts of a thread another Mac or thread started; nil for any other. `host` is the connected host it runs on, nil for This Mac:
    /// a thread `agent_spawn` started sits on the same host as the thread that started it.
    static func sentInfo(of agent: Agent, host: UUID? = nil, _ source: SidebarSource) -> SidebarSentInfo? {
        if let started = agent.startedBy {
            let sender: SidebarRowID = host.map { .remote(RemoteAgentRef(hostID: $0, agentID: started.agentID)) } ?? .local(started.agentID)
            return SidebarSentInfo(sender: sender, at: started.at)
        }
        guard let from = agent.dispatchedFrom else { return nil }
        return SidebarSentInfo(sender: fleetSender(of: agent, source), at: from.at)
    }

    /// The threads this Mac started on other Macs that don't exist yet, and the ones that failed before they did: their own rows, with their facts. A
    /// thread that exists among `threads` is drawn as itself. One that is starting reads as a normal thread's row in Working; one that failed is a finished
    /// thread in Done with its reason in red.
    static func dispatchRows(_ source: SidebarSource, threads: Set<UUID>, now: Date = Date()) -> [(row: SidebarListRow, info: SidebarSentInfo, key: Double, space: SpaceID?)] {
        let pending: Set<FleetDispatchState> = [.placing, .waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing, .failed]
        let dayAgo = (now.timeIntervalSince1970 - 86_400) * 1000
        return source.fleet.records.compactMap { record in
            guard record.kind != .move, pending.contains(record.state), !threads.contains(record.id),
                  record.state != .failed || (record.updatedAt > dayAgo && !source.fleet.dismissed.contains(record.id)) else { return nil }
            let stage = FleetSentStage.of(record, viewer: source.localFleetID, macs: source.fleet.macs)
            let sender = record.parentAgentID.flatMap { id in
                record.parentHostID == source.localFleetID ? SidebarRowID.local(id) : source.hosts.first { $0.fleetID == record.parentHostID }
                    .map { .remote(RemoteAgentRef(hostID: $0.id, agentID: id)) }
            }
            let title = record.title.isEmpty ? "Untitled" : record.title
            let failed = stage.phase == .failed
            let words = [stage.tag, stage.words].compactMap { $0 }.joined(separator: " · ")
            var row = SidebarListRow(id: .dispatch(record.id), title: title, leading: .dot(AgentState(stage.dot)),
                                     accessory: stage.tag.map { .tag($0) } ?? .none, section: failed ? .done : .working,
                                     help: "\(title) · \(words)", accessibilityLabel: "\(title), \(words)",
                                     worktree: false, automation: nil, automationLive: false)
            row.subtitle = .init(stage.words, tone: .init(stage.tone))
            // Finished: Done, and nothing marks it read (only Try again or Delete ends it).
            if failed { row.completion = 1 }
            return (row, SidebarSentInfo(sender: sender, at: record.createdAt), record.updatedAt, record.spaceID)
        }
    }
}

enum SidebarSent {
    /// The key a sender's open state is remembered under (`ShepherdViewModel.collapsedProjects`, with the other chevrons').
    static func foldKey(_ row: SidebarRowID) -> String {
        switch row {
        case .local(let id): "sent.open:local:\(id.rawValue)"
        case .remote(let ref): "sent.open:remote:\(ref.hostID.uuidString):\(ref.agentID.rawValue)"
        case .design(let id): "sent.open:design:\(id.rawValue)"
        case .remoteDesign(let ref): "sent.open:design:\(ref.hostID.uuidString):\(ref.designID.rawValue)"
        case .dispatch(let id): "sent.open:dispatch:\(id.uuidString)"
        }
    }

    /// More than this many threads nested under one thread fold under it until it is opened or one of them is on screen.
    static let foldsAbove = 2

    /// Places every thread another thread started among `lists` (the rows of one or more groups, in order): under the thread that started it while it
    /// works or asks, and in its own group, as the thread it is, once it is finished or when that thread isn't among the rows. One that asks you stays
    /// in Needs you as well. Activity only: the Spaces tree keeps every thread in its own space.
    static func arrange(_ lists: inout [[SidebarListRow]], by infos: [SidebarRowID: SidebarSentInfo]) {
        guard !infos.isEmpty else { return }
        let present = Set(lists.flatMap { $0.map(\.id) })
        // The top of each chain of threads that started one another that this Mac can see.
        func root(of id: SidebarRowID) -> SidebarRowID? {
            var seen: Set<SidebarRowID> = [id]
            var top: SidebarRowID?
            var at = id
            while let sender = infos[at]?.sender, present.contains(sender), seen.insert(sender).inserted {
                top = sender
                at = sender
            }
            return top
        }
        // A thread that is finished, or pinned, or whose starter isn't here stays in its group.
        func nests(_ row: SidebarListRow) -> Bool { !row.pinned && [.working, .needsYou].contains(row.section) && root(of: row.id) != nil }
        var children: [SidebarRowID: [(row: SidebarListRow, at: Double)]] = [:]
        for row in lists.joined() {
            guard let info = infos[row.id], nests(row), let top = root(of: row.id) else { continue }
            children[top, default: []].append((row, info.at))
        }
        for list in lists.indices {
            var out: [SidebarListRow] = []
            for var row in lists[list] {
                let id = row.id
                // Still in its own group only where it waits on you.
                if infos[id] != nil, nests(row), row.section != .needsYou { continue }
                if let kids = children[id]?.sorted(by: { $0.at < $1.at }) {
                    if kids.count > foldsAbove { row.fold = SidebarFold(key: foldKey(id)) }
                    out.append(row)
                    out += kids.map {
                        var nested = $0.row
                        nested.fleetNested = true
                        nested.sentRoot = id
                        return nested
                    }
                    continue
                }
                out.append(row)
            }
            lists[list] = out
        }
    }
}
