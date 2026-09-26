import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's designs on this device (docs/designs.md › Remote): one `RemoteDesignLibrary` per
/// host over one shared file cache, connected while its host is and offers `designs.v1` (the
/// host's Design tool experiment on), and each design's canvas, kept for the app's run so coming
/// back to a design finds it as it was left. A host that doesn't offer designs shows none: the
/// iOS gate follows the host.
@MainActor
@Observable
final class PadDesigns {
    /// A design as the sidebar and the Designs list show it.
    struct Row: Identifiable, Equatable, Sendable {
        var ref: PadDesignRef
        var name: String
        /// "4 boards".
        var boards: String
        /// The design system's namespace, or the project's name.
        var system: String?
        var hostName: String
        var lastActive: Double
        var agentID: AgentID?

        var id: PadDesignRef { ref }
    }

    /// Designs across every host that offers them, most recently active first.
    private(set) var rows: [Row] = []
    /// Some connected host offers designs: the sidebar's Designs row shows.
    private(set) var available = false
    /// The design agents' threads, never listed among the threads (the design is the row).
    private(set) var designAgents: Set<AgentRef> = []

    @ObservationIgnored let cache: RemoteDesignCache
    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private var libraries: [UUID: RemoteDesignLibrary] = [:]
    @ObservationIgnored private var sessions: [UUID: UUID?] = [:]
    @ObservationIgnored private var canvases: [PadDesignRef: PadDesignCanvas] = [:]
    /// Designs on screen, by host: their hosts push changes for these alone.
    @ObservationIgnored private var onScreen: [PadDesignRef: Int] = [:]
    /// The sidebar's Recents as last merged (`recents`).
    @ObservationIgnored var recentsCache: (input: RecentsInput, output: [PadRecent])?

    private static var stores: [ObjectIdentifier: PadDesigns] = [:]

    /// The designs of the app's hosts: one store per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> PadDesigns {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = PadDesigns(hosts: hosts)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ShepherdDesigns", isDirectory: true)
        cache = RemoteDesignCache(directory: folder, memoryBudget: 48 * 1024 * 1024)
        track()
    }

    // MARK: Hosts

    /// Reads the hosts under observation tracking, follows their connections and what they
    /// offer, and derives the rows when their state changed.
    private func track() {
        let inputs = withObservationTracking {
            hosts.hosts.map { host in
                Input(id: host.id, name: host.name, session: host.session, offers: host.phase.isConnected
                        && host.supports(RemoteProtocol.designsCapability),
                      designs: host.state.designs, agents: host.state.agents.compactMap { agent in agent.designID.map { (agent.id, $0) } })
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        let live = Set(inputs.map(\.id))
        for id in Set(libraries.keys).subtracting(live) {
            libraries.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
        }
        for input in inputs {
            let library = library(input.id)
            let connection = input.offers ? input.session : nil
            guard sessions[input.id] != .some(connection) else { continue }
            sessions[input.id] = connection
            let host = hosts.host(input.id)
            library.connect(input.offers ? host?.connectedClient : nil, available: input.offers)
            if input.offers {
                host?.onDesignChanged = { [weak self] design, revision, comments in
                    self?.changed(PadDesignRef(host: input.id, design: design), revision: revision, comments: comments)
                }
                // A new connection: canvases on screen read what changed while it was away.
                for ref in canvases.keys where ref.host == input.id && onScreen[ref, default: 0] > 0 {
                    Task { await canvases[ref]?.refresh() }
                }
            }
        }
        derive(inputs)
    }

    private struct Input {
        var id: UUID
        var name: String
        var session: UUID?
        var offers: Bool
        var designs: [Design]
        var agents: [(AgentID, DesignID)]
    }

    private func derive(_ inputs: [Input]) {
        var next: [Row] = []
        var agents: Set<AgentRef> = []
        for input in inputs {
            // A host's design agents are its designs' chats wherever the host serves them or not.
            for (agent, _) in input.agents { agents.insert(AgentRef(host: input.id, agent: agent)) }
            guard input.offers else { continue }
            for design in input.designs where !design.buildsSystem {
                next.append(Row(ref: PadDesignRef(host: input.id, design: design.id), name: design.name,
                                boards: nativeCount(design.boardCount ?? 0, "board"), system: design.systemNamespace,
                                hostName: input.name, lastActive: design.lastActiveAt, agentID: design.agentID))
            }
        }
        next.sort { $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.name < $1.name }
        if next != rows { rows = next }
        if agents != designAgents { designAgents = agents }
        let offers = inputs.contains(where: \.offers)
        if offers != available { available = offers }
        PadDesignRendering.shared.prune(keeping: Set(next.map(\.ref)).union(canvases.keys.filter { onScreen[$0, default: 0] > 0 }))
    }

    /// The design's row, while its host serves it.
    func row(_ ref: PadDesignRef) -> Row? { rows.first { $0.ref == ref } }

    /// The design as its host's state has it.
    func design(_ ref: PadDesignRef) -> Design? {
        hosts.host(ref.host)?.state.designs.first { $0.id == ref.design }
    }

    func library(_ host: UUID) -> RemoteDesignLibrary {
        if let library = libraries[host] { return library }
        let library = RemoteDesignLibrary(hostID: host, cache: cache)
        libraries[host] = library
        return library
    }

    // MARK: Canvases

    /// A design's canvas, made on first use and kept for the app's run.
    func canvas(_ ref: PadDesignRef) -> PadDesignCanvas {
        if let canvas = canvases[ref] { return canvas }
        let canvas = PadDesignCanvas(ref: ref, library: library(ref.host))
        canvases[ref] = canvas
        return canvas
    }

    /// A design came on screen (in any window) or left it: only designs on screen take a live
    /// view, and their hosts push changes for them alone.
    func setVisible(_ ref: PadDesignRef, _ visible: Bool) {
        let count = max(0, onScreen[ref, default: 0] + (visible ? 1 : -1))
        onScreen[ref] = count == 0 ? nil : count
        canvas(ref).setActive(count > 0)
        library(ref.host).watch(Set(onScreen.keys.filter { $0.host == ref.host }.map(\.design)))
    }

    /// The host pushed a change to a design on screen: its canvas pulls what changed.
    private func changed(_ ref: PadDesignRef, revision: UInt64?, comments: UInt64?) {
        guard let canvas = canvases[ref] else { return }
        Task {
            if revision == nil, comments != nil { await canvas.refreshComments() } else { await canvas.refresh() }
        }
    }

    /// Lists every serving host's designs again (the Designs list's pull).
    func refresh() async {
        for (id, library) in libraries {
            guard case .some(.some) = sessions[id] else { continue }
            await library.refresh()
        }
    }
}

// MARK: Recents

/// A row of the iPad sidebar's Recents (iPadSidebar): a thread, or a design with its nib and
/// "4 boards" (`DesignRecents`).
typealias PadRecent = DesignRecents.Entry<PadDesigns.Row>

extension PadDesigns {
    /// Recents with the designs among the threads, derived once per change of either list. A
    /// design agent's thread is never listed: the design is its row (decision 6).
    func recents(_ threads: [FleetThreadRow]) -> [PadRecent] {
        let input = RecentsInput(threads: threads, designs: rows, agents: designAgents)
        if let cached = recentsCache, cached.input == input { return cached.output }
        let output = DesignRecents.merge(threads: threads.filter { !designAgents.contains($0.ref.agentRef) }, designs: rows) { $0.lastActive }
        recentsCache = (input, output)
        return output
    }

    struct RecentsInput: Equatable {
        var threads: [FleetThreadRow]
        var designs: [Row]
        var agents: Set<AgentRef>
    }
}
