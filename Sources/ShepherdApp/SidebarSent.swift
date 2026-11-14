import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Threads sent to other Macs, in the sidebar (FleetSubthreads): a sent thread nests under the thread that sent it with the Mac and stage on its
// second line, a sender says "3 sent · 1 back", more than two fold, a thread that is back leaves the tree for its own group, and one whose sender
// isn't here is a flat "sent by" row. Plain values derived with the lists, never in a view's body.

/// Where a sent thread came from and where it is: what the tree needs to place its row.
struct SidebarSentInfo: Equatable {
    /// The row of the thread that sent it, when this Mac can name it.
    var sender: SidebarRowID?
    /// The sender's title, as it was when the work went ("" for a thread the person started).
    var senderTitle: String
    /// The sender's Mac when it isn't one this Mac sees ("sent by Release prep · studio").
    var senderHost: String?
    var stage: FleetSentStage
    /// When it was sent, in epoch milliseconds: a sender lists what it sent in this order.
    var at: Double
    /// The person started it from New thread, not a thread.
    var userStarted: Bool
}

extension AgentState {
    init(_ mark: FleetSentStage.Mark) {
        switch mark {
        case .hollow: self = .idle
        case .running: self = .running
        case .attention: self = .attention
        case .failed: self = .failed
        case .done: self = .done
        }
    }
}

extension SHSidebarRow.Subtitle.Tone {
    init(_ mark: FleetSentStage.Mark?) {
        switch mark {
        case .running?: self = .running
        case .attention?: self = .attention
        case .failed?: self = .failed
        case .hollow?, .done?, nil: self = .quiet
        }
    }
}

extension SidebarDerivation {
    /// The tree facts of a thread another Mac sent or this Mac was sent; nil for any other. `host` is the Mac it runs on (nil: This Mac).
    static func sentInfo(of agent: Agent, host: SidebarSource.Host?, _ source: SidebarSource) -> SidebarSentInfo? {
        guard let from = agent.dispatchedFrom else { return nil }
        let tag = host.map { $0.fleetID == nil ? $0.name : FleetWherePicker.tagName($0.name) } ?? "This Mac"
        let stage: FleetSentStage
        if let record = source.fleet.record(from.dispatchID) {
            stage = .of(record, thread: agent.status, viewer: source.localFleetID, next: source.fleet.next, live: source.fleet.live(record),
                        cap: source.fleet.cap)
        } else {
            stage = .of(thread: agent.status, host: tag)
        }
        let sender = fleetSender(of: agent, source)
        let elsewhere = sender == nil && from.agentID != nil && from.hostID != source.localFleetID
        return SidebarSentInfo(sender: sender, senderTitle: from.agentTitle, senderHost: elsewhere ? FleetWherePicker.tagName(from.hostName) : nil,
                               stage: stage, at: from.at, userStarted: from.agentID == nil)
    }

    /// The dispatches this Mac sent that have no thread to draw: their own rows, with their facts. A dispatch whose thread is among `threads` is
    /// drawn as that thread.
    static func dispatchRows(_ source: SidebarSource, threads: Set<UUID>, now: Date = Date()) -> [(row: SidebarListRow, info: SidebarSentInfo, key: Double, space: SpaceID?)] {
        let pending: Set<FleetDispatchState> = [.placing, .waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing, .failed]
        let dayAgo = (now.timeIntervalSince1970 - 86_400) * 1000
        return source.fleet.records.compactMap { record in
            guard record.kind != .move, pending.contains(record.state), !threads.contains(record.id),
                  record.state != .failed || record.updatedAt > dayAgo else { return nil }
            // Auto starts a thread the person made on the Mac with the most room: no "next" Mac to name when none has any.
            let stage = FleetSentStage.of(record, viewer: source.localFleetID, next: record.kind == .userThread ? nil : source.fleet.next,
                                          live: source.fleet.live(record), cap: source.fleet.cap)
            let sender = record.parentAgentID.flatMap { id in
                record.parentHostID == source.localFleetID ? SidebarRowID.local(id) : source.hosts.first { $0.fleetID == record.parentHostID }
                    .map { .remote(RemoteAgentRef(hostID: $0.id, agentID: id)) }
            }
            let info = SidebarSentInfo(sender: sender, senderTitle: record.parentTitle, senderHost: nil, stage: stage, at: record.createdAt,
                                       userStarted: record.kind == .userThread)
            let title = record.title.isEmpty ? "Untitled" : record.title
            let line = info.userStarted && stage.phase == .noRoom ? "Auto · \(stage.words)" : stage.line()
            var row = SidebarListRow(id: .dispatch(record.id), title: title, leading: .dot(AgentState(stage.dot)), accessory: .none,
                                     section: .working, help: "\(title) · \(line)", accessibilityLabel: "\(title), sent thread, \(line)",
                                     worktree: false, automation: nil, automationLive: false)
            row.subtitle = .init(line, tone: .init(stage.tone))
            return (row, info, record.updatedAt, record.spaceID)
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

    /// Places every sent thread among `lists` (the rows of one or more groups, in order): under its sender while it is on its way or working,
    /// in its own group, with "sent by <thread>" under it, once it is back or its sender isn't among the rows. A sent thread that asks you
    /// stays in Needs you as well, "from <sender>" (`keepsNeedsYou`: the Spaces tree has no Needs you). A sender says what it sent.
    static func arrange(_ lists: inout [[SidebarListRow]], by infos: [SidebarRowID: SidebarSentInfo], keepsNeedsYou: Bool = true) {
        guard !infos.isEmpty else { return }
        let present = Set(lists.flatMap { $0.map(\.id) })
        // The top of each chain of senders that this Mac can see.
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
        var children: [SidebarRowID: [(row: SidebarListRow, info: SidebarSentInfo)]] = [:]
        for row in lists.joined() {
            guard let info = infos[row.id], !row.pinned, let top = root(of: row.id) else { continue }
            children[top, default: []].append((row, info))
        }
        // Nested rows go under their root; a thread that is back, or pinned, or whose sender isn't here stays in its group.
        func nested(_ row: SidebarListRow, _ info: SidebarSentInfo, top: SidebarRowID) -> SidebarListRow {
            var row = row
            row.fleetNested = true
            row.sentRoot = top
            row.leading = .dot(AgentState(info.stage.dot))
            row.accessory = .none
            row.pullRequest = nil
            let via = info.sender == top || info.senderTitle.isEmpty ? nil : "via \(info.senderTitle)"
            let line = [via, info.stage.line()].compactMap { $0 }.joined(separator: " · ")
            row.subtitle = .init(line, tone: .init(info.stage.tone), since: info.stage.runningSince.map { Date(timeIntervalSince1970: $0 / 1000) })
            row.accessibilityLabel = "\(row.title), sent thread, \(line)"
            row.help = "\(row.title) · \(line)"
            return row
        }
        let nestable: (SidebarSentInfo) -> Bool = { $0.stage.phase != .back }
        for list in lists.indices {
            var out: [SidebarListRow] = []
            for var row in lists[list] {
                let id = row.id
                if let info = infos[id], !row.pinned, root(of: id) != nil, nestable(info) {
                    // Still in its own group only where it waits on you.
                    guard keepsNeedsYou, row.section == .needsYou else { continue }
                    row.subtitle = .init(info.senderTitle.isEmpty ? "sent from another Mac" : "from \(info.senderTitle)", tone: .attention)
                    row.accessory = .none
                } else if let info = infos[id], !info.userStarted, !info.senderTitle.isEmpty || info.senderHost != nil {
                    let by = ["sent by \(info.senderTitle.isEmpty ? "a thread" : info.senderTitle)", info.senderHost].compactMap { $0 }
                    row.subtitle = .init(by.joined(separator: " · "))
                }
                if let kids = children[id], !kids.isEmpty {
                    let counts = (sent: kids.count, back: kids.filter { !nestable($0.info) }.count,
                                  asking: kids.contains { $0.info.stage.phase == .asking })
                    row.subtitle = FleetSentSummary.line(sent: counts.sent, back: counts.back, asking: counts.asking).map { .init($0) }
                    let live = kids.filter { nestable($0.info) }.sorted { $0.info.at < $1.info.at }
                    if !live.isEmpty, counts.sent > FleetSentSummary.foldsAbove { row.fold = SidebarFold(key: foldKey(id)) }
                    out.append(row)
                    out += live.map { nested($0.row, $0.info, top: id) }
                    continue
                }
                out.append(row)
            }
            lists[list] = out
        }
    }
}
