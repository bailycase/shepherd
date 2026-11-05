import SwiftUI
import ShepherdRemote

extension View {
    /// Hook: what the thread's terminals run, from its host, while the
    /// thread is on screen: the side pane's Terminal tab dot and the thread menu's "1 running".
    /// `ThreadScreen` applies it to its content.
    func watchesTerminals(_ ref: AgentRef) -> some View {
        modifier(TerminalActivityWatch(ref: ref))
    }
}

private struct TerminalActivityWatch: ViewModifier {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.scenePhase) private var scenePhase
    /// A thread kept mounted behind the selected one watches nothing.
    @Environment(\.threadDetailActive) private var active
    @State private var visible = false

    private struct Key: Equatable {
        var ref: AgentRef
        var session: UUID?
        var watching: Bool
        var hasTerminals: Bool
    }

    func body(content: Content) -> some View {
        let host = hosts.host(ref.host)
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: Key(ref: ref, session: host?.session, watching: visible && active && scenePhase == .active,
                          hasTerminals: MobileTerminals.hasTerminals(ref, host: host))) {
                guard visible, active, scenePhase == .active, let host, host.connectedClient != nil else { return }
                await MobileTerminals.shared.watchActivity(ref, host: host)
            }
    }
}

/// How many of a thread's terminals run a command now ("1 running").
@MainActor func runningTerminals(_ ref: AgentRef) -> Int {
    MobileTerminals.shared.activity[ref]?.values.filter(\.isRunning).count ?? 0
}
