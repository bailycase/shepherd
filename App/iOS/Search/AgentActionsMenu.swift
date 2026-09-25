import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The agent actions in a thread's options menu (search track): Rename, Move up and down within
/// its group, and Delete (a worktree agent's delete confirms on its own sheet, as the Mac's
/// Delete Worktree Agent). Menu items only; the thread's menu holds them. Each is offered only
/// while the host is connected and new enough to do it.
struct AgentActionsMenu: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let host = hosts.host(thread.host), let agent = host.agent(thread.agent) {
            let actions = ThreadActions(ref: thread, agent: agent, host: host)
            Section {
                Button("Rename…", systemImage: "pencil") { navigator.present(.search(.rename(thread))) }
                    .disabled(!actions.canRename)
                if actions.canMoveUp || actions.canMoveDown {
                    Button("Move up", systemImage: "arrow.up") { move(.up) }
                        .disabled(!actions.canMoveUp)
                    Button("Move down", systemImage: "arrow.down") { move(.down) }
                        .disabled(!actions.canMoveDown)
                }
            }
            Section {
                Button(actions.worktree ? "Delete worktree agent…" : "Delete agent…", systemImage: "trash", role: .destructive) {
                    navigator.present(.search(.delete(thread)))
                }
                .disabled(!actions.canDelete)
            }
        }
    }

    private func move(_ direction: AgentReorder.Direction) {
        let ref = thread
        let hosts = hosts
        AgentActions.run("Couldn’t move the thread", navigator: navigator) {
            try await AgentActions.move(ref, direction, hosts: hosts)
        }
    }
}
