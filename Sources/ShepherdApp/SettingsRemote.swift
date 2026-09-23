import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol

// MARK: Remote hosts

/// Settings ▸ Remote: configured remote Shepherd hosts, and this Mac's own listener.
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
        SettingsPage(title: "Remote",
                     explanation: "Connect to agents on other Macs over your VPN, or let other Macs connect to this one.") {
            SettingsGroup(title: "Hosts") {
                if store.connections.isEmpty {
                    SettingsRow(title: "No remote hosts",
                                subtitle: "Add a Mac running Shepherd below. Its agents appear in the sidebar under its name.") { EmptyView() }
                }
                ForEach(store.connections, id: \.id) { connection in
                    RemoteHostRow(connection: connection) {
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

            SettingsGroup(title: editingID == nil ? "Add host" : "Edit host") {
                SettingsRow(title: "Name", subtitle: "Shown as the sidebar section label.") {
                    SettingsTextField(label: "Name", prompt: "mac mini", text: $draftName)
                }
                SettingsRow(title: "Address", subtitle: "VPN-reachable IP or hostname.") {
                    SettingsTextField(label: "Address", prompt: "100.x.y.z", text: $draftHost, mono: true)
                }
                SettingsRow(title: "Port") {
                    SettingsTextField(label: "Port", prompt: String(RemoteSettingsDefaults.port), text: $draftPort, mono: true,
                                      width: AppLayout.settingsPortFieldWidth)
                        .onChange(of: draftPort) {
                            // Digits only: a pasted "7,433" must not silently become another port.
                            let digits = draftPort.filter(\.isNumber)
                            if digits != draftPort { draftPort = digits }
                        }
                }
                SettingsRow(title: "Token", subtitle: "Contents of the host's remote-token file.") {
                    SettingsTextField(label: "Token", prompt: "paste token", text: $draftToken, mono: true, secure: true)
                }
                SettingsActionRow {
                    if editingID != nil {
                        Button("Cancel") { cancelEdit() }.buttonStyle(.nw(.ghost, size: .s))
                    }
                    Button(editingID == nil ? "Add host" : "Save") { save() }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .disabled(!draftValid)
                }
            }

            SettingsGroup(title: "Serve this Mac",
                          footnote: "Remote sessions run on the host Mac; your VPN is the transport and the token keeps other devices out.") {
                SettingsRow(title: "Listener", subtitle: vm.remoteListenerStatus, problem: vm.remoteListenerProblem) {
                    SettingsSwitch(label: "Listener", isOn: Binding(
                        get: { vm.remoteListenerEnabled },
                        set: { vm.setRemoteListenerEnabled($0) }
                    ))
                }
                PathRow(title: "Token",
                        subtitle: "Paste this into the other Mac's Token field. To revoke every client, delete the file and turn the listener off and on.",
                        url: ShepherdPaths.remoteTokenURL())
            }
        }
    }

    private func save() {
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
}

enum RemoteSettingsDefaults {
    static let port: UInt16 = 7433
}

/// "horizon" over "horizon.internal:7433 · connected · 5 agents", with Edit, Reconnect, Remove.
private struct RemoteHostRow: View {
    @ObservedObject var connection: RemoteHostStore.Connection
    let remove: () -> Void
    let reconnect: () -> Void
    let edit: () -> Void

    private var status: (word: String, state: AgentState) {
        switch connection.phase {
        case .connected: ("connected", .done)
        case .connecting: ("connecting…", .running)
        case .failed(let reason): ("unreachable · \(reason)", .failed)
        case .disconnected: ("disconnected", .idle)
        }
    }

    var body: some View {
        let config = connection.config
        let (word, state) = status
        let agents = connection.phase == .connected ? " · \(connection.state.agents.count) agents" : ""
        SettingsActionRow {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(config.name).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                HStack(spacing: NW.Space.s) {
                    NWStatusDot(state)
                    Text("\(Text("\(config.host):\(String(config.port)) · ").foregroundStyle(Color.nw.textSecondary))\(Text(word).foregroundStyle(state.textColor))\(Text(agents).foregroundStyle(Color.nw.textSecondary))")
                        .font(.nw(.mono))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button("Edit", action: edit).buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Edit \(config.name)")
            Button("Reconnect", action: reconnect).buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Reconnect \(config.name)")
            Button("Remove", action: remove).buttonStyle(.nw(.danger, size: .s))
                .accessibilityLabel("Remove \(config.name)")
        }
    }
}
