import SwiftUI
import ShepherdDesign
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
                    field("mac mini", text: $draftName)
                }
                SettingsRow(title: "Address", subtitle: "VPN-reachable IP or hostname.") {
                    field("100.x.y.z", text: $draftHost, mono: true)
                }
                SettingsRow(title: "Port") {
                    field(String(RemoteSettingsDefaults.port), text: $draftPort, mono: true, width: 100)
                        .onChange(of: draftPort) {
                            // Digits only: a pasted "7,433" must not silently become another port.
                            let digits = draftPort.filter(\.isNumber)
                            if digits != draftPort { draftPort = digits }
                        }
                }
                SettingsRow(title: "Token", subtitle: "Contents of the host's remote-token file.") {
                    SecureField("paste token", text: $draftToken)
                        .textFieldStyle(.plain)
                        .font(Fonts.code)
                        .shepherdField(mono: true)
                        .frame(width: 240)
                }
                HStack(spacing: 8) {
                    Spacer()
                    if editingID != nil {
                        Button("Cancel") { cancelEdit() }.buttonStyle(ShepherdButtonStyle(.ghost, size: .small))
                    }
                    Button(editingID == nil ? "Add host" : "Save") { save() }
                        .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                        .disabled(!draftValid)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: Metrics.settingsRowMinHeight)
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

    private func field(_ placeholder: String, text: Binding<String>, mono: Bool = false, width: CGFloat = 240) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(mono ? Fonts.code : Fonts.labelRegular)
            .shepherdField(mono: mono)
            .frame(width: width)
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

    private var status: (String, Color) {
        switch connection.phase {
        case .connected: ("connected", Tokens.successText)
        case .connecting: ("connecting…", Tokens.textTertiary)
        case .failed(let reason): ("unreachable · \(reason)", Tokens.dangerText)
        case .disconnected: ("disconnected", Tokens.textTertiary)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.config.name).font(Fonts.rowTitle).foregroundStyle(Tokens.text)
                let (word, color) = status
                (Text("\(connection.config.host):\(String(connection.config.port)) · ").foregroundStyle(Tokens.textTertiary)
                    + Text(word).foregroundStyle(color)
                    + Text(connection.phase == .connected ? " · \(connection.state.agents.count) agents" : "").foregroundStyle(Tokens.textTertiary))
                    .font(Fonts.micro)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Edit", action: edit).buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                Button("Reconnect", action: reconnect).buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                Button("Remove", action: remove).buttonStyle(ShepherdButtonStyle(.destructive, size: .small))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.settingsRowMinHeight)
    }
}
