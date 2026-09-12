import SwiftUI
import ShepherdCore
import ShepherdProtocol

// MARK: Remote hosts

/// Settings → Remote: configured remote Shepherd hosts, plus this Mac's own
/// listener token path for setting up the other side.
struct RemoteSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject var store: RemoteHostStore

    @State private var draftName = ""
    @State private var draftHost = ""
    @State private var draftPort = ""
    @State private var draftToken = ""
    /// Host being edited: the form saves over it instead of adding.
    @State private var editingID: UUID?

    private var draftValid: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftHost.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(draftPort.trimmingCharacters(in: .whitespaces)) != nil
            && !draftToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func cancelEdit() {
        editingID = nil
        draftName = ""; draftHost = ""; draftPort = ""; draftToken = ""
    }

    var body: some View {
        SettingsGroup(title: "Hosts") {
            if store.connections.isEmpty {
                SettingsRow(
                    title: "No remote hosts",
                    subtitle: "Add the Mac running Shepherd you want to reach. Its agents appear in the sidebar's REMOTE section.",
                    isFirst: true
                ) { EmptyView() }
            }
            ForEach(Array(store.connections.enumerated()), id: \.element.id) { index, connection in
                RemoteHostRow(
                    connection: connection,
                    isFirst: index == 0 && store.connections.isEmpty == false
                ) {
                    if editingID == connection.id { cancelEdit() }
                    store.removeHost(id: connection.id)
                } reconnect: {
                    store.reconnect(id: connection.id)
                } edit: {
                    let config = connection.config
                    editingID = config.id
                    draftName = config.name
                    draftHost = config.host
                    draftPort = String(config.port)
                    draftToken = config.token
                }
            }
        }

        SettingsGroup(title: editingID == nil ? "Add Host" : "Edit Host") {
            SettingsRow(title: "Name", subtitle: "Sidebar section label.", isFirst: true) {
                TextField("mac mini", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(width: 160)
            }
            SettingsRow(title: "Address", subtitle: "VPN-reachable IP or hostname.") {
                TextField("100.x.y.z", text: $draftHost)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(width: 160)
            }
            SettingsRow(title: "Port") {
                TextField(String(RemoteSettingsDefaults.port), text: $draftPort)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(width: 160)
                    .onChange(of: draftPort) {
                        // Digits only: a pasted "7,433" must not silently
                        // become an invalid (or worse, different) port.
                        let digits = draftPort.filter(\.isNumber)
                        if digits != draftPort { draftPort = digits }
                    }
            }
            SettingsRow(title: "Token", subtitle: "Contents of the host's remote-token file.") {
                SecureField("", text: $draftToken)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(width: 160)
            }
            SettingsRow(title: "") {
                HStack(spacing: 8) {
                    if editingID != nil {
                        Button("Cancel") { cancelEdit() }
                    }
                    Button(editingID == nil ? "Add Host" : "Save") {
                        guard let port = UInt16(draftPort.trimmingCharacters(in: .whitespaces)) else { return }
                        let name = draftName.trimmingCharacters(in: .whitespaces)
                        let host = draftHost.trimmingCharacters(in: .whitespaces)
                        let token = draftToken.trimmingCharacters(in: .whitespaces)
                        if let id = editingID {
                            store.updateHost(id: id, name: name, host: host, port: port, token: token)
                        } else {
                            store.addHost(name: name, host: host, port: port, token: token)
                        }
                        cancelEdit()
                    }
                    .disabled(!draftValid)
                }
            }
        }

        SettingsGroup(title: "Serve This Mac") {
            SettingsRow(
                title: "Listener",
                subtitle: vm.remoteListenerStatus,
                isFirst: true
            ) {
                Toggle("", isOn: Binding(
                    get: { vm.remoteListenerEnabled },
                    set: { vm.setRemoteListenerEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            PathRow(
                title: "Token",
                subtitle: "Paste this file's contents into the other Mac's Token field. Delete it to revoke every client.",
                url: ShepherdPaths.remoteTokenURL()
            )
        }
        SettingsNote(text: "remote sessions run on the host Mac · your VPN is the transport; the token keeps other devices on it honest")
    }
}

enum RemoteSettingsDefaults {
    static let port: UInt16 = 7433
}

private struct RemoteHostRow: View {
    @ObservedObject var connection: RemoteHostStore.Connection
    var isFirst: Bool
    let remove: () -> Void
    let reconnect: () -> Void
    let edit: () -> Void

    private var statusText: String {
        switch connection.phase {
        case .connected: return "connected · \(connection.state.agents.count) agents"
        case .connecting: return "connecting…"
        case .failed(let reason): return "unreachable · \(reason)"
        case .disconnected: return "disconnected"
        }
    }

    var body: some View {
        SettingsRow(
            title: "\(connection.config.name) — \(connection.config.host):\(String(connection.config.port))",
            subtitle: statusText,
            isFirst: isFirst
        ) {
            HStack(spacing: 8) {
                Button("Edit", action: edit)
                Button("Reconnect", action: reconnect)
                Button(role: .destructive, action: remove) {
                    Text("Remove").foregroundStyle(Tokens.destructive)
                }
            }
        }
    }
}
