import SwiftUI
import ShepherdRemote

/// The app's open windows (iPadSplitView board). Each window has its own `MobileNavigator`;
/// everything else (the hosts and their one connection each, the thread stores, drafts,
/// appearance) is the app's and shared by every window.
///
/// The registry lets windows reach each other: "Open in new window" brings forward a window
/// already showing the thread, "Send to…" lists the threads other windows show, forgetting a
/// host closes its screens in every window, and the hosts stay connected while any window is
/// active.
@MainActor
@Observable
final class MobileWindows {
    struct Window {
        let seed: MobileWindowSeed
        let navigator: MobileNavigator
    }

    /// Open windows, in the order they opened.
    private(set) var open: [Window] = []
    /// Each window's scene phase: it moves the connections, never what a view draws.
    @ObservationIgnored private var phases: [UUID: WindowPhase] = [:]

    func register(_ seed: MobileWindowSeed, navigator: MobileNavigator) {
        if let index = open.firstIndex(where: { $0.seed.id == seed.id }) {
            if open[index].navigator !== navigator { open[index] = Window(seed: seed, navigator: navigator) }
        } else {
            open.append(Window(seed: seed, navigator: navigator))
        }
    }

    /// A window closed: the hosts disconnect once no open window is left in front.
    func unregister(_ id: UUID, hosts: MobileHosts) {
        guard open.contains(where: { $0.seed.id == id }) else { return }
        open.removeAll { $0.seed.id == id }
        phases[id] = nil
        apply(hosts)
    }

    /// A window's scene phase changed. Only the background drops the sockets (inactive includes
    /// system alerts and the app switcher), and only once every window is there.
    func setPhase(_ id: UUID, _ phase: ScenePhase, hosts: MobileHosts) {
        phases[id] = WindowPhase(phase)
        apply(hosts)
    }

    private func apply(_ hosts: MobileHosts) {
        let current = open.map { phases[$0.seed.id] ?? .inactive }
        if let foreground = WindowPresence.foreground(current) { hosts.setForeground(foreground) }
    }

    /// Closes a forgotten host's screens in every window.
    func forget(host: UUID) {
        for window in open { window.navigator.forget(host: host) }
    }

    /// The window other than `window` that shows `thread`, if one does.
    func window(showing thread: AgentRef, except window: UUID) -> MobileWindowSeed? {
        open.first { $0.seed.id != window && $0.navigator.selectedThread == thread }?.seed
    }

    /// The threads other windows show, for "Send to…": each once, never `source` itself.
    func targets(from window: UUID, excluding source: AgentRef?) -> [WindowTarget<AgentRef>] {
        WindowTargets.others(open.map { ($0.seed.id, $0.navigator.selectedThread) }, from: window, excluding: source)
    }

    func seed(_ id: UUID) -> MobileWindowSeed? {
        open.first { $0.seed.id == id }?.seed
    }
}

extension WindowPhase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}

extension EnvironmentValues {
    /// The window a view is in: its seed, for reaching it from another window.
    @Entry var mobileWindow = MobileWindowSeed.lone
}

extension FocusedValues {
    /// The focused window's navigator, for the app's keyboard commands (⌘K).
    @Entry var mobileNavigator: MobileNavigator?
}
