import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

struct RemoteWorktreeSheet: View {
    var vm: ShepherdViewModel
    let target: RemoteAgentRef
    let finalize: Bool
    @State private var endpointID: UUID?
    @State private var transportID: UUID?
    /// Set only by previews: the finalize form as a ready host fills it, and no query is sent.
    private let staged: Staged?

    /// The host's worktree and a commit count, so a preview renders the finalize form without a
    /// host.
    struct Staged {
        var info: RemoteWorktreeInfo
        var includedCommits: Int?
    }

    init(vm: ShepherdViewModel, target: RemoteAgentRef, finalize: Bool, staged: Staged? = nil) {
        self.vm = vm; self.target = target; self.finalize = finalize; self.staged = staged
        let connection = vm.remoteHosts.connections.first { $0.id == target.hostID }
        _endpointID = State(initialValue: vm.remoteWorktreeOperationEndpoints[target] ?? connection?.endpointID)
        _transportID = State(initialValue: connection?.transportID)
        if let staged {
            _info = State(initialValue: staged.info)
            _options = State(initialValue: staged.info.defaults)
            _includedCommits = State(initialValue: staged.includedCommits)
            _checking = State(initialValue: false)
            _descriptionPrepared = State(initialValue: true)
        }
    }

    private func query(_ value: RemoteAgentQuery, statusOnly: Bool = false) async throws -> RemoteAgentResult {
        guard let endpointID, let transportID else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "Host connection unavailable. Reopen this action after reconnecting.")
        }
        return try await vm.remoteHosts.agentQuery(target, query: value, endpointID: endpointID, transportID: statusOnly ? nil : transportID)
    }
    @State private var setup = WorktreeSetupModel(repoPath: "host repository")
    @State private var showingSetup = false
    @State private var checking = true
    @State private var includedCommits: Int?
    @State private var generatingDescription = false
    @State private var descriptionPrepared = false
    @State private var info: RemoteWorktreeInfo?
    @State private var options = RemoteFinalizeOptions(base: "", title: "", body: "", autoCommit: true, deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash")
    @State private var errorText: String?
    @State private var operation: RemoteWorktreeOperation?
    @State private var submitting = false
    @State private var acknowledgedLoss = false

    private var hostName: String {
        vm.remoteHosts.connections.first { $0.id == target.hostID }?.config.name ?? "removed"
    }

    private var operationPending: Bool { vm.remoteWorktreeOperationIDs[target] != nil }

    var body: some View {
        NWDialog(finalize ? "Finalize worktree" : "Delete worktree agent",
                 message: finalize ? "Runs on \(hostName): commit, push, pull request, optional merge, then cleanup." : nil,
                 width: AppLayout.remoteWorktreeSheetWidth) {
            SheetRow("Host") {
                Text(hostName).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
            }
            if finalize && !operationPending {
                if checking {
                    HStack(spacing: NW.Space.s) {
                        ProgressView().progressViewStyle(.nwSpinner)
                        Text("Checking host prerequisites…").font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                    }
                    .padding(.horizontal, NWDialogMetrics.inset)
                    .padding(.vertical, NW.Space.l)
                } else if showingSetup {
                    WorktreeSetupChecklist(model: setup, openLoginShell: openLoginShell)
                }
            }
            if let info {
                SheetRow("Worktree") {
                    Text(info.path).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                        .lineLimit(1).truncationMode(.middle).help(info.path).textSelection(.enabled)
                }
                SheetRow("Branch") {
                    Text(info.branch).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary).textSelection(.enabled)
                }
                if operation == nil && !operationPending {
                    if finalize && !checking && !showingSetup {
                        finalizeInput(info)
                    } else if !finalize, let warning = info.warning {
                        DialogBanner(title: "Unreconciled work", message: "\(warning) will be lost with the worktree.")
                        Toggle("I understand this work will be lost", isOn: $acknowledgedLoss)
                            .toggleStyle(.nwCheckbox)
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textPrimary)
                            .padding(.horizontal, NWDialogMetrics.inset)
                            .padding(.top, NW.Space.l)
                    }
                }
            }
            if let operation {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(Array(operation.progress.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, NWDialogMetrics.inset)
                .padding(.top, NW.Space.l)
                if let error = operation.error { DialogBanner(state: .failed, title: "The host stopped the operation", message: error) }
                if let url = operation.prURL, let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.nw(.mono))
                        .foregroundStyle(Color.nw.running)
                        .textSelection(.enabled)
                        .padding(.horizontal, NWDialogMetrics.inset)
                        .padding(.top, NW.Space.l)
                }
            }
            if let errorText { DialogBanner(state: .failed, title: "Request failed", message: errorText) }
        } status: {
            if operationPending, operation?.finished != true {
                NWDialogStatus("Operation continues on the host. Reconnecting only checks its status.")
            } else if finalize && showingSetup && !operationPending {
                Button("Re-run checks") { Task { await setup.runAll() } }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(setup.running)
            }
        } actions: {
            actions
        }
        .task {
            guard vm.remoteWorktreeOperationIDs[target] == nil else { return }
            if staged != nil {
                // Every check passing, answered here instead of by a host.
                let checks = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0.rawValue, RemoteWorktreeCheckState.pass("ok")) })
                setup.remoteAction = { _ in RemoteWorktreeSetup(repoPath: "host repository", checks: checks, repoSettings: [:]) }
                await setup.runAll()
                return
            }
            if finalize {
                setup.remoteAction = { action in
                    guard case .worktreeSetup(let result) = try await query(.worktreeSetup(action: action)) else {
                        throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected host setup reply")
                    }
                    return result
                }
                await setup.runAll()
                showingSetup = !setup.allPassed
                checking = false
                if setup.allPassed { await prepareInput() }
            } else { await prepareInput() }
        }
        .task(id: options.base) {
            guard finalize, info != nil, staged == nil else { return }
            let base = options.base
            includedCommits = nil
            do {
                try await Task.sleep(for: .milliseconds(250))
                if case .worktreeCommitCount(let count) = try await query(.worktreeCommitCount(base: base)),
                   !Task.isCancelled, options.base == base { includedCommits = count }
            } catch { if !Task.isCancelled { errorText = String(describing: error) } }
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
            .buttonStyle(.nw(.secondary))
            .keyboardShortcut(.cancelAction)
        if let operation, operation.finished {
            Button("Done") {
                vm.remoteWorktreeOperationIDs.removeValue(forKey: target)
                vm.remoteWorktreeOperationEndpoints.removeValue(forKey: target)
                vm.remoteWorktreeSheet = nil
            }
            .buttonStyle(.nw(.primary))
            .keyboardShortcut(.defaultAction)
        } else if !operationPending {
            if finalize && showingSetup {
                Button("Continue") { Task { await prepareInput() } }
                    .buttonStyle(.nw(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.running || !setup.allPassed)
            } else if !finalize {
                Button("Delete agent only") {
                    Task {
                        do {
                            _ = try await query(.deleteKeepingWorktree)
                            vm.remoteWorktreeSheet = nil
                        } catch { errorText = String(describing: error) }
                    }
                }
                .buttonStyle(.nw(.secondary))
            }
            if let info, !(finalize && showingSetup) {
                Button(finalize ? "Finalize" : "Delete agent and worktree") { start(info) }
                    .buttonStyle(.nw(finalize ? .primary : .dangerFill))
                    .keyboardShortcut(finalize ? KeyboardShortcut.defaultAction : nil)
                    .disabled(submitting || (finalize && (checking || showingSetup || generatingDescription || !setup.allPassed)) || (!finalize && info.warning != nil && !acknowledgedLoss)
                              || (finalize && (options.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
            }
        }
    }

    @ViewBuilder
    private func finalizeInput(_ info: RemoteWorktreeInfo) -> some View {
        SheetRow("Base") {
            HStack(spacing: NW.Space.m) {
                TextField("Base branch", text: $options.base).textFieldStyle(.nw(mono: true))
                    .frame(maxWidth: AppLayout.baseFieldMaxWidth)
                if let count = includedCommits {
                    Text("Will include \(count) commit\(count == 1 ? "" : "s")")
                        .font(.nw(.caption))
                        .foregroundStyle(count > 20 ? Color.nw.lanternText : Color.nw.textTertiary)
                }
            }
        }
        SheetRow("Title") {
            TextField("Pull request title", text: $options.title,
                      prompt: Text("PR title").foregroundStyle(Color.nw.textTertiary))
                .textFieldStyle(.nw)
        }
        SheetRow("Description", alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                TextEditor(text: $options.body)
                    .nwText(.body)
                    .foregroundStyle(Color.nw.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: AppLayout.descriptionEditorHeight)
                    .padding(NW.Space.s)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(Color.nw.lineStrong, lineWidth: 1) }
                    .accessibilityLabel("Pull request description")
                if generatingDescription {
                    Text("Generating on the host…").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                } else if info.generateDescription == true {
                    SheetLinkButton(label: descriptionPrepared ? "Regenerate…" : "Generate…") {
                        Task { await generateDescription(force: true) }
                    }
                }
            }
        }
        SheetRow("Setup") { SheetLinkButton(label: "Repo setup…") { showingSetup = true } }
        SheetRow("Commit") { captionedSwitch("Commit remaining work", isOn: $options.autoCommit) }
        SheetRow("Cleanup") { captionedSwitch("Delete local branch", isOn: $options.deleteLocalBranch) }
        SheetRow("Merge") { captionedSwitch("Merge PR automatically", isOn: $options.autoMergePR) }
        if options.autoMergePR {
            SheetRow("Method") {
                NWSegmentedPicker("Merge method", selection: $options.mergeMethod,
                                  options: [("squash", "Squash"), ("merge", "Merge"), ("rebase", "Rebase")])
            }
        }
        Text("Runs on the host: commit, push, PR, optional merge, clean check, stop agent, remove checkout. The remote branch is never deleted. Failures stop cleanup.")
            .nwText(.caption)
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NWDialogMetrics.inset)
            .padding(.top, NW.Space.l)
    }

    /// A switch with what it does beside it: the row label alone ("Cleanup") doesn't say.
    private func captionedSwitch(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: NW.Space.m) {
            SettingsSwitch(label: label, isOn: isOn)
            Text(label)
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private func prepareInput() async {
        do {
            if info == nil, case .worktreeInfo(let value) = try await query(.worktreeInfo) {
                info = value
                options = value.defaults
            }
            showingSetup = false
            if finalize { await generateDescription() }
        } catch { errorText = String(describing: error) }
    }

    private func generateDescription(force: Bool = false) async {
        guard WorktreePRDescriptionGenerator.shouldGenerate(enabled: info?.generateDescription == true, prepared: descriptionPrepared, force: force),
              !generatingDescription else { return }
        let original = options.body
        generatingDescription = true
        defer { generatingDescription = false }
        do {
            if case .worktreeDescription(let body) = try await query(.worktreeDescription(base: options.base, title: options.title)) {
                options.body = WorktreePRDescriptionGenerator.applying(body, replacing: original, current: options.body)
                descriptionPrepared = true
            }
        } catch { errorText = String(describing: error) }
    }

    private func openLoginShell() {
        vm.selectRemoteAgent(hostID: target.hostID, agentID: target.agentID)
        let requestID = UUID()
        vm.remoteInspectionRequest = requestID
        Task {
            do {
                if case .inspector(let tabID) = try await query(.worktreeSetup(action: .loginShell)), vm.remoteInspectionRequest == requestID, vm.selectedRemoteAgent == target {
                    vm.showRemoteInspector(target, tabID: tabID)
                    vm.remoteWorktreeSheet = nil
                }
            } catch { errorText = String(describing: error) }
        }
    }

    private func start(_ info: RemoteWorktreeInfo) {
        submitting = true
        let id = UUID()
        vm.remoteWorktreeOperationIDs[target] = id
        vm.remoteWorktreeOperationEndpoints[target] = endpointID
        Task {
            do {
                let query: RemoteAgentQuery = finalize
                    ? .finalizeWorktree(operationID: id, options: options)
                    : .deleteWorktree(operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint)
                if case .worktreeOperation(let status) = try await self.query(query) {
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
