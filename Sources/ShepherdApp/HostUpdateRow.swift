import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

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
    @State private var dontAskAgain = false

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
                        Button("Update and restart\u{2026}") {
                            if AppSettings.shared.skipped(.updateHost) != nil { onInstall?() } else { confirmingInstall = true }
                        }
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
            Button("Update and restart", role: .destructive) {
                if dontAskAgain { AppSettings.shared.skip(.updateHost, with: "Update and restart") }
                onInstall?()
            }
        } message: {
            Text(HostSettingsPresentation.installConfirmation(host: hostName))
        }
        .dialogSuppressionToggle(isSuppressed: $dontAskAgain)
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
