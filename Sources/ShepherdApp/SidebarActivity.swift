import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar
import ShepherdUI

/// When each agent's sparkline may next be published: at most every `interval`, the first sample at once, and a
/// sample that comes early held until the interval is up so the newest always lands. It keeps no clock: the times
/// are the events' own (`ShepherdViewModel.recordSidebarActivity`), so a burst of tool finishes draws a row a few
/// times a second, not once per tool.
struct ActivityPacing {
    static let interval: TimeInterval = 0.25
    /// How long past its deadline a flush waits, so the agents whose deadlines fall a few milliseconds apart publish
    /// in one pass of the sidebar, not one pass each.
    static let coalescing: TimeInterval = 0.025

    private var published: [AgentID: Date] = [:]
    private var held: [AgentID: [Double]] = [:]

    /// The samples to publish now, or nil while they wait for `due`.
    mutating func record(_ id: AgentID, samples: [Double], at now: Date) -> [Double]? {
        if let last = published[id], now.timeIntervalSince(last) < Self.interval {
            held[id] = samples
            return nil
        }
        published[id] = now
        held[id] = nil
        return samples
    }

    /// The held samples whose interval is up at `now`, now published, and when the next held ones are due.
    mutating func due(at now: Date) -> (publish: [AgentID: [Double]], next: Date?) {
        var publish: [AgentID: [Double]] = [:]
        for (id, samples) in held {
            guard let last = published[id], now.timeIntervalSince(last) >= Self.interval else { continue }
            publish[id] = samples
        }
        for id in publish.keys {
            held[id] = nil
            published[id] = now
        }
        return (publish, nextDue)
    }

    /// When the earliest held samples are due, or nil with none held.
    var nextDue: Date? {
        held.keys.compactMap { published[$0]?.addingTimeInterval(Self.interval) }.min()
    }

    /// Starts the agent over: its next sample is its first.
    mutating func forget(_ id: AgentID) {
        published[id] = nil
        held[id] = nil
    }
}

@MainActor
extension ShepherdViewModel {
    var sidebarActivityItems: [SidebarActivityItem] {
        presentedSidebarLists.items(collapsed: collapsedActivitySections, openRunGroups: collapsedProjects,
                                    projects: sidebarLogicalProjects, showsProjects: projectsEnabled,
                                    selectedAutomation: shownDestination == .automations ? automationsPageSelection : nil,
                                    forgePins: sidebarForgePins, forgePinsProblem: forgeStore.sidebar?.pinsProblem)
    }

    /// Issues & PRs' pins as Pinned draws them, newest first.
    var sidebarForgePins: [SidebarForgePin] {
        guard let sidebar = forgeStore.sidebar else { return [] }
        let viewer = forgeStore.lists.values.lazy.compactMap(\.viewer).first
        return sidebar.pins.map { SidebarForgePin($0, viewer: viewer) }
    }

    func toggleActivitySection(_ section: SidebarActivitySection) {
        if collapsedActivitySections.contains(section) {
            collapsedActivitySections.remove(section)
        } else {
            collapsedActivitySections.insert(section)
        }
    }

    /// Selecting a sender, or a thread it sent, shows what it sent (Activity: the Spaces tree folds none).
    func openSentFoldsHoldingSelection() {
        guard let selected = selectedSidebarRow else { return }
        for row in sidebarLists.all where row.id == selected {
            let keys = [row.fold?.key, row.sentRoot.map(SidebarSent.foldKey)].compactMap { $0 }
            for key in keys where !collapsedProjects.contains(key) { collapsedProjects.insert(key) }
        }
    }

    func openActivitySectionHoldingSelection() {
        openSentFoldsHoldingSelection()
        guard sidebarStyle == .activity, let selected = selectedSidebarRow,
              let section = sidebarLists.sections.first(where: { $0.rows.contains { $0.id == selected } })?.section else { return }
        collapsedActivitySections.remove(section)
        // Selecting a run opens its group.
        if let automation = sidebarLists.automations.first(where: { $0.id == selected })?.foldedUnder {
            let key = SidebarLists.runGroupKey(automation)
            if !collapsedProjects.contains(key) { collapsedProjects.insert(key) }
        }
    }

    /// A command or rejected opening send may never report a turn. Drop the startup marker
    /// once the host has no pending message, using revision pushes rather than a polling loop.
    func reconcileSidebarOpeningTurn(_ id: AgentID) {
        guard sidebarOpeningTurns.contains(id), !sidebarPreparingOpeningTurns.contains(id) else { return }
        Task {
            guard case .snapshot(let snapshot) = try? await nativeThread(id, request: .snapshot()),
                  !snapshot.piSessionID.isEmpty, !snapshot.running,
                  !snapshot.messages.contains(where: { $0.status == "pending" }) else { return }
            sidebarOpeningTurns.remove(id)
        }
    }

    /// A tool finished. The rate since the last one joins the agent's tail at once; the box its row reads is
    /// written when `ActivityPacing` says, so a burst of tools redraws the row a few times a second.
    func recordSidebarActivity(_ id: AgentID, at now: Date = Date()) {
        let previous = sidebarActivityLast[id] ?? statusSince[id]
        sidebarActivityLast[id] = now
        guard let previous, now > previous else { return }
        let tail = Array((sidebarActivityTail[id, default: []] + [1 / now.timeIntervalSince(previous)]).suffix(10))
        sidebarActivityTail[id] = tail
        if let samples = sidebarActivityPacing.record(id, samples: tail, at: now) {
            agentLive(id).samples = samples
        } else {
            armSidebarActivityFlush(after: now)
        }
    }

    /// One short-lived wait for the earliest held samples, on the events' own clock: it sleeps what is left of
    /// their interval and a little more (`ActivityPacing.coalescing`), then publishes every sample due by then.
    private func armSidebarActivityFlush(after now: Date) {
        guard let next = sidebarActivityPacing.nextDue else { return }
        let at = next.addingTimeInterval(ActivityPacing.coalescing)
        if let armed = sidebarActivityFlush, armed.due <= at { return }
        sidebarActivityFlush?.task.cancel()
        let wait = min(max(at.timeIntervalSince(now), 0), ActivityPacing.interval + ActivityPacing.coalescing)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.flushSidebarActivity(at: at)
        }
        sidebarActivityFlush = (task, at)
    }

    func flushSidebarActivity(at now: Date) {
        sidebarActivityFlush?.task.cancel()
        sidebarActivityFlush = nil
        let due = sidebarActivityPacing.due(at: now)
        for (id, samples) in due.publish { agentLives[id]?.samples = samples }
        if due.next != nil { armSidebarActivityFlush(after: now) }
    }

    /// A turn starting begins the sparkline again: no samples, and none held to land after it.
    func resetSidebarActivity(_ id: AgentID) {
        agentLives[id]?.samples = []
        sidebarActivityLast[id] = Date()
        forgetSidebarActivity(id)
    }

    /// Drops the agent's tail and its pacing; the wait ends when nothing is left to publish.
    func forgetSidebarActivity(_ id: AgentID) {
        sidebarActivityTail[id] = nil
        sidebarActivityPacing.forget(id)
        if sidebarActivityPacing.nextDue == nil {
            sidebarActivityFlush?.task.cancel()
            sidebarActivityFlush = nil
        }
    }

    /// Leaving for a page does not clear Done. Only opening another thread marks the current
    /// completion read; a later completion has a different generation.
    func willOpenSidebarThread(_ row: SidebarRowID) {
        if queuedReview != row { queuedReview = nil }
        let previous = sidebarReadingThread ?? selectedSidebarRow
        if let previous, previous != row, let completion = sidebarReadingCompletion {
            markSidebarSeen(previous, completion)
        }
        sidebarReadingThread = row
        sidebarReadingCompletion = sidebarLists.all.first(where: { $0.id == row })?.completion
    }

    func markAllSidebarDoneSeen() {
        for row in sidebarLists.done where row.id.dispatchID == nil {
            if let completion = row.completion { markSidebarSeen(row.id, completion) }
        }
    }

    /// Seen here at once, and told to the thread's host when the completion is the host's own
    /// (`Agent.completedAt`), so Done clears on every device. An older host refuses; this device
    /// still remembers.
    private func markSidebarSeen(_ row: SidebarRowID, _ completion: Int) {
        sidebarSeenCompletions[row] = completion
        let ref: RemoteAgentRef?, agent: Agent?
        switch row {
        case .local(let id): ref = localRef(id); agent = state.agents.first { $0.id == id }
        case .remote(let remote):
            ref = remote
            agent = remoteHosts.connections.first { $0.id == remote.hostID }?.state.agents.first { $0.id == remote.agentID }
        case .design, .remoteDesign, .dispatch: return
        }
        guard let agent, let stamp = agent.completedAt, Int(stamp) == completion, agent.completionSeen == false else { return }
        Task {
            if let ref { try? await remoteHosts.agentAction(ref, action: .markSeen(upTo: stamp)) }
        }
    }
}
