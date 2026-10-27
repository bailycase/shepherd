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
                     explanation: "Connect to agents on other Macs over your VPN, or let other Macs and Shepherd on your iPhone or iPad connect to this one.") {
            SettingsGroup(title: "Hosts") {
                if store.connections.isEmpty {
                    SettingsRow(title: "No remote hosts",
                                subtitle: "Add a Mac running Shepherd below. Its agents appear in the sidebar under its name.") { EmptyView() }
                        .shTransition(.list)
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
                    .shTransition(.list)
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
                        Button("Cancel") { cancelEdit() }.buttonStyle(.sh(.ghost, size: .s))
                            .shTransition(.content)
                    }
                    Button(editingID == nil ? "Add host" : "Save") { save() }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .disabled(!draftValid)
                }
            }

            SettingsGroup(title: "Serve this Mac",
                          footnote: "Remote sessions run on the host Mac; your VPN is the transport and the token keeps other devices out. "
                              + "The iPhone and iPad app pairs the same way: Settings ▸ Hosts ▸ Add host there takes this Mac's address, port and token.") {
                SettingsRow(title: "Listener", subtitle: vm.remoteListenerStatus, problem: vm.remoteListenerProblem,
                            problemHelp: vm.remoteListenerProblemDetail) {
                    SettingsSwitch(label: "Listener", isOn: Binding(
                        get: { vm.remoteListenerEnabled },
                        set: { vm.setRemoteListenerEnabled($0) }
                    ))
                }
                PathRow(title: "Token",
                        subtitle: "Paste this into the other Mac's, iPhone's or iPad's Token field. To revoke every client, delete the file and turn the listener off and on.",
                        url: ShepherdPaths.remoteTokenURL())
            }
        }
        // Hosts arrive and leave as rows; the form swaps between adding and editing in place;
        // a bind failure discloses under the listener, and its status fades to the new port.
        .shAnimation(.list, value: store.connections.map(\.id))
        .shAnimation(.content, value: editingID)
        .shAnimation(.disclosure, value: vm.remoteListenerProblem)
        .shAnimation(.content, value: vm.remoteListenerStatus)
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

/// "horizon" over "horizon.internal:7433 · connected · 5 agents" (the word in its state's text
/// color), with Edit, Reconnect, Remove.
/// A failed connection's word says why ("unreachable", "token refused"), its sentence sits
/// under it as the row's problem, and the client's own reason is the problem's tooltip.
/// When the host supports updates, shows version and update status underneath.
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
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(config.name).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                // The address in mono, then the connection's word in its state's color (no dot, as
                // SettingsRemote draws it); the rest in the description's Geist.
                Group {
                    Text("\(Text(verbatim: "\(config.host):\(String(config.port))").font(.shMono(AppLayout.settingsAddressSize)))\(Text(verbatim: " · "))\(Text(word).foregroundStyle(state.textColor))\(Text(agents))")
                        .foregroundStyle(Color.sh.textSecondary)
                        .shText(size: SHTextStyle.ui.size, lineHeight: SHCardRowMetrics.settingsDescriptionLineHeight)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shContentTransition(.crossFade)
                }
                // Connecting… → connected · 5 agents, or unreachable: the words fade.
                .shComponentAnimation(.content, value: state)
                if let failure = connection.phase.failure {
                    SHInlineProblem(failure.message(host: config.name), help: failure.detail)
                        .padding(.top, SH.Space.xs - SH.Space.xxs)
                }
                if connection.supportsHostUpdate, connection.phase == .connected {
                    RemoteHostUpdateRow(connection: connection)
                        .padding(.top, SH.Space.xs)
                }
            }
            // A new reason discloses under the status line and the row grows with it.
            .shAnimation(.disclosure, value: connection.phase.failure?.kind)
            .accessibilityElement(children: .combine)
        } actions: {
            Button("Edit", action: edit).buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Edit \(config.name)")
            Button("Reconnect", action: reconnect).buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Reconnect \(config.name)")
            Button("Remove", action: remove).buttonStyle(.sh(.danger, size: .s))
                .accessibilityLabel("Remove \(config.name)")
        }
    }
}

/// The display content of an update row: version line, status, action buttons. Shared between
/// the live `RemoteHostUpdateRow` (which polls) and preview fixtures (which supply fixed data).
struct HostUpdateContent: View {
    let hostName: String
    let status: HostUpdateStatus?
    var polling: Bool = false
    var error: String? = nil
    var onCheck: (() -> Void)? = nil
    var onInstall: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            if let status {
                HStack(spacing: SH.Space.s) {
                    Text(HostSettingsPresentation.versionLine(status))
                        .font(.shMono(AppLayout.settingsAddressSize))
                        .foregroundStyle(Color.sh.textSecondary)
                    Text("·").foregroundStyle(Color.sh.textTertiary)
                    Text(HostSettingsPresentation.updateSummary(status))
                        .foregroundStyle(HostSettingsPresentation.updateTone(status).agentState.textColor)
                    if polling { ProgressView().controlSize(.small) }
                }
                .font(.sh(.ui))
                .lineLimit(1)
                HStack(spacing: SH.Space.s) {
                    if HostSettingsPresentation.canCheck(status) {
                        Button("Check for update") { onCheck?() }
                            .buttonStyle(.sh(.ghost, size: .s))
                            .disabled(polling)
                    }
                    if HostSettingsPresentation.canInstall(status) {
                        Button("Update and restart\u{2026}") { confirmingInstall = true }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .disabled(polling)
                    }
                    if let reason = HostSettingsPresentation.installBlockReason(status) {
                        Text(reason).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
            } else {
                HStack(spacing: SH.Space.s) {
                    if polling {
                        ProgressView().controlSize(.small)
                        Text("Checking update status\u{2026}")
                    } else {
                        Text("Update status unavailable.")
                        Button("Retry") { onRetry?() }
                            .buttonStyle(.sh(.ghost, size: .s))
                    }
                }
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
            }
            if let error {
                SHInlineProblem(error)
                    .padding(.top, SH.Space.xxs)
            }
        }
        .confirmationDialog(
            "Update and restart \(hostName)?",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button("Update and restart", role: .destructive) { onInstall?() }
        } message: {
            Text(HostSettingsPresentation.installConfirmation(host: hostName))
        }
    }
}

/// Update status for a connected remote host. Polls `.status` with bounded retries while
/// the phase is transient. Never automatically retries `.check` or `.install`.
struct RemoteHostUpdateRow: View {
    let connection: RemoteHostStore.Connection
    @State private var status: HostUpdateStatus?
    @State private var polling = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    private static let terminalPhases: Set<HostUpdateStatus.Phase> =
        [.idle, .upToDate, .available, .failed, .unsupported]
    // ponytail: 12 polls × 3s = 36s max wait; raise if downloads are slower.
    private static let maxPolls = 12
    private static let pollInterval: Duration = .seconds(3)

    var body: some View {
        HostUpdateContent(
            hostName: connection.config.name,
            status: status,
            polling: polling,
            error: error,
            onCheck: { Task { await check() } },
            onInstall: { Task { await install() } },
            onRetry: { Task { await fetchStatus() } }
        )
        .task { await fetchStatus() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    // MARK: Actions

    /// One-shot fetch on appear or retry.
    private func fetchStatus() async {
        guard let client = connection.updateClient else { return }
        polling = true
        defer { polling = false }
        do {
            let s = try await client.hostUpdate(.status)
            status = s
            error = nil
            if !Self.terminalPhases.contains(s.phase) { startPolling() }
        } catch {
            self.error = "Couldn't read update status."
        }
    }

    /// Ask the host to check for an update, then poll until it resolves.
    private func check() async {
        guard let client = connection.updateClient else { return }
        polling = true
        do {
            status = try await client.hostUpdate(.check)
            error = nil
            startPolling()
        } catch {
            self.error = "Couldn't check for updates."
            polling = false
        }
    }

    /// Authorize install. The host downloads, verifies and restarts; the connection will drop.
    private func install() async {
        guard let client = connection.updateClient,
              let status, let offerID = status.offerID else { return }
        polling = true
        error = nil
        do {
            self.status = try await client.hostUpdate(.install(offerID: offerID, authorized: true))
            startPolling()
        } catch {
            if Self.isConnectionLoss(error) {
                self.error = "Connection lost during update. Reconnect to verify whether it succeeded."
            } else {
                self.error = "Update failed: \(error.localizedDescription)"
            }
            polling = false
        }
    }

    private static func isConnectionLoss(_ error: any Error) -> Bool {
        guard let e = error as? RemoteHostClientError else { return false }
        switch e {
        case .outcomeUnknown, .disconnected, .timeout: return true
        default: return false
        }
    }

    // MARK: Bounded polling

    /// Polls `.status` at a fixed interval until the phase is terminal or the budget is spent.
    /// Cancelled on disappear and by a new action.
    private func startPolling() {
        pollTask?.cancel()
        let connection = connection
        pollTask = Task {
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let client = connection.updateClient else { return }
                do {
                    let s = try await client.hostUpdate(.status)
                    status = s
                    error = nil
                    if Self.terminalPhases.contains(s.phase) { break }
                } catch {
                    break
                }
            }
            polling = false
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

extension HostSettingsPresentation.UpdateTone {
    var agentState: AgentState {
        switch self {
        case .idle: return .idle
        case .running: return .running
        case .attention: return .attention
        case .failed: return .failed
        }
    }
}
