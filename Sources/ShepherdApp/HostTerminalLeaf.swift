import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import SwiftUI

/// A terminal of the background host's thread in the app's own layout (`ShepherdViewModel.localHost`):
/// the host runs its shell, and the pane attaches to it. Showing it is the demand that starts a
/// restored shell, as `LiveTerminalPane`'s is.
struct HostTerminalLeaf: View {
    var vm: ShepherdViewModel
    let connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let pane: LeafPane
    let isFocused: Bool
    let isVisible: Bool
    var addToMessage: ((String) -> Void)? = nil

    var body: some View {
        let terminal = pane.sessionID.flatMap { id in vm.remoteHosts.paneSession(connection: connection, sessionID: id).map { (id: id, pane: $0) } }
        ZStack {
            if let terminal {
                RemoteTerminalPane(pane: terminal.pane, isFocused: isFocused, isRendering: isVisible,
                                   onFocusAcquired: { [vm, id = pane.id] in vm.focusedPaneID = id },
                                   addToMessage: addToMessage, local: true)
                    .id(terminal.id)
                    .onDisappear { [vm, connection] in vm.remoteHosts.closePane(connection: connection, sessionID: terminal.id) }
                    .transition(.identity)
            } else {
                PanePlaceholder(text: "starting shell…")
                    .shTransition(.content)
            }
        }
        .task(id: isVisible) {
            // The host keeps a shell that already runs; a restored one starts now.
            guard isVisible else { return }
            do { try await vm.remoteHosts.agentAction(ref, action: .startTerminal(paneID: pane.id)) }
            catch { vm.fail("Couldn’t start the terminal", error) }
        }
    }
}
