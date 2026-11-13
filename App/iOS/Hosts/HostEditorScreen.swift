import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A paired host's page: its connection, its name (the only thing to edit), its address and port as
/// paired, and Forget. Adding a host is `HostPairScreen`: a code, never an address or a token.
/// When the host supports updates, shows version and update status with Check / Update actions.
struct HostEditorScreen: View {
    let hostID: UUID?

    var body: some View {
        if let hostID {
            HostPage(hostID: hostID)
        } else {
            HostPairScreen()
        }
    }
}

private struct HostPage: View {
    let hostID: UUID
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.mobileApp) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let host = hosts.host(hostID) {
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
                    if host.phase.isConnected, host.supports(RemoteProtocol.hostSettingsBackgroundServiceCapability),
                       let line = HostSettingsPresentation.backgroundService(settings(of: host.id), host: host.name) {
                        Text(line).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
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
                Section {
                    LabeledContent("Name") {
                        TextField("My Mac", text: $name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Address") {
                        Text("\(host.record.address):\(String(host.record.port))")
                            .font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                    }
                } footer: {
                    Text("Paired with a code. If a Mac revokes this device, add that Mac again with a new code.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                Section {
                    Button("Forget host", role: .destructive) { confirmingForget = true }
                }
            }
        }
        .listRowBackground(Color.sh.bgRaised)
        .font(.sh(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented from Home or More, the page is a sheet's root and needs its own way out.
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
        .onAppear { name = hosts.host(hostID)?.record.name ?? "" }
        .task { await SettingsStore.of(hosts).watch() }
    }

    /// The host's settings, once Settings has read them.
    private func settings(of id: UUID) -> HostSettings? {
        let store = SettingsStore.of(hosts)
        return store.hosts.first { $0.id == id }.flatMap(store.hostSettings.settings(of:))
    }

    private func save() {
        guard let host = hosts.host(hostID) else { return dismiss() }
        do {
            let entry = try RemoteHostEntry(name: name, address: host.record.address, port: String(host.record.port), token: nil)
            try hosts.edit(hostID, entry)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forget() {
        Task {
            do {
                try await app?.forget(host: hostID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
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
    @State private var pollID = UUID()

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
                Button("Check status") { Task { await fetchStatus() } }.disabled(polling)
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
        .onDisappear { pollID = UUID(); pollTask?.cancel(); pollTask = nil; polling = false }
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
        defer { if pollTask == nil { polling = false } }
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
        pollID = UUID()
        let id = pollID
        let host = host
        polling = true
        pollTask = Task {
            defer {
                if pollID == id { polling = false; pollTask = nil }
            }
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard let client = host.connectedClient else {
                    error = "Mac disconnected. Reconnect, then check status."
                    return
                }
                do {
                    let s = try await client.hostUpdate(.status)
                    guard !Task.isCancelled else { return }
                    status = s
                    error = nil
                    if Self.terminalPhases.contains(s.phase) { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = "Couldn't read update status. Check status to try again."
                    return
                }
            }
            error = "Still updating — check status to verify progress."
        }
    }
}
