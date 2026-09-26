import Foundation
import SystemConfiguration
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The sidebar as plain values (NWNavigation; Main, Running, NavNewThread, NavAutomations,
// NavHosts): the destinations, Needs you, Recents, and the footer. Derived once per change from
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

/// What a Needs you or Recents row opens: an agent's thread, or a design (its canvas and its
/// agent's chat).
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

/// One row of Needs you or Recents, as the row draws it and its context menu needs it.
struct SidebarListRow: Identifiable, Equatable {
    let id: SidebarRowID
    let title: String
    let leading: NWSidebarRow.Leading
    var accessory: NWSidebarRow.Accessory
    var selected = false
    /// A remote thread whose host is not connected: its last known state, dimmed, and its menu
    /// has nothing to offer until the host is back.
    var offline = false
    /// The title, and the worktree's branch.
    let help: String
    /// "Fix the login, worktree, running, on horizon".
    let accessibilityLabel: String
    /// A worktree agent: its menu offers Finalize and Delete Worktree Agent.
    let worktree: Bool
    /// A run of one of This Mac's automations: its menu offers Stop or Run Now.
    let automation: AutomationID?
    /// That run is going (its menu offers Stop).
    let automationLive: Bool
}

/// Needs you and Recents in display order, before selection and ⌘-digit hints are applied.
struct SidebarLists: Equatable {
    /// Everything waiting on you: a thread's question, a subagent asking, an automation run
    /// that asked. Most recently active first.
    var needsYou: [SidebarListRow] = []
    /// Every other agent, local and remote, automation runs included, most recently active
    /// first (`Agent.lastActiveAt`).
    var recents: [SidebarListRow] = []

    /// The rows ⌘↑/↓ walk through: Needs you, then Recents.
    var all: [SidebarListRow] { needsYou + recents }

    /// The Recents rows ⌘1–9 reach, in order: every thread's. A design takes no digit.
    var shortcutRows: [SidebarListRow] {
        recents.filter { if case .design = $0.id { false } else { true } }
    }

    /// The lists with the row on screen marked, and the first nine thread rows of Recents
    /// wearing their ⌘-digit while ⌘ is held.
    func presented(selected: SidebarRowID?, shortcuts: Bool) -> SidebarLists {
        var lists = self
        if let selected {
            for index in lists.needsYou.indices where lists.needsYou[index].id == selected { lists.needsYou[index].selected = true }
            for index in lists.recents.indices where lists.recents[index].id == selected { lists.recents[index].selected = true }
        }
        if shortcuts {
            var digit = 0
            for index in lists.recents.indices where digit < 9 {
                if case .design = lists.recents[index].id { continue }
                digit += 1
                lists.recents[index].accessory = .shortcut("⌘\(digit)")
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
        var children: [AgentID: [ChildRun]]
        /// Not connected: `state` is what it last sent this launch.
        var offline = false
    }

    var local: ShepherdState
    var localChildren: [AgentID: [ChildRun]] = [:]
    /// This Mac's agents whose last turn ended in an error.
    var failedTurns: Set<AgentID> = []
    /// This Mac's agents whose pi stopped before it served, waiting for Retry.
    var cannotStart: Set<AgentID> = []
    /// When each of This Mac's agents entered its status: a running row's elapsed time.
    var statusSince: [AgentID: Date] = [:]
    /// Each automation's open run (`AutomationRun.isLive`).
    var openRuns: [AutomationID: AutomationRun] = [:]
    /// Every configured host, in configured order; one that is offline lists what it last sent.
    var hosts: [Host] = []
    /// Settings ▸ Experiments ▸ Design tool: This Mac's designs are Recents rows. Their agents
    /// never are: a design's chat is its agent's thread.
    var designs = false
}

enum SidebarDerivation {
    /// Needs you and Recents, in order. Pure: the same source always gives the same lists.
    @MainActor static func lists(_ source: SidebarSource) -> SidebarLists {
        NWRenderProbe.tick("sidebar.lists")
        var entries: [(row: SidebarListRow, needsYou: Bool, key: Double, host: Int, index: Int)] = []
        let localRuns = Dictionary(source.local.automations.compactMap { automation in
            automation.agentID.map { ($0, automation) }
        }, uniquingKeysWith: { first, _ in first })
        let designs = Set(source.local.designs.map(\.id))
        for (index, agent) in source.local.agents.enumerated() {
            if let design = agent.designID, designs.contains(design) { continue }
            let automation = localRuns[agent.id]
            let children = source.localChildren[agent.id] ?? []
            let needsYou = agent.status == .blocked || children.contains(where: \.needsAttention)
            let run = automation.flatMap { source.openRuns[$0.id] }.flatMap { $0.agentID == agent.id ? $0 : nil }
            let row = localRow(agent, automation: automation, run: run, children: children, needsYou: needsYou,
                               failed: source.failedTurns.contains(agent.id), cannotStart: source.cannotStart.contains(agent.id),
                               since: source.statusSince[agent.id])
            entries.append((row, needsYou, agent.lastActiveAt ?? -1, 0, index))
        }
        if source.designs {
            // A system build's page opens from its system, never from Recents.
            for (index, design) in source.local.designs.enumerated() where !design.buildsSystem {
                entries.append((designRow(design), false, design.lastActiveAt, 0, index))
            }
        }
        for (hostIndex, host) in source.hosts.enumerated() {
            let runs = Set(host.state.automations.compactMap(\.agentID))
            // A host sends no design's agent (`withoutDesigns`); one from before that is no thread either.
            for (index, agent) in host.state.agents.enumerated() where !host.state.isDesignAgent(agent) {
                let children = host.offline ? [] : host.children[agent.id] ?? []
                // Nothing on an offline host can be answered, so none of it waits on you here.
                let needsYou = !host.offline && (agent.status == .blocked || children.contains(where: \.needsAttention))
                let row = remoteRow(agent, host: host, automation: runs.contains(agent.id), children: children, needsYou: needsYou)
                entries.append((row, needsYou, agent.lastActiveAt ?? -1, hostIndex + 1, index))
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
        for entry in entries {
            if entry.needsYou { lists.needsYou.append(entry.row) } else { lists.recents.append(entry.row) }
        }
        return lists
    }

    /// The short reason a Needs you row gives: the agent's own word or two for its question
    /// ("retention?"), else the question cut short; else the asking subagent's own reason, else
    /// its name; else "ASK".
    static func reason(question: String?, short: String? = nil, children: [ChildRun]) -> String {
        if let question = question.flatMap(nonEmpty) { return shortened(short.flatMap(nonEmpty) ?? question) }
        if let child = children.first(where: \.needsAttention),
           let reason = child.question?.short.flatMap(nonEmpty) ?? nonEmpty(child.role ?? child.label) {
            return shortened(reason)
        }
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

    private static func localRow(_ agent: Agent, automation: Automation?, run: AutomationRun?, children: [ChildRun],
                                 needsYou: Bool, failed: Bool, cannotStart: Bool = false, since: Date?) -> SidebarListRow {
        let failed = failed && agent.status == .done
        let live = automation != nil && AutomationRow.isLive(agent, run: run)
        let leading: NWSidebarRow.Leading
        let accessory: NWSidebarRow.Accessory
        let word: String
        if needsYou {
            leading = automation == nil ? .dot(.attention) : .glyph("bolt", attention: true)
            accessory = .reason(reason(question: agent.waitingOn, short: agent.waitingReason, children: children))
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
        return SidebarListRow(
            id: .local(agent.id), title: agent.name, leading: leading, accessory: accessory,
            help: agent.worktreeBranch.map { "\(agent.name) · worktree \($0)" } ?? agent.name,
            accessibilityLabel: label(agent, word: word, automation: automation != nil, host: nil),
            worktree: agent.worktreeBranch != nil, automation: automation?.id, automationLive: live)
    }

    /// A design in Recents (NavDesigns): the nib in place of the status dot, and its board count.
    private static func designRow(_ design: Design) -> SidebarListRow {
        let boards = DesignsPageModel.boardsText(design.boardCount ?? 0)
        return SidebarListRow(
            id: .design(design.id), title: design.name, leading: .glyph("pencil.tip", attention: false),
            accessory: .text(boards), help: design.name, accessibilityLabel: "\(design.name), design, \(boards)",
            worktree: false, automation: nil, automationLive: false)
    }

    private static func remoteRow(_ agent: Agent, host: SidebarSource.Host, automation: Bool, children: [ChildRun],
                                  needsYou: Bool) -> SidebarListRow {
        let leading: NWSidebarRow.Leading
        let accessory: NWSidebarRow.Accessory
        let word: String
        if needsYou {
            leading = automation ? .glyph("bolt", attention: true) : .dot(.attention)
            accessory = .reason(reason(question: agent.waitingOn, short: agent.waitingReason, children: children))
            word = "needs you"
        } else {
            leading = automation ? .glyph("bolt", attention: false) : .dot(AgentState(agent.status))
            accessory = .tag(host.name)
            word = AgentRow.statusWord(agent.status)
        }
        let help = agent.worktreeBranch.map { "\(agent.name) · worktree \($0)" } ?? agent.name
        return SidebarListRow(
            id: .remote(RemoteAgentRef(hostID: host.id, agentID: agent.id)), title: agent.name, leading: leading,
            accessory: accessory, offline: host.offline, help: host.offline ? "\(help) · \(host.name) is offline" : help,
            accessibilityLabel: label(agent, word: word, automation: automation, host: host.name)
                + (host.offline ? ", host offline" : ""),
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
            /// Settings ▸ Pi, where the bundled extensions are.
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
