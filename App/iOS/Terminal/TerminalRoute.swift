import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The terminal's screens (terminal track).
enum TerminalRoute: Hashable, Codable {
    /// iPhone: a thread's terminals, full screen. (The case keeps its stored name, so a saved
    /// route still restores.)
    case panes(AgentRef)

    var thread: AgentRef {
        switch self {
        case .panes(let ref): ref
        }
    }
}

struct TerminalDestination: View {
    let route: TerminalRoute

    var body: some View {
        switch route {
        case .panes(let ref): TerminalScreen(ref: ref)
        }
    }
}

/// How the thread reaches its terminal: on iPad the panel under it opens and closes in place; on
/// iPhone the terminals open full screen. With no terminal yet, opening one makes one (on iPhone
/// the screen does it as it appears), so there is never an empty panel.
@MainActor
enum TerminalHooks {
    static func toggle(thread: AgentRef, navigator: MobileNavigator, hosts: MobileHosts) {
        switch navigator.layout {
        case .pad:
            let terminals = MobileTerminals.shared
            if terminals.panel(thread).shown {
                terminals.update(thread) { $0.shown = false; $0.maximized = false }
                return
            }
            let host = hosts.host(thread.host)
            guard let client = host?.connectedClient, let agent = host?.agent(thread.agent),
                  let layout = host?.state.tabs.first(where: { $0.id == agent.tabID })?.layout else {
                terminals.update(thread) { $0.shown = true }
                return
            }
            if TerminalPanel.tabs(in: layout, thread: agent.paneID).isEmpty, host?.supports(RemoteProtocol.paneControlCapability) == true {
                Task { await terminals.newTab(thread, layout: layout, thread: agent.paneID, client: client) }
            } else {
                terminals.update(thread) { $0.shown = true }
            }
        case .phone:
            navigator.open(.terminal(.panes(thread)))
        }
    }
}

/// Hook (docs/ios/CONTRACTS.md): the thread's options menu item. "Terminal" on iPhone; "Show
/// Terminal" or "Hide Terminal" on iPad. Absent while the host is offline.
struct TerminalMenuItems: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if hosts.host(thread.host)?.connectedClient != nil {
            let shown = navigator.layout == .pad && MobileTerminals.shared.panel(thread).shown
            Button(navigator.layout == .phone ? "Terminal" : shown ? "Hide Terminal" : "Show Terminal", systemImage: "terminal") {
                TerminalHooks.toggle(thread: thread, navigator: navigator, hosts: hosts)
            }
        }
    }
}

