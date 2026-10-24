import Foundation
import Observation
import ShepherdCore
import ShepherdRemote

/// The Mac sidebar's thread groups on this device (docs/design/sidebar.md): Needs you, Working, Done, Pinned and Recents,
/// derived from Home's model by `FleetSidebarState`. Pins are this device's view state, as each Mac's are its own: kept in
/// its preferences (`shepherd.ios.sidebar.pinned`), never sent to a host, gone with their thread or host.
@MainActor
@Observable
final class SidebarThreads {
    private(set) var state: FleetSidebarState
    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let defaults: UserDefaults

    static let pinsKey = "shepherd.ios.sidebar.pinned"
    private static var stores: [ObjectIdentifier: SidebarThreads] = [:]

    /// The store of the app's hosts: one per `MobileHosts`, shared by every window, made on first use.
    static func of(_ hosts: MobileHosts) -> SidebarThreads {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = SidebarThreads(hosts: hosts, defaults: hosts.defaults)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    init(hosts: MobileHosts, defaults: UserDefaults) {
        self.hosts = hosts
        self.defaults = defaults
        let saved = (try? JSONDecoder().decode([FleetRef].self, from: defaults.data(forKey: Self.pinsKey) ?? Data())) ?? []
        state = FleetSidebarState(pins: saved)
        track()
    }

    /// Follows every host's state and connection; a pin goes only when its connected host lost the thread or the host
    /// was forgotten (`FleetSidebarState.reconcile`).
    private func track() {
        let (inputs, sessions) = withObservationTracking {
            (hosts.hosts.map { host in
                FleetHost(id: host.id, name: host.name, address: host.record.address, port: host.record.port,
                          phase: host.phase, state: host.state)
            }, Dictionary(hosts.hosts.compactMap { host in host.session.map { (host.id, $0) } }, uniquingKeysWith: { a, _ in a }))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        mutate { $0.reconcile(inputs, sessions: sessions) }
    }

    /// The groups for Home's model, derived once per change of either (as `PadDesigns.recents`), never per redraw.
    func groups(_ model: FleetModel) -> FleetSidebarGroups {
        if let cached = cache, cached.model == model, cached.state == state { return cached.groups }
        let groups = state.groups(model)
        cache = (model, state, groups)
        return groups
    }

    @ObservationIgnored private var cache: (model: FleetModel, state: FleetSidebarState, groups: FleetSidebarGroups)?

    func isPinned(_ ref: AgentRef) -> Bool { state.isPinned(Self.fleet(ref)) }

    func togglePin(_ ref: AgentRef) {
        let ref = Self.fleet(ref)
        mutate { state in
            if state.isPinned(ref) { state.unpin(ref) } else { state.pin(ref) }
        }
    }

    /// The window's thread on screen changed (`MobileNavigator.selectedThread`).
    func select(_ ref: AgentRef?) { mutate { $0.select(ref.map(Self.fleet)) } }

    func markSeen(_ rows: [FleetThreadRow]) { mutate { $0.markSeen(rows.map(\.ref)) } }

    private static func fleet(_ ref: AgentRef) -> FleetRef { FleetRef(host: ref.host, agent: ref.agent) }

    private func mutate(_ change: (inout FleetSidebarState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        if next.pins != state.pins { defaults.set(try? JSONEncoder().encode(next.pins), forKey: Self.pinsKey) }
        state = next
    }
}
