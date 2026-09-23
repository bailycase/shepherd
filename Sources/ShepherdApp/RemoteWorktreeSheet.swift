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

    init(vm: ShepherdViewModel, target: RemoteAgentRef, finalize: Bool) {
        self.vm = vm; self.target = target; self.finalize = finalize
        let connection = vm.remoteHosts.connections.first { $0.id == target.hostID }
        _endpointID = State(initialValue: vm.remoteWorktreeOperationEndpoints[target] ?? connection?.endpointID)
        _transportID = State(initialValue: connection?.transportID)
    }

    private func query(_ value: RemoteAgentQuery, statusOnly: Bool = false) async throws -> RemoteAgentResult {
        guard let endpointID, let transportID else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "Host connection unavailable. Reopen this action after reconnecting.")
        }
        return try await vm.remoteHosts.agentQuery(target, query: value, endpointID: endpointID, transportID: statusOnly ? nil : transportID)
    }
    @StateObject private var setup = WorktreeSetupModel(repoPath: "host repository")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(finalize ? "Finalize worktree" : "Delete worktree agent")
                .font(Font.nw(.title))
                .foregroundStyle(Color.nw.textPrimary)
                .padding(20)
            SheetRow("Host") { Text(vm.remoteHosts.connections.first { $0.id == target.hostID }?.config.name ?? "removed") }
            if finalize && vm.remoteWorktreeOperationIDs[target] == nil {
                if checking {
                    Text("Checking host prerequisites…").padding(20)
                } else if showingSetup {
                    WorktreeSetupChecklist(model: setup, openLoginShell: openLoginShell)
                    HStack {
                        Button("Re-run checks") { Task { await setup.runAll() } }.disabled(setup.running)
                        Spacer()
                        Button("Continue") {
                            Task { await prepareInput() }
                        }
                        .buttonStyle(NWButtonStyle(.primary))
                        .disabled(setup.running || !setup.allPassed)
                    }.padding(20)
                }
            }
            if let info {
                SheetRow("Worktree") { Text(info.path).font(Font.nw(.mono)).lineLimit(1).truncationMode(.middle).help(info.path) }
                SheetRow("Branch") { Text(info.branch).font(Font.nw(.mono)) }
                if operation == nil && vm.remoteWorktreeOperationIDs[target] == nil {
                    if finalize && !checking && !showingSetup {
                        SheetRow("Base") {
                                    HStack {
                                TextField("base branch", text: $options.base).font(Font.nw(.mono)).nwField(mono: true)
                                if let count = includedCommits {
                                    Text("Will include \(count) commit\(count == 1 ? "" : "s")")
                                        .foregroundStyle(count > 20 ? Color.nw.lanternText : Color.nw.textTertiary)
                                }
                            }
                        }
                        SheetRow("Title") { TextField("PR title", text: $options.title).nwField() }
                        SheetRow("Description") {
                            VStack(alignment: .leading) {
                                TextEditor(text: $options.body).frame(height: 70).scrollContentBackground(.hidden).padding(6)
                                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineStrong, lineWidth: 1) }
                                if generatingDescription { Text("Generating on the host…").font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary) }
                                else if info.generateDescription == true {
                                    SheetLinkButton(label: descriptionPrepared ? "Regenerate…" : "Generate…") {
                                        Task { await generateDescription(force: true) }
                                    }
                                }
                            }
                        }
                        SheetRow("Setup") { SheetLinkButton(label: "Repo setup…") { showingSetup = true } }
                        SheetRow("Commit") { Toggle("Commit remaining work", isOn: $options.autoCommit).toggleStyle(.nwSwitch) }
                        SheetRow("Cleanup") { Toggle("Delete local branch", isOn: $options.deleteLocalBranch).toggleStyle(.nwSwitch) }
                        SheetRow("Merge") { Toggle("Merge PR automatically", isOn: $options.autoMergePR).toggleStyle(.nwSwitch) }
                        if options.autoMergePR {
                            SheetRow("Method") {
                                NWSegmentedPicker(selection: $options.mergeMethod,
                                                 options: [("squash", "Squash"), ("merge", "Merge"), ("rebase", "Rebase")])
                            }
                        }
                        Text("Runs on the host: commit, push, PR, optional merge, clean check, stop agent, remove checkout. The remote branch is never deleted. Failures stop cleanup.")
                            .font(Font.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .padding(20)
                    } else if !finalize, let warning = info.warning {
                        DialogWarning(text: "\(warning) will be lost with the worktree.")
                        Toggle("I understand this work will be lost", isOn: $acknowledgedLoss).toggleStyle(.nwSwitch).padding(20)
                    }
                }
            }
            if let operation {
                ForEach(Array(operation.progress.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 3)
                }
                if let error = operation.error { DialogWarning(text: error) }
                if let url = operation.prURL, let link = URL(string: url) { Link(url, destination: link).textSelection(.enabled).padding(20) }
            }
            if let errorText { DialogWarning(text: errorText) }
            HStack {
                Button("Close") { vm.remoteWorktreeSheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                if let operation, operation.finished {
                    Button("Done") {
                        vm.remoteWorktreeOperationIDs.removeValue(forKey: target)
                        vm.remoteWorktreeOperationEndpoints.removeValue(forKey: target)
                        vm.remoteWorktreeSheet = nil
                    }
                    .buttonStyle(NWButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                } else if vm.remoteWorktreeOperationIDs[target] != nil {
                    Text("Operation continues on host. Reconnecting only checks status.")
                } else {
                    if !finalize {
                        Button("Delete agent, keep worktree") {
                            Task {
                                do {
                                    _ = try await query(.deleteKeepingWorktree)
                                    vm.remoteWorktreeSheet = nil
                                } catch { errorText = String(describing: error) }
                            }
                        }
                    }
                    if let info {
                        Button(finalize ? "Finalize" : "Delete agent and worktree", role: finalize ? nil : .destructive) { start(info) }
                        .buttonStyle(NWButtonStyle(finalize ? .primary : .danger))
                        .disabled(submitting || (finalize && (checking || showingSetup || generatingDescription || !setup.allPassed)) || (!finalize && info.warning != nil && !acknowledgedLoss)
                                  || (finalize && (options.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                    }
                }
            }.padding(20)
        }
        .font(Font.nw(.body))
        .foregroundStyle(Color.nw.textSecondary)
        .textFieldStyle(.plain)
        .frame(width: 620)
        .background(Color.nw.bgWindow)
        .buttonStyle(NWButtonStyle(.secondary))
        .task {
            guard vm.remoteWorktreeOperationIDs[target] == nil else { return }
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
            guard finalize, info != nil else { return }
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
