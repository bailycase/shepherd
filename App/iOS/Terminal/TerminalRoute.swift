import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The terminal's screens (terminal track).
enum TerminalRoute: Hashable, Codable {
    /// iPhone: a thread's terminal panes, full screen.
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
/// iPhone the panes open full screen.
@MainActor
enum TerminalHooks {
    static func toggle(thread: AgentRef, navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad:
            MobileTerminals.shared.update(thread) {
                $0.shown.toggle()
                if !$0.shown { $0.maximized = false }
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
                TerminalHooks.toggle(thread: thread, navigator: navigator)
            }
        }
    }
}

/// Hook (docs/ios/CONTRACTS.md): the iPad thread header's terminal toggle (iPadTerminal board),
/// filled while the panel is open.
struct TerminalToolbarButton: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let terminals = MobileTerminals.shared
        let shown = terminals.panel(thread).shown
        let news = !shown && TerminalModel.resolve(thread, hosts: hosts, terminals: terminals, onScreen: false).hasNews
        Button {
            TerminalHooks.toggle(thread: thread, navigator: navigator)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.nwIcon(isOn: shown))
        .overlay(alignment: .topTrailing) { NWToggleBadge(visible: news) }
        .disabled(!shown && hosts.host(thread.host)?.connectedClient == nil)
        .accessibilityLabel(shown ? "Hide terminal" : "Show terminal")
        .accessibilityValue(news ? "New output" : "")
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}
