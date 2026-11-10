import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Delete Worktree Agent for a remote worktree agent: the host's worktree and loss warning, then
/// the host's progress as it stops the agent and removes the checkout.
struct RemoteWorktreeSheet: View {
    var vm: ShepherdViewModel
    let target: RemoteAgentRef
    @State private var endpointID: UUID?
    @State private var transportID: UUID?
    /// Set only by previews: the host's worktree as a ready host reports it, and no query is sent.
    private let staged: RemoteWorktreeInfo?

    init(vm: ShepherdViewModel, target: RemoteAgentRef, staged: RemoteWorktreeInfo? = nil) {
        self.vm = vm; self.target = target; self.staged = staged
        let connection = vm.remoteHosts.allConnections.first { $0.id == target.hostID }
        _endpointID = State(initialValue: vm.remoteWorktreeOperationEndpoints[target] ?? connection?.endpointID)
        _transportID = State(initialValue: connection?.transportID)
        _remember = State(initialValue: vm.settings.worktreeDeleteAction != .ask)
        if let staged { _info = State(initialValue: staged) }
    }

    private func query(_ value: RemoteAgentQuery, statusOnly: Bool = false) async throws -> RemoteAgentResult {
        guard let endpointID, let transportID else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "Host connection unavailable. Reopen this action after reconnecting.")
        }
        return try await vm.remoteHosts.agentQuery(target, query: value, endpointID: endpointID, transportID: statusOnly ? nil : transportID)
    }
    @State private var info: RemoteWorktreeInfo?
    @State private var errorText: String?
    @State private var operation: RemoteWorktreeOperation?
    @State private var submitting = false
    @State private var acknowledgedLoss = false
    /// Delete's "Don't ask again".
    @State private var remember: Bool

    private var hostName: String {
        vm.remoteHosts.allConnections.first { $0.id == target.hostID }?.config.name ?? "removed"
    }

    private var operationPending: Bool { vm.remoteWorktreeOperationIDs[target] != nil }

    /// Which part of the sheet shows: the confirmation, the running operation, the outcome.
    private var stage: [Bool] {
        [info != nil, operationPending, operation != nil, operation?.finished == true]
    }

    var body: some View {
        SHDialog("Delete worktree agent", width: AppLayout.remoteWorktreeSheetWidth) {
            SheetRow("Host") {
                Text(hostName).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
            }
            if let info {
                SheetRow("Worktree") {
                    Text(info.path).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1).truncationMode(.middle).help(info.path).textSelection(.enabled)
                }
                SheetRow("Branch") {
                    Text(info.branch).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).textSelection(.enabled)
                }
                if operation == nil && !operationPending {
                    if let warning = info.warning {
                        DialogBanner(title: "Unreconciled work", message: "\(warning) will be lost with the worktree.")
                        Toggle("I understand this work will be lost", isOn: $acknowledgedLoss)
                            .toggleStyle(.shCheckbox)
                            .font(.sh(.ui))
                            .foregroundStyle(Color.sh.textPrimary)
                            .padding(.horizontal, SHDialogMetrics.inset)
                            .padding(.top, SH.Space.l)
                    }
                    DontAskAgainToggle(isOn: $remember, caption: DontAskAgainToggle.worktreeCaption).dialogInset()
                }
            }
            if let operation {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    ForEach(Array(operation.progress.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).textSelection(.enabled)
                            .shTransition(.list)
                    }
                }
                .padding(.horizontal, SHDialogMetrics.inset)
                .padding(.top, SH.Space.l)
                if let error = operation.error { DialogBanner(state: .failed, title: "The host stopped the operation", message: error) }
            }
            if let errorText { DialogBanner(state: .failed, title: "Request failed", message: errorText) }
        } status: {
            if operationPending, operation?.finished != true {
                SHDialogStatus("Operation continues on the host. Reconnecting only checks its status.")
            }
        } actions: {
            actions
        }
        // The confirmation → the host's progress → done: each stage replaces the last in place
        // as the sheet eases to its height, and progress lines arrive as rows.
        .shAnimation(.disclosure, value: stage)
        .shAnimation(.list, value: operation?.progress.count)
        .shAnimation(.disclosure, value: errorText)
        .task {
            guard vm.remoteWorktreeOperationIDs[target] == nil, staged == nil else { return }
            await loadInfo()
        }
        .task(id: vm.remoteWorktreeOperationIDs[target]) {
            guard let id = vm.remoteWorktreeOperationIDs[target] else { return }
            while !Task.isCancelled {
                do {
                    if case .worktreeOperation(let status) = try await query(.worktreeStatus(operationID: id), statusOnly: true) {
                        operation = status
                        errorText = nil
                        if status.finished { return }
                    }
                } catch { errorText = "Outcome not yet known: \(error). Do not retry the operation." }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Close") { vm.remoteWorktreeSheet = nil }
            .buttonStyle(.sh(.secondary))
            .keyboardShortcut(.cancelAction)
        if let operation, operation.finished {
            Button("Done") {
                vm.remoteWorktreeOperationIDs.removeValue(forKey: target)
                vm.remoteWorktreeOperationEndpoints.removeValue(forKey: target)
                vm.remoteWorktreeSheet = nil
            }
            .buttonStyle(.sh(.primary))
            .keyboardShortcut(.defaultAction)
        } else if !operationPending {
            Button("Delete agent only") {
                vm.settings.rememberWorktreeDelete(remember, removeWorktree: false)
                Task {
                    do {
                        _ = try await query(.deleteKeepingWorktree)
                        vm.remoteWorktreeSheet = nil
                    } catch { errorText = String(describing: error) }
                }
            }
            .buttonStyle(.sh(.secondary))
            if let info {
                Button("Delete agent and worktree") { start(info) }
                    .buttonStyle(.sh(.dangerFill))
                    .disabled(submitting || (info.warning != nil && !acknowledgedLoss))
            }
        }
    }

    private func loadInfo() async {
        do {
            if info == nil, case .worktreeInfo(let value) = try await query(.worktreeInfo) {
                info = value
                // A remembered removal skips the confirmation, never the host's loss warning.
                if value.warning == nil, vm.settings.worktreeDeleteAction == .removeWorktree { start(value) }
            }
        } catch { errorText = String(describing: error) }
    }

    private func start(_ info: RemoteWorktreeInfo) {
        vm.settings.rememberWorktreeDelete(remember, removeWorktree: true)
        submitting = true
        let id = UUID()
        vm.remoteWorktreeOperationIDs[target] = id
        vm.remoteWorktreeOperationEndpoints[target] = endpointID
        Task {
            do {
                if case .worktreeOperation(let status) = try await query(
                    .deleteWorktree(operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint)) {
                    operation = status
                }
            } catch RemoteHostClientError.rejected(_, let message) {
                vm.remoteWorktreeOperationIDs.removeValue(forKey: target)
                vm.remoteWorktreeOperationEndpoints.removeValue(forKey: target)
                errorText = message
            } catch {
                errorText = "Request failed: \(error). Check operation status before trying again."
            }
            submitting = false
        }
    }
}
