import SwiftUI
import ShepherdRemote

extension View {
    /// Hook (docs/ios/CONTRACTS.md): what the thread's terminals run, from its host, while the
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
    @State private var visible = false

    private struct Key: Equatable {
        var session: UUID?
        var watching: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: Key(session: hosts.host(ref.host)?.session, watching: visible && scenePhase == .active)) {
                guard visible, scenePhase == .active, let client = hosts.host(ref.host)?.connectedClient else { return }
                await MobileTerminals.shared.watchActivity(ref, client: client)
            }
    }
}

/// How many of a thread's terminals run a command now ("1 running").
@MainActor func runningTerminals(_ ref: AgentRef) -> Int {
    MobileTerminals.shared.activity[ref]?.values.filter(\.isRunning).count ?? 0
}
