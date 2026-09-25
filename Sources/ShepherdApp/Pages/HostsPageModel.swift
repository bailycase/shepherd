import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

// What the Hosts page draws (NavHosts), derived once per change: This Mac, then each remote
// host in the order they were added, with the facts Shepherd really has about each. A host's
// last pushed state stays after it drops, so an unreachable host still says what waits on it.

/// A remote host as the Hosts page reads it.
struct HostsPageRemote: Equatable {
    var id: UUID
    var name: String
    var address: String
    var port: UInt16
    var phase: RemoteHostStore.Phase
    /// Its last pushed state (kept while it is unreachable).
    var state: ShepherdState
    /// When the connection dropped, this launch.
    var lastSeen: Date?
}

/// One host's card.
struct HostsPageCard: Identifiable, Equatable {
    enum ID: Hashable {
        case local
        case remote(UUID)
    }

    var id: ID
    var name: String
    /// "Shepherd app · agent 0.8.2".
    var subtitle: String
    /// Appends "offline 3h", kept current by the card.
    var offlineSince: Date?
    /// "Connected", "Connecting", "Unreachable", "Token refused".
    var status: String
    var state: AgentState
    var facts: [NWHostFact]
    /// What a failed connection needs from you, when retrying alone won't fix it.
    var note: String?
    /// Neither connected nor connecting.
    var canRetry: Bool
    var canRemove: Bool
}

struct HostsPageModel: Equatable {
    var cards: [HostsPageCard] = []
    /// The cards `columns` to a row, as the grid lays them out.
    var rows: [[HostsPageCard]] = []
    /// "3 hosts · 1 offline".
    var subtitle = ""
    /// Remote hosts that are not connected (More ▸ Hosts' "1 offline").
    var offlineCount = 0

    /// `local` is this Mac's state; `agentVersion` is pi's version here, when known.
    static func make(local: ShepherdState, agentVersion: String?, remotes: [HostsPageRemote], columns: Int = 3,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> HostsPageModel {
        var model = HostsPageModel()
        model.cards.append(HostsPageCard(
            id: .local, name: PageHost.localName,
            subtitle: ["Shepherd app", agentVersion.map { "agent \($0)" }].compactMap { $0 }.joined(separator: " · "),
            offlineSince: nil, status: "Connected", state: .done, facts: connectedFacts(local, address: nil),
            note: nil, canRetry: false, canRemove: false))
        for remote in remotes {
            model.cards.append(card(remote, timeZone: timeZone, locale: locale))
        }
        model.rows = stride(from: 0, to: model.cards.count, by: max(1, columns)).map {
            Array(model.cards[$0..<min($0 + max(1, columns), model.cards.count)])
        }
        model.offlineCount = remotes.count { $0.phase != .connected }
        let hosts = model.cards.count
        model.subtitle = "\(hosts) host\(hosts == 1 ? "" : "s")"
            + (model.offlineCount > 0 ? " · \(model.offlineCount) offline" : "")
        return model
    }

    static func card(_ remote: HostsPageRemote, timeZone: TimeZone, locale: Locale) -> HostsPageCard {
        let address = "\(remote.address):\(remote.port)"
        let status: String, state: AgentState
        var note: String?
        switch remote.phase {
        case .connected: (status, state) = ("Connected", .done)
        case .connecting: (status, state) = ("Connecting", .running)
        case .disconnected: (status, state) = ("Not connected", .idle)
        case .failed(let failure):
            (status, state) = (failure.headline, .failed)
            // Unreachable says it all; a refused token or another version needs you.
            if !failure.retries { note = failure.message(host: remote.name) }
        }
        let connected = remote.phase == .connected
        let facts = connected ? connectedFacts(remote.state, address: address)
            : offlineFacts(remote.state, lastSeen: remote.lastSeen, address: address, timeZone: timeZone, locale: locale)
        let canRetry = !connected && remote.phase != .connecting
        return HostsPageCard(id: .remote(remote.id), name: remote.name, subtitle: "Shepherd app",
                             offlineSince: connected ? nil : remote.lastSeen, status: status, state: state, facts: facts,
                             note: note, canRetry: canRetry, canRemove: true)
    }

    /// Running threads, worktree threads, and the projects (spaces) there.
    static func connectedFacts(_ state: ShepherdState, address: String?) -> [NWHostFact] {
        var facts: [NWHostFact] = []
        let running = state.agents.count { $0.status == .working }
        facts.append(.init("Running", running == 0 ? "none" : count(running, "thread")))
        let worktrees = state.agents.count { $0.worktreeBranch != nil }
        if worktrees > 0 { facts.append(.init("Worktrees", "\(worktrees)")) }
        let repos = state.spaces.filter { !$0.hidden }.map(\.name)
        if !repos.isEmpty { facts.append(.init("Repos", repos.joined(separator: ", "))) }
        if let address { facts.append(.init("Address", address)) }
        return facts
    }

    /// What waits on an unreachable host (from its last pushed state), when it was last seen,
    /// and where it is.
    static func offlineFacts(_ state: ShepherdState, lastSeen: Date?, address: String, timeZone: TimeZone,
                             locale: Locale) -> [NWHostFact] {
        var facts: [NWHostFact] = []
        let hidden = Set(state.spaces.filter(\.hidden).map(\.id))
        let threads = state.agents.count { !hidden.contains($0.spaceID) }
        let waiting = [threads > 0 ? count(threads, "thread") : nil,
                       state.automations.isEmpty ? nil : count(state.automations.count, "automation")].compactMap { $0 }
        if !waiting.isEmpty { facts.append(.init("Waiting", waiting.joined(separator: ", "))) }
        if let lastSeen {
            facts.append(.init("Last seen", AutomationsModel.stamp(lastSeen, timeZone: timeZone, locale: locale)))
        }
        facts.append(.init("Address", address))
        return facts
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
