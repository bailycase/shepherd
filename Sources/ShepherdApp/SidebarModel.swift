import Foundation
import SystemConfiguration
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The sidebar as plain values (NWNavigation): destinations, status groups, Designs and footer. Derived once per change from
// This Mac's state and every connected host's, never in a view's body.

/// A page the main column shows in place of a thread.
enum MainDestination: Hashable, CaseIterable {
    /// NavNewThread: ⌘N or the first destination.
    case newThread
    /// NavDesigns (Settings ▸ Experiments ▸ Design tool).
    case designs
    /// DZStart: a new design's brief. The sidebar shows Designs selected.
    case newDesign
    /// DZSystem (More ▸ Design systems): a design system without an agent of its own. A system
    /// built from a repository shows as its build's layout instead.
    case designSystem
    /// NavAutomations.
    case automations
    /// NavHosts (More ▸ Hosts).
    case hosts
}

/// What a Needs you, Pinned or Recents row opens: an agent's thread, or a design (its canvas and
/// its agent's chat).
enum SidebarRowID: Hashable {
    case local(AgentID)
    case remote(RemoteAgentRef)
    case design(DesignID)

    /// The agent the row names; nil for a design.
    var agentID: AgentID? {
        switch self {
        case .local(let id): id
        case .remote(let ref): ref.agentID
        case .design: nil
        }
    }
}

/// One row of Needs you, Pinned or Recents, as the row draws it and its context menu needs it.
struct SidebarListRow: Identifiable, Equatable {
    let id: SidebarRowID
    let title: String
    let leading: NWSidebarRow.Leading
    var accessory: NWSidebarRow.Accessory
    var hasGoal = false
    var selected = false
    /// One extra project level in the project sidebar, never in Activity.
    var inChildProject = false
    /// A thread the Activity sidebar can pin: not an automation run or a design. Only the
    /// Activity lists say so, so the project tree's menus offer no Pin.
    var pinnable = false
    /// A pinned thread stays in Pinned, including while it waits on the user.
    var pinned = false
    var section: SidebarActivitySection = .recents
    /// App-owned completion generation, unchanged by sends or repeated snapshots.
    var completion: Int?
    /// A remote thread whose host is not connected: its last known state, dimmed, and its menu
    /// has nothing to offer until the host is back.
    var offline = false
    /// The title, and the worktree's branch.
    let help: String
    /// "Fix the login, worktree, running, on horizon"; ", pinned" follows a pinned thread's.
    var accessibilityLabel: String
    /// A worktree agent: its menu offers Finalize and Delete Worktree Agent.
    let worktree: Bool
    /// A run of one of This Mac's automations: its menu offers Stop or Run Now.
    let automation: AutomationID?
    /// That run is going (its menu offers Stop).
    let automationLive: Bool
}

/// Activity groups in display order, before selection and ⌘-digit hints are applied.
struct SidebarLists: Equatable {
    /// Unpinned threads waiting on the user, most recently active first.
    var needsYou: [SidebarListRow] = []
    /// The threads the user pinned, in the order they pinned them (oldest first).
    var pinned: [SidebarListRow] = []
    var working: [SidebarListRow] = []
    /// Finished, unseen threads; reading one keeps it here until another thread opens.
    var done: [SidebarListRow] = []
    /// Idle and seen threads, most recently active first (`Agent.lastActiveAt`).
    var recents: [SidebarListRow] = []
    var designs: [SidebarListRow] = []
    /// Every row once, Needs you's first and the rest most recently active first, pinned or
    /// not: what a launch shows and the New thread page's Continue card read. Unmarked, as derived.
    var activity: [SidebarListRow] = []

    var all: [SidebarListRow] { sections.flatMap(\.rows) }

    /// Needs you and Designs have no digit; folded groups have no visible hint or target.
    var shortcutRows: [SidebarListRow] { shortcutRows(collapsed: []) }

    func shortcutRows(collapsed: Set<SidebarActivitySection>) -> [SidebarListRow] {
        sections.filter { $0.section != .needsYou && $0.section != .designs && !collapsed.contains($0.section) }
            .flatMap(\.rows)
    }

    func presented(selected: SidebarRowID?, shortcuts: Bool,
                   collapsed: Set<SidebarActivitySection> = []) -> SidebarLists {
        var lists = self
        let digits = shortcuts ? Dictionary(uniqueKeysWithValues: shortcutRows(collapsed: collapsed).prefix(9).enumerated()
            .map { ($0.element.id, "⌘\($0.offset + 1)") }) : [:]
        for path in [\SidebarLists.pinned, \.needsYou, \.working, \.done, \.recents, \.designs] {
            for index in lists[keyPath: path].indices {
                let id = lists[keyPath: path][index].id
                lists[keyPath: path][index].selected = id == selected
                if let digit = digits[id] { lists[keyPath: path][index].accessory = .shortcut(digit) }
            }
        }
        return lists
    }
}

/// What the sidebar's lists are derived from: This Mac's state, and each connected host's.
struct SidebarSource: Equatable {
    struct Host: Equatable {
        var id: UUID
        var name: String
        var state: ShepherdState
        /// Not connected: `state` is what it last sent this launch.
        var offline = false
    }

    var local: ShepherdState
    var openingTurns: Set<AgentID> = []
    var completions: [SidebarRowID: SidebarCompletions.Record] = [:]
    /// This Mac's agents whose last turn ended in an error.
    var failedTurns: Set<AgentID> = []
    /// This Mac's agents whose pi stopped before it served, waiting for Retry.
    var cannotStart: Set<AgentID> = []
    /// Of those, the ones that stopped because nothing signs in for their model: Needs you.
    var notSignedIn: Set<AgentID> = []
    /// This Mac's restored agents the first launch's copy from your pi holds.
    var waiting: Set<AgentID> = []
    /// When each of This Mac's agents entered its status: a running row's elapsed time.
    var statusSince: [AgentID: Date] = [:]
    /// Each automation's open run (`AutomationRun.isLive`).
    var openRuns: [AutomationID: AutomationRun] = [:]
    /// Every configured host, in configured order; one that is offline lists what it last sent.
    var hosts: [Host] = []
    /// Settings ▸ Experiments ▸ Design tool: This Mac's designs have their own group. Their agents
    /// never are: a design's chat is its agent's thread.
    var designs = false

    /// Child work affects sidebar presentation, never the parent's actual turn status.
    static func presentationState(_ state: ShepherdState, children: [AgentID: [ChildRun]]) -> ShepherdState {
        var state = state
        for index in state.agents.indices {
            let agent = state.agents[index]
            if (agent.status == .idle || agent.status == .done),
               children[agent.id]?.contains(where: { !$0.isTerminal && $0.paused != true }) == true {
                state.agents[index].status = .working
            }
        }
        return state
    }
}

enum SidebarDerivation {
    private typealias Entry = (row: SidebarListRow, pin: PinnedThread?, needsYou: Bool, key: Double, host: Int, index: Int)

    /// Exclusive activity groups. The same source, pins and seen generations give the same lists.
    @MainActor static func lists(_ source: SidebarSource, pins: SidebarPins = SidebarPins(),
                                seen: [SidebarRowID: Int] = [:]) -> SidebarLists {
        NWRenderProbe.tick("sidebar.lists")
        let pinned = Set(pins.threads)
        var entries: [Entry] = []
        /// A thread's entry, marked for pinning; `pin` is nil for what is never pinned (an
        /// automation's run, a design). Only a pinned thread keeps its pin on the entry.
        func entry(_ row: SidebarListRow, _ pin: PinnedThread?, needsYou: Bool, key: Double, host: Int, index: Int) -> Entry {
            var row = row
            if row.completion != nil {
                let completion = source.completions[row.id]
                row.completion = completion?.generation ?? 1
                if case .local(let id) = row.id, !source.failedTurns.contains(id) {
                    let settled = row.automation.flatMap { source.openRuns[$0] }
                        .flatMap { $0.agentID == id ? $0.settledAt : nil }
                    let milliseconds = completion?.completedAt ?? (key >= 0 ? key : nil)
                        ?? settled.map { $0 * 1000 } ?? source.statusSince[id].map { $0.timeIntervalSince1970 * 1000 }
                    if let milliseconds { row.accessory = .age(since: Date(timeIntervalSince1970: milliseconds / 1000)) }
                }
            }
            var kept: PinnedThread?
            if let pin {
                row.pinnable = true
                if pinned.contains(pin) {
                    row.pinned = true
                    row.accessibilityLabel += ", pinned"
                    kept = pin
                }
            }
            return (row, kept, needsYou, key, host, index)
        }
        let localRuns = Dictionary(source.local.automations.compactMap { automation in
            automation.agentID.map { ($0, automation) }
        }, uniquingKeysWith: { first, _ in first })
        let designs = Set(source.local.designs.map(\.id))
        for (index, agent) in source.local.agents.enumerated() {
            if let design = agent.designID, designs.contains(design) { continue }
            let automation = localRuns[agent.id]
            let notSignedIn = source.notSignedIn.contains(agent.id)
            // A subagent's question goes to its parent, never to the user: only the thread's own
            // question, or a missing sign-in, puts its row in Needs you.
            let needsYou = agent.status == .blocked || notSignedIn
            let run = automation.flatMap { source.openRuns[$0.id] }.flatMap { $0.agentID == agent.id ? $0 : nil }
            let row = localRow(agent, automation: automation, run: run, needsYou: needsYou,
                               failed: source.failedTurns.contains(agent.id), cannotStart: source.cannotStart.contains(agent.id),
                               notSignedIn: notSignedIn, waiting: source.waiting.contains(agent.id),
                               opening: source.openingTurns.contains(agent.id), since: source.statusSince[agent.id])
            entries.append(entry(row, automation == nil ? .local(agent.id) : nil, needsYou: needsYou,
                                 key: agent.lastActiveAt ?? -1, host: 0, index: index))
        }
        if source.designs {
            // A system build opens from its system. Remove from Recents hides a design's
            // sidebar row until it changes again (DesignRecentsMenu).
            for (index, design) in source.local.designs.enumerated() where design.inRecents {
                entries.append(entry(designRow(design), nil, needsYou: false, key: design.lastActiveAt, host: 0, index: index))
            }
        }
        for (hostIndex, host) in source.hosts.enumerated() {
            let runs = Set(host.state.automations.compactMap(\.agentID))
            // A host sends no design's agent (`withoutDesigns`); one from before that is no thread either.
            for (index, agent) in host.state.agents.enumerated() where !host.state.isDesignAgent(agent) {
                // Nothing on an offline host can be answered, so none of it waits on you here.
                let needsYou = !host.offline && agent.status == .blocked
                let row = remoteRow(agent, host: host, automation: runs.contains(agent.id), needsYou: needsYou)
                let pin = runs.contains(agent.id) ? nil : PinnedThread.remote(RemoteAgentRef(hostID: host.id, agentID: agent.id))
                entries.append(entry(row, pin, needsYou: needsYou, key: agent.lastActiveAt ?? -1, host: hostIndex + 1, index: index))
            }
        }
        // Most recently active first. Agents no host has timed (older hosts and state files)
        // follow, newest created first; ties keep This Mac first, then the hosts in order.
        entries.sort { a, b in
            if a.key != b.key { return a.key > b.key }
            if a.host != b.host { return a.host < b.host }
            return a.index > b.index
        }
        var lists = SidebarLists()
        var pinnedRows: [PinnedThread: SidebarListRow] = [:]
        var calm: [SidebarListRow] = []
        for entry in entries {
            if !entry.needsYou { calm.append(entry.row) }
            if let pin = entry.pin {
                pinnedRows[pin] = entry.row
                continue
            }
            switch entry.row.section {
            case .needsYou: lists.needsYou.append(entry.row)
            case .working: lists.working.append(entry.row)
            case .done:
                if seen[entry.row.id] == entry.row.completion { lists.recents.append(entry.row) }
                else { lists.done.append(entry.row) }
            case .designs: lists.designs.append(entry.row)
            case .recents, .pinned: lists.recents.append(entry.row)
            }
        }
        lists.pinned = pins.threads.compactMap { pinnedRows[$0] }
        lists.done.sort { a, b in
            let left = source.completions[a.id], right = source.completions[b.id]
            let leftTime = left?.completedAt ?? -1, rightTime = right?.completedAt ?? -1
            return leftTime != rightTime ? leftTime > rightTime : (left?.generation ?? 0) > (right?.generation ?? 0)
        }
        lists.activity = entries.filter(\.needsYou).map(\.row) + calm
        return lists
    }

    /// The short reason a Needs you row gives: the agent's own word or two for its question
    /// ("retention?"), else the question cut short; else "ASK".
    static func reason(question: String?, short: String? = nil) -> String {
        if let question = question.flatMap(nonEmpty) { return shortened(short.flatMap(nonEmpty) ?? question) }
        return "ASK"
    }

    /// One line, at most `NWSidebarMetrics.reasonLength` characters (`NeedsYouReason`).
    static func shortened(_ text: String) -> String {
        NeedsYouReason.shortened(text, limit: NWSidebarMetrics.reasonLength)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func localRow(_ agent: Agent, automation: Automation?, run: AutomationRun?,
                         needsYou: Bool, failed: Bool, cannotStart: Bool = false, notSignedIn: Bool = false, waiting: Bool = false,
                         opening: Bool = false, since: Date?) -> SidebarListRow {
        var agent = agent
        if opening, agent.status == .idle { agent.status = .working }
        let failed = failed && agent.status == .done
        let live = automation != nil && AutomationRow.isLive(agent, run: run)
        let leading: NWSidebarRow.Leading
        let accessory: NWSidebarRow.Accessory
        let word: String
        if notSignedIn {
            // PiAuthStates' `.notSignedIn`: it waits for a sign-in, in Needs you.
            leading = automation == nil ? .dot(.attention) : .glyph("bolt", attention: true)
            accessory = .reason("sign in")
            word = "not signed in"
        } else if waiting {
            // PiAuthStates' `.waiting`: held while the first launch's copy runs.
            leading = .waiting
            accessory = .text("waiting")
            word = "waiting"
        } else if needsYou {
            leading = automation == nil ? .dot(.attention) : .glyph("bolt", attention: true)
            accessory = .reason(reason(question: agent.waitingOn, short: agent.waitingReason))
            word = "needs you"
        } else if cannotStart {
            leading = automation == nil ? .dot(.failed) : .glyph("bolt", attention: false)
            accessory = .text("can't start", tone: .failed)
            word = "can't start"
        } else if automation != nil {
            leading = .glyph("bolt", attention: false)
            if live {
                accessory = since.map { .elapsed(since: $0) } ?? .text("running")
                word = "running"
            } else {
                accessory = failed ? .text("failed", tone: .failed) : .text("done")
                word = failed ? "failed" : "done"
            }
        } else {
            leading = .dot(failed ? .failed : AgentState(agent.status))
            accessory = agent.status == .working ? since.map { .elapsed(since: $0) } ?? .none : .none
            word = AgentRow.statusWord(agent.status, turnFailed: failed)
        }
        let finished = !needsYou && !cannotStart && !waiting && (agent.status == .done || (automation != nil && !live && run?.settledAt != nil))
        let section: SidebarActivitySection = needsYou ? .needsYou : waiting || cannotStart ? .recents
            : live || agent.status == .working ? .working : finished ? .done : .recents
        return SidebarListRow(
            id: .local(agent.id), title: agent.name, leading: leading,
            accessory: accessory, hasGoal: agent.goalState != nil,
            section: section, completion: finished ? 1 : nil,
            help: agent.worktreeBranch.map { "\(agent.name) · worktree \($0)" } ?? agent.name,
            accessibilityLabel: label(agent, word: word, automation: automation != nil, host: nil)
                + (agent.goalState != nil ? ", goal" : ""),
            worktree: agent.worktreeBranch != nil, automation: automation?.id, automationLive: live)
    }

    /// A design in its own sidebar group: the nib and its board count.
    private static func designRow(_ design: Design) -> SidebarListRow {
        let boards = DesignsPageModel.boardsText(design.boardCount ?? 0)
        return SidebarListRow(
            id: .design(design.id), title: design.name, leading: .glyph("pencil.tip", attention: false),
            accessory: .text(boards), section: .designs, help: design.name, accessibilityLabel: "\(design.name), design, \(boards)",
            worktree: false, automation: nil, automationLive: false)
    }

    static func remoteRow(_ agent: Agent, host: SidebarSource.Host, automation: Bool,
                          needsYou: Bool) -> SidebarListRow {
        let leading: NWSidebarRow.Leading
        let accessory: NWSidebarRow.Accessory
        let word: String
        if needsYou {
            leading = automation ? .glyph("bolt", attention: true) : .dot(.attention)
            accessory = .reason(reason(question: agent.waitingOn, short: agent.waitingReason))
            word = "needs you"
        } else {
            leading = automation ? .glyph("bolt", attention: false) : .dot(AgentState(agent.status))
            accessory = .tag(host.name)
            word = AgentRow.statusWord(agent.status)
        }
        let help = agent.worktreeBranch.map { "\(agent.name) · worktree \($0)" } ?? agent.name
        return SidebarListRow(
            id: .remote(RemoteAgentRef(hostID: host.id, agentID: agent.id)), title: agent.name, leading: leading,
            accessory: accessory, hasGoal: agent.goalState != nil,
            section: host.offline ? .recents : needsYou ? .needsYou : agent.status == .working ? .working
                : agent.status == .done ? .done : .recents,
            completion: agent.status == .done ? 1 : nil,
            offline: host.offline, help: host.offline ? "\(help) · \(host.name) is offline" : help,
            accessibilityLabel: label(agent, word: word, automation: automation, host: host.name)
                + (host.offline ? ", host offline" : "") + (agent.goalState != nil ? ", goal" : ""),
            worktree: agent.worktreeBranch != nil, automation: nil, automationLive: false)
    }

    private static func label(_ agent: Agent, word: String, automation: Bool, host: String?) -> String {
        var parts = [agent.name]
        if automation { parts.append("automation") }
        if agent.worktreeBranch != nil { parts.append("worktree") }
        parts.append(word)
        if let host { parts.append("on \(host)") }
        return parts.joined(separator: ", ")
    }

    // MARK: Destinations

    /// One destination row, in the order they draw.
    struct Destination: Equatable, Identifiable {
        enum Target: Hashable {
            case page(MainDestination)
            /// More's disclosure.
            case more
            /// Settings ▸ Extensions, the bundled extensions.
            case extensions
            /// More ▸ Design systems: the system page opened last, else the first.
            case designSystems
        }

        let target: Target
        let title: String
        let icon: NWSidebarDestination.Icon
        let selected: Bool
        let child: Bool
        let trailing: NWSidebarDestination.Trailing

        var id: Target { target }
    }

    /// New thread (with its chord), Designs while the Design tool is on (selected on its page and
    /// on New design), Automations, More, and More's Hosts (with how many hosts are offline),
    /// Design systems (with the Design tool; selected while a system's page shows) and Extensions
    /// while it is open. Missions and Archive are not built, so they are not shown.
    static func destinations(shown: MainDestination?, moreOpen: Bool, offlineHosts: Int, newThreadChord: String,
                             designs: Bool = false, systemShown: Bool = false) -> [Destination] {
        var rows = [
            Destination(target: .page(.newThread), title: "New thread", icon: .newThread, selected: shown == .newThread,
                        child: false, trailing: .keycaps(newThreadChord)),
        ]
        if designs {
            rows.append(Destination(target: .page(.designs), title: "Designs", icon: .symbol("pencil.tip"),
                                    selected: shown == .designs || shown == .newDesign, child: false, trailing: .none))
        }
        rows += [
            Destination(target: .page(.automations), title: "Automations", icon: .symbol("bolt"),
                        selected: shown == .automations, child: false, trailing: .none),
            Destination(target: .more, title: "More", icon: .disclosure(open: moreOpen), selected: false, child: false,
                        trailing: .none),
        ]
        if moreOpen {
            rows.append(Destination(target: .page(.hosts), title: "Hosts", icon: .symbol("display"), selected: shown == .hosts,
                                    child: true, trailing: offlineHosts > 0 ? .alert("\(offlineHosts) offline") : .none))
            if designs {
                rows.append(Destination(target: .designSystems, title: "Design systems", icon: .symbol("paintpalette"),
                                        selected: shown == .designSystem || (shown == nil && systemShown), child: true,
                                        trailing: .none))
            }
            rows.append(Destination(target: .extensions, title: "Extensions", icon: .symbol("puzzlepiece.extension"),
                                    selected: false, child: true, trailing: .none))
        }
        return rows
    }

    // MARK: Footer

    /// The footer's second line: "This Mac · build-01".
    static func footerDetail(computerName: String?) -> String {
        let name = computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "This Mac" : "This Mac · \(name)"
    }

    /// The Mac's user and computer, read once.
    @MainActor static let footer: (name: String, detail: String) = {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return (NSFullUserName(), footerDetail(computerName: computer))
    }()
}
