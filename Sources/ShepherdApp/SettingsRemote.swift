import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// MARK: Remote hosts

/// Settings ▸ Remote: configured remote Shepherd hosts, and this Mac's own listener.
struct RemoteSettings: View {
    var vm: ShepherdViewModel
    var store: RemoteHostStore

    @State private var draftName = ""
    @State private var draftHost = ""
    @State private var draftPort = ""
    @State private var draftToken = ""
    /// Host being edited: the form saves over it instead of adding.
    @State private var editingID: UUID?

    private var draftValid: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftHost.trimmingCharacters(in: .whitespaces).isEmpty
            && RemotePortField.port(draftPort) != nil
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
                        .nwTransition(.list)
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
                    .nwTransition(.list)
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
                                      width: AppLayout.settingsPortFieldWidth, error: RemotePortField.problem(draftPort))
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
                            .nwTransition(.content)
                    }
                    Button(editingID == nil ? "Add host" : "Save") { save() }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .disabled(!draftValid)
                }
            }

            SettingsGroup(title: "Serve this Mac",
                          footnote: "Remote sessions run on the host Mac; your VPN is the transport and the token keeps other devices out.") {
                SettingsRow(title: "Listener", subtitle: vm.remoteListenerStatus, problem: vm.remoteListenerProblem,
                            problemHelp: vm.remoteListenerProblemDetail) {
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
        // Hosts arrive and leave as rows; the form swaps between adding and editing in place;
        // a bind failure discloses under the listener, and its status fades to the new port.
        .nwAnimation(.list, value: store.connections.map(\.id))
        .nwAnimation(.content, value: editingID)
        .nwAnimation(.disclosure, value: vm.remoteListenerProblem)
        .nwAnimation(.content, value: vm.remoteListenerStatus)
    }

    private func save() {
        guard let port = RemotePortField.port(draftPort) else { return }
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

/// The Add host form's port: digits from 1 to 65535. Anything else is refused under the field.
enum RemotePortField {
    static func port(_ text: String) -> UInt16? {
        UInt16(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 == 0 ? nil : $0 }
    }

    /// Why the typed port is refused; nil while it is empty or valid.
    static func problem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || port(trimmed) != nil ? nil : "Ports run from 1 to 65535."
    }
}

enum RemoteSettingsDefaults {
    /// 7433, or 7434 in Shepherd Nightly, so both apps can serve this Mac at once.
    static let port = ShepherdEdition.current.defaultRemoteListenerPort
}

/// Why the listener couldn't start, as Settings ▸ Remote says it: one plain sentence under the
/// Listener row, and the technical reason only as that line's tooltip.
struct RemoteListenerFailure: Equatable {
    let sentence: String
    let detail: String

    init(_ error: Error, port: UInt16) {
        sentence = Self.sentence(for: error, port: port)
        detail = String(describing: error)
    }

    static func sentence(for error: Error, port: UInt16) -> String {
        switch error {
        case SessionServerError.system(let call, let code) where call == "bind":
            switch code {
            case EADDRINUSE: return "Couldn't start: port \(port) is already in use."
            case EACCES: return "Couldn't start: port \(port) needs administrator rights."
            case EADDRNOTAVAIL: return "Couldn't start: this Mac has no network address to serve on."
            default: return "Couldn't start: this Mac didn't let Shepherd use port \(port)."
            }
        case SessionServerError.system(let call, _) where call == "chmod":
            return "Couldn't start: Shepherd couldn't protect its token file."
        case is CocoaError:
            return "Couldn't start: Shepherd couldn't read or write its token file."
        default:
            return "Couldn't start the listener."
        }
    }
}

/// "horizon" over "horizon.internal:7433 · connected · 5 agents", with Edit, Reconnect, Remove.
/// A failed connection's word says why ("unreachable", "token refused"), its sentence sits
/// under it as the row's problem, and the client's own reason is the problem's tooltip.
struct RemoteHostRow: View {
    var connection: RemoteHostStore.Connection
    let remove: () -> Void
    let reconnect: () -> Void
    let edit: () -> Void

    private var status: (word: String, state: AgentState) {
        switch connection.phase {
        case .connected: ("connected", .done)
        case .connecting: ("connecting…", .running)
        case .failed(let failure): (failure.headline.lowercased(), .failed)
        case .disconnected: ("disconnected", .idle)
        }
    }

    var body: some View {
        let config = connection.config
        let (word, state) = status
        let agents = connection.phase == .connected ? " · \(connection.state.agents.count) agents" : ""
        SettingsActionRow {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(config.name).font(.nw(.body, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                HStack(spacing: NW.Space.s) {
                    NWStatusDot(state)
                    // The address in mono; the rest in the description's Geist.
                    Text("\(Text(verbatim: "\(config.host):\(String(config.port))").font(.nwMono(AppLayout.settingsAddressSize)))\(Text(verbatim: " · "))\(Text(word).foregroundStyle(state.textColor))\(Text(agents))")
                        .foregroundStyle(Color.nw.textSecondary)
                        .nwText(size: NWTextStyle.ui.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .nwContentTransition(.crossFade)
                }
                // Connecting… → connected · 5 agents, or unreachable: the word and dot fade.
                .nwComponentAnimation(.content, value: state)
                if let failure = connection.phase.failure {
                    NWInlineProblem(failure.message(host: config.name), help: failure.detail)
                        .padding(.top, NW.Space.xs - NW.Space.xxs)
                }
            }
            // A new reason discloses under the status line and the row grows with it.
            .nwAnimation(.disclosure, value: connection.phase.failure?.kind)
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

extension RemoteHostStore.Phase {
    /// Why the connection failed, while it has.
    var failure: RemoteHostFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
