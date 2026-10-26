import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A host's form (home track): name, address, port and token; Forget for a saved host. The
/// token goes to the Keychain; a blank token field keeps the saved one.
/// When the host supports updates, shows version and update status with Check / Update actions.
struct HostEditorScreen: View {
    let hostID: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.mobileApp) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var address = ""
    @State private var port = String(RemoteHostRecord.defaultPort)
    @State private var token = ""
    @State private var hasToken = false
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let host = hostID.flatMap(hosts.host) {
                Section {
                    LabeledContent("Connection") {
                        SHStatusPill(host.phase.isConnected ? .done : host.phase == .connecting ? .running : .failed,
                                     label: host.phase.word)
                    }
                    if let failure = host.phase.failure {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(failure.message(host: host.name)).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                            Text(failure.detail).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                    if !host.phase.isConnected {
                        Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(host.id) }
                    }
                }
                if host.phase.isConnected, host.supports(RemoteProtocol.hostUpdateCapability) {
                    MobileHostUpdateSection(host: host)
                } else if host.phase.isConnected {
                    Section {
                        Text("Update Shepherd on \(host.name) to manage updates here.")
                            .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
            }
            Section {
                LabeledContent("Name") {
                    TextField("My Mac", text: $name).multilineTextAlignment(.trailing)
                }
                LabeledContent("Address") {
                    TextField("hostname or IP", text: $address)
                        .keyboardType(.URL).font(.sh(.mono)).multilineTextAlignment(.trailing)
                }
                LabeledContent("Port") {
                    TextField(String(RemoteHostRecord.defaultPort), text: $port)
                        .keyboardType(.numberPad).font(.sh(.mono)).multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField(hasToken ? "Saved" : "Required", text: $token)
                        .privacySensitive().font(.sh(.mono)).multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Turn on Settings ▸ Remote ▸ Serve this Mac in Shepherd on the host and copy its token. Use a trusted LAN or VPN: there is no TLS.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if hostID != nil {
                Section {
                    Button("Forget host", role: .destructive) { confirmingForget = true }
                }
            }
        }
        .listRowBackground(Color.sh.bgRaised)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.sh(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle(hostID == nil ? "Add host" : "Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented from Home or More, the form is a sheet's root and needs its own way out.
            if navigator.presented?.route == .settings(.host(hostID)) {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .alert("Could not save the host", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Forget this host and delete its token?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget host", role: .destructive, action: forget)
        }
        .onAppear(perform: load)
        .onDisappear { token = "" }
    }

    private func load() {
        guard let id = hostID, let host = hosts.host(id) else { return }
        name = host.record.name
        address = host.record.address
        port = String(host.record.port)
        hasToken = (try? hosts.token(for: id))??.isEmpty == false
    }

    private func save() {
        do {
            let entry = try RemoteHostEntry(name: name, address: address, port: port, token: token, requireToken: hostID == nil || !hasToken)
            if let id = hostID { try hosts.edit(id, entry) } else { try hosts.add(entry) }
            token = ""
            dismiss()
        } catch let problem as RemoteHostEntry.Problem {
            error = problem.description
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forget() {
        guard let id = hostID else { return }
        do {
            try app?.forget(host: id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Update section

/// Version and update status for a connected host that supports `host.update.v1`.
/// Polls `.status` with bounded retries while the phase is transient. Never automatically
/// retries `.check` or `.install`.
private struct MobileHostUpdateSection: View {
    let host: MobileHost
    @State private var status: HostUpdateStatus?
    @State private var polling = false
    @State private var error: String?
    @State private var confirmingInstall = false
    @State private var pollTask: Task<Void, Never>?

    private static let terminalPhases: Set<HostUpdateStatus.Phase> =
        [.idle, .upToDate, .available, .failed, .unsupported]
    // ponytail: 12 polls × 3s = 36s max wait; raise if downloads are slower.
    private static let maxPolls = 12
    private static let pollInterval: Duration = .seconds(3)

    var body: some View {
        Section {
            if let status {
                LabeledContent("Version") {
                    Text(HostSettingsPresentation.versionLine(status))
                        .font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: SH.Space.xs) {
                        Text(HostSettingsPresentation.updateSummary(status))
                            .foregroundStyle(Self.toneColor(status))
                        if polling { ProgressView().controlSize(.small) }
                    }
                    .font(.sh(.ui))
                }
                if HostSettingsPresentation.canCheck(status) {
                    Button("Check for update") { Task { await check() } }
                        .disabled(polling)
                }
                if HostSettingsPresentation.canInstall(status) {
                    Button("Update and restart\u{2026}") { confirmingInstall = true }
                        .disabled(polling)
                }
                if let reason = HostSettingsPresentation.installBlockReason(status) {
                    Text(reason).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            } else {
                HStack(spacing: SH.Space.s) {
                    if polling {
                        ProgressView().controlSize(.small)
                        Text("Checking update status\u{2026}")
                    } else {
                        Text("Update status unavailable.")
                        Button("Retry") { Task { await fetchStatus() } }
                    }
                }
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if let error {
                Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
            }
        } header: {
            Text("Software Update")
        } footer: {
            if status?.phase == .available {
                Text("Updating downloads, verifies and installs the update, then restarts Shepherd on \(host.name). All connected clients disconnect while it restarts.")
                    .font(.sh(.caption))
            }
        }
        .confirmationDialog(
            "Update and restart \(host.name)?",
            isPresented: $confirmingInstall,
            titleVisibility: .visible
        ) {
            Button("Update and restart", role: .destructive) { Task { await install() } }
        } message: {
            Text(HostSettingsPresentation.installConfirmation(host: host.name))
        }
        .task { await fetchStatus() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    @MainActor private static func toneColor(_ status: HostUpdateStatus) -> Color {
        switch HostSettingsPresentation.updateTone(status) {
        case .idle: return AgentState.idle.textColor
        case .running: return AgentState.running.textColor
        case .attention: return AgentState.attention.textColor
        case .failed: return AgentState.failed.textColor
        }
    }

    // MARK: Actions

    private func fetchStatus() async {
        guard let client = host.connectedClient else { return }
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

    private func check() async {
        guard let client = host.connectedClient else { return }
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

    private func install() async {
        guard let client = host.connectedClient,
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

    private func startPolling() {
        pollTask?.cancel()
        let host = host
        pollTask = Task {
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let client = host.connectedClient else { return }
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
