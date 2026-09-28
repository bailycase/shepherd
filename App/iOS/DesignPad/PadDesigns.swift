import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's designs on this device (docs/designs.md › Remote): each host's
/// `RemoteDesignLibrary` (shared with the iPhone's designs, `HostDesignLibraries`), connected
/// while its host is and offers `designs.v1` (the host's Design tool experiment on), and each
/// design's canvas, kept for the app's run so coming back to a design finds it as it was left.
/// A host that doesn't offer designs shows none: the iOS gate follows the host.
@MainActor
@Observable
final class PadDesigns {
    /// A design as the sidebar and the Designs list show it.
    struct Row: Identifiable, Equatable, Sendable {
        var ref: PadDesignRef
        var name: String
        /// "4 boards".
        var boards: String
        /// The design system's namespace; nil while it is drawn in none.
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

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let libraries: HostDesignLibraries
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

    static func forget(host: UUID, in hosts: MobileHosts) {
        guard let store = stores[ObjectIdentifier(hosts)] else { return }
        for ref in Array(store.canvases.keys) where ref.host == host {
            store.canvases.removeValue(forKey: ref)?.forget()
        }
        store.onScreen = store.onScreen.filter { $0.key.host != host }
        store.sessions.removeValue(forKey: host)
        store.rows.removeAll { $0.ref.host == host }
        store.available = hosts.hosts.contains { $0.id != host && $0.phase.isConnected && $0.supports(RemoteProtocol.designsCapability) }
        store.recentsCache = nil
        PadDesignRendering.shared.forget(host: host)
    }

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        libraries = HostDesignLibraries.of(hosts)
        libraries.observe("pad") { [weak self] host, design, revision, comments in
            self?.changed(PadDesignRef(host: host, design: design), revision: revision, comments: comments)
        }
        track()
    }

    // MARK: Hosts

    /// Reads the hosts under observation tracking, follows their connections and what they
    /// offer, and derives the rows when their state changed.
    private func track() {
        let inputs = withObservationTracking {
            hosts.hosts.filter { !libraries.cache.isForgotten(host: $0.id) }.map { host in
                Input(id: host.id, name: host.name, session: host.session, offers: host.phase.isConnected
                        && host.supports(RemoteProtocol.designsCapability),
                      designs: host.state.designs)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        let live = Set(inputs.map(\.id))
        for id in Set(sessions.keys).subtracting(live) {
            libraries.forget(id)
            Self.forget(host: id, in: hosts)
        }
        for input in inputs {
            if let host = hosts.host(input.id) { libraries.connect(host) }
            let connection = input.offers ? input.session : nil
            guard sessions[input.id] != .some(connection) else { continue }
            sessions[input.id] = connection
            if input.offers {
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
    }

    private func derive(_ inputs: [Input]) {
        var next: [Row] = []
        for input in inputs {
            guard input.offers else { continue }
            for design in input.designs where !design.buildsSystem {
                next.append(Row(ref: PadDesignRef(host: input.id, design: design.id), name: design.name,
                                boards: nativeCount(design.boardCount ?? 0, "board"), system: design.systemNamespace,
                                hostName: input.name, lastActive: design.lastActiveAt, agentID: design.agentID))
            }
        }
        next.sort { $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.name < $1.name }
        if next != rows { rows = next }
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

    func library(_ host: UUID) -> RemoteDesignLibrary { libraries.library(host) }

    // MARK: Canvases

    /// A design's canvas, made on first use and kept for the app's run.
    func canvas(_ ref: PadDesignRef) -> PadDesignCanvas {
        if let canvas = canvases[ref] { return canvas }
        let canvas = PadDesignCanvas(ref: ref, library: library(ref.host))
        if libraries.cache.isForgotten(host: ref.host) { canvas.forget() }
        else { canvases[ref] = canvas }
        return canvas
    }

    /// A design came on screen (in any window) or left it: only designs on screen take a live
    /// view, and their hosts push changes for them alone.
    func setVisible(_ ref: PadDesignRef, _ visible: Bool) {
        guard !libraries.cache.isForgotten(host: ref.host) else { return }
        let count = max(0, onScreen[ref, default: 0] + (visible ? 1 : -1))
        onScreen[ref] = count == 0 ? nil : count
        canvas(ref).setActive(count > 0)
        libraries.watch(Set(onScreen.keys.filter { $0.host == ref.host }.map(\.design)), on: ref.host, for: "pad")
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
        for (id, session) in sessions where session != nil {
            await library(id).refresh()
        }
    }
}

// MARK: Recents

/// A row of the iPad sidebar's Recents (iPadSidebar): a thread, or a design with its nib and
/// "4 boards" (`DesignRecents`).
typealias PadRecent = DesignRecents.Entry<PadDesigns.Row>

extension PadDesigns {
    /// Recents with the designs among the threads, derived once per change of either list. A
    /// design agent is never a thread (FleetModel); the row Fleet gives its design is the
    /// phone's, and here the design is this store's row (decision 6).
    func recents(_ threads: [FleetThreadRow]) -> [PadRecent] {
        let input = RecentsInput(threads: threads, designs: rows)
        if let cached = recentsCache, cached.input == input { return cached.output }
        let output = DesignRecents.merge(threads: threads.filter { $0.design == nil }, designs: rows) { $0.lastActive }
        recentsCache = (input, output)
        return output
    }

    struct RecentsInput: Equatable {
        var threads: [FleetThreadRow]
        var designs: [Row]
    }
}
