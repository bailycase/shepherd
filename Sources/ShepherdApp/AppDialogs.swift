import ShepherdSessions
import SwiftUI
import ShepherdUI
import ShepherdCore

/// Every sheet and dialog the main window presents: creation sheets, the directory pickers,
/// renames, confirmations, and the failed-action dialog. Each is `sheet(item:)` on a view
/// model target, so a sheet keeps the value it opened with while it dismisses.
struct AppDialogs: ViewModifier {
    @Bindable var vm: ShepherdViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $vm.showNewAgentSheet) {
                NewAgentSheet(vm: vm)
                    .dialogSheetFrame()
            }
            // The first launch's sheet; closing it, whichever way, starts restored agents. A sign-in
            // it opens shows over it.
            .sheet(item: Binding(get: { vm.yourPi.importSheet }, set: { if $0 == nil { vm.finishImport() } }),
                   onDismiss: { vm.finishImport() }) { sheet in
                PiImportSheet(state: vm.yourPi.importSheet ?? sheet,
                              signIn: { provider, key in vm.piAuth.signIn(provider, key: key, origin: .firstLaunch) },
                              retry: { vm.retryImportSignIns() },
                              reviewExtensions: {
                                  vm.finishImport()
                                  vm.settingsSection = .pi
                                  vm.showSettings = true
                              },
                              close: { vm.finishImport() },
                              chooseDefault: { vm.yourPi.chooseDefault($0) })
                    .dialogSheetFrame()
                    .sheet(item: Binding(get: { vm.piAuth.session }, set: { if $0 == nil { vm.piAuth.closeSheet() } })) { session in
                        PiSignInSheet(session: session) { vm.piAuth.closeSheet() }
                            .dialogSheetFrame()
                    }
            }
            // Sign in to <provider>: over Settings or the thread.
            .sheet(item: Binding(get: { vm.yourPi.importSheet == nil ? vm.piAuth.session : nil }, set: { if $0 == nil { vm.piAuth.closeSheet() } })) { session in
                PiSignInSheet(session: session) { vm.piAuth.closeSheet() }
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.worktreeSheetSpace) { space in
                NewWorktreeSheet(vm: vm, space: space)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.branchSheet) { sheet in
                BranchSheetView(vm: vm, sheet: sheet).dialogSheetFrame()
            }
            .sheet(item: $vm.addingChildProject) { model in
                ChildProjectSheet(model: model, dismiss: { vm.addingChildProject = nil })
            }
            .sheet(item: $vm.assigningProjectTask) { shown in
                // Same guard as the New project sheet below: a dismissing sheet must not write its last draft back.
                if let ref = vm.selectedLogicalProject {
                    AssignProjectTaskSheet(vm: vm, ref: ref, draft: Binding(get: { vm.assigningProjectTask ?? shown }, set: { if vm.assigningProjectTask != nil { vm.assigningProjectTask = $0 } }),
                                           dismiss: { vm.assigningProjectTask = nil })
                        .dialogSheetFrame()
                }
            }
            .sheet(item: $vm.runningElsewhere) { shown in
                RunElsewhereSheet(vm: vm, draft: Binding(get: { vm.runningElsewhere ?? shown }, set: { if vm.runningElsewhere != nil { vm.runningElsewhere = $0 } }),
                                  dismiss: { vm.runningElsewhere = nil })
                    .dialogSheetFrame()
            }
            .sheet(item: Binding(get: { vm.projectsEnabled ? vm.newLogicalProject : nil }, set: { vm.newLogicalProject = $0 })) { shown in
                // A dismissing sheet writes its last value back; only write while a draft exists, so turning Projects off (which clears it) stays cleared.
                NewProjectSheet(vm: vm, draft: Binding(get: { vm.newLogicalProject ?? shown }, set: { if vm.newLogicalProject != nil { vm.newLogicalProject = $0 } }),
                                dismiss: { vm.newLogicalProject = nil })
            }
            .sheet(item: $vm.spacePickerTarget) { target in
                spacePicker(target)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.remoteRenameItem) { item in
                RenameDialog(title: "Rename agent", name: vm.remoteAgent(item.value)?.name ?? "") { name in
                    vm.performRemoteAction(item.value, action: .rename(name: name))
                    vm.remoteRenameTarget = nil
                } onCancel: {
                    vm.remoteRenameTarget = nil
                }
            }
            .sheet(item: $vm.terminalRenameTarget) { rename in
                RenameDialog(title: "Rename tab", caption: "Clear the name to name the tab after what it runs.",
                             name: rename.name, allowsEmpty: true) { name in
                    vm.commitTerminalRename(rename, to: name)
                } onCancel: {
                    vm.terminalRenameTarget = nil
                }
            }
            .sheet(item: $vm.remoteWorktreeItem) { item in
                RemoteWorktreeSheet(vm: vm, target: item.target)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.spaceRenameSpace) { space in
                ProjectRenameDialog(vm: vm, space: space)
            }
            .sheet(item: $vm.agentRenameAgent) { agent in
                RenameDialog(title: "Rename agent", name: agent.name) { name in
                    vm.renameAgent(agent.id, to: name)
                    vm.agentRenameTarget = nil
                } onCancel: {
                    vm.agentRenameTarget = nil
                }
            }
            .sheet(item: $vm.worktreeDeleteAgent, onDismiss: vm.runAfterDialogDismiss) { agent in
                WorktreeDeleteDialog(vm: vm, agent: agent)
                    .dialogSheetFrame()
            }
            // The background host's worktree agent: This Mac's dialog, the host's checkout and warning.
            .sheet(item: $vm.thisMacWorktreeDelete, onDismiss: vm.runAfterDialogDismiss) { item in
                WorktreeDeleteDialog(agent: item.agent, path: item.info?.path ?? item.agent.worktreePath ?? "", settings: vm.settings, probe: {
                    if let info = item.info { return info.warning }
                    let info = try await vm.thisMacWorktreeInfo(item.target)
                    vm.thisMacWorktreeDelete?.info = info
                    return info.warning
                }, cancel: { vm.thisMacWorktreeDelete = nil }) { removeWorktree in
                    let (target, info) = (item.target, vm.thisMacWorktreeDelete?.info)
                    vm.afterDialogDismiss = { vm.deleteThisMacWorktreeAgent(target, removing: removeWorktree ? info : nil) }
                    vm.thisMacWorktreeDelete = nil
                }
                .dialogSheetFrame()
            }
            .sheet(item: $vm.agentDeleteAgent, onDismiss: vm.runAfterDialogDismiss) { agent in
                AgentDeleteDialog(agent: agent, settings: vm.settings, cancel: { vm.agentDeleteTarget = nil }) {
                    let id = agent.id
                    vm.afterDialogDismiss = { vm.deleteAgent(id) }
                    vm.agentDeleteTarget = nil
                }
            }
            // A host's agent: the same dialog, naming its host; the host deletes it once the sheet is down.
            .sheet(item: $vm.remoteDeleteItem, onDismiss: vm.remoteDeleteDismissed) { item in
                AgentDeleteDialog(agent: item.agent, host: item.hostName, settings: vm.settings,
                                  cancel: { vm.remoteDeleteTarget = nil }) { vm.confirmRemoteDelete(item.target) }
            }
            .sheet(item: $vm.automationDeleteAutomation, onDismiss: vm.runAfterDialogDismiss) { automation in
                DialogSheet(
                    title: "Delete automation",
                    subtitle: "Deletes “\(automation.name)” with its prompt, schedule and settings. A run in progress stops.",
                    actions: [
                        DialogAction("Cancel", kind: .cancel) { vm.automationDeleteTarget = nil },
                        DialogAction("Delete", kind: .destructive) {
                            let id = automation.id
                            vm.afterDialogDismiss = { vm.deleteAutomation(id) }
                            vm.automationDeleteTarget = nil
                        },
                    ]
                )
            }
            .sheet(item: $vm.spaceDeleteSpace, onDismiss: vm.runAfterDialogDismiss) { space in
                SpaceDeleteDialog(vm: vm, space: space)
            }
            .sheet(item: $vm.designDeleteRequest) { request in
                DeleteDesignDialog(words: request.words, delete: { vm.confirmDesignDelete(request) },
                                   cancel: { vm.designDeleteRequest = nil })
            }
            .sheet(item: $vm.designSystemDeleteRequest) { request in
                DeleteSystemDialog(words: request.words, delete: { vm.confirmDesignSystemDelete(request) },
                                   cancel: { vm.designSystemDeleteRequest = nil })
            }
            .sheet(item: $vm.designImportPrompt, onDismiss: { vm.designImportPromptDismissed() }) { prompt in
                DesignImportDialog(prompt: prompt, dismiss: { vm.cancelDesignImport(prompt) }, resolve: { vm.resolveDesignImport(prompt) },
                                   openExisting: { vm.resolveDesignImport(prompt, openExisting: true) })
            }
            .sheet(item: $vm.designRename) { request in
                let system: Bool = switch request.subject { case .system, .remoteSystem: true; case .design: false }
                RenameDialog(title: system ? "Rename design system" : "Rename design", name: request.name) { name in
                    vm.commitDesignRename(request, to: name)
                } onCancel: {
                    vm.designRename = nil
                }
            }
            .sheet(item: $vm.actionErrorItem) { item in
                ActionErrorDialog(error: item.value) { vm.actionError = nil }
            }
    }

    @ViewBuilder
    private func spacePicker(_ target: ShepherdViewModel.SpacePickerTarget) -> some View {
        switch target {
        case .local:
            RemoteDirectoryPicker(
                hostName: "this Mac",
                list: { path in try await LocalDirectoryLister.load(path: path) },
                choose: { path in
                    vm.spacePickerTarget = nil
                    Task { await vm.addSpace(at: URL(fileURLWithPath: path)) }
                },
                cancel: { vm.spacePickerTarget = nil }
            )
        case .relocate(let spaceID):
            RemoteDirectoryPicker(
                title: "Locate \(vm.state.spaces.first { $0.id == spaceID }?.name ?? "space")'s folder",
                actionTitle: "Use Folder",
                hostName: "this Mac",
                list: { path in try await LocalDirectoryLister.load(path: path) },
                choose: { path in
                    vm.spacePickerTarget = nil
                    Task { await vm.relocateSpace(spaceID, to: path) }
                },
                cancel: { vm.spacePickerTarget = nil }
            )
        case .importWorktree(let target):
            RemoteDirectoryPicker(
                title: "Import existing worktree",
                actionTitle: "Import",
                hostName: "this Mac",
                startPath: target.startPath,
                list: { path in try await LocalDirectoryLister.load(path: path) },
                choose: { path in
                    vm.spacePickerTarget = nil
                    Task {
                        await vm.importExistingCheckout(at: URL(fileURLWithPath: path), into: target.spaceID)
                    }
                },
                cancel: { vm.spacePickerTarget = nil }
            )
        case .host(let hostID):
            if let connection = vm.remoteHosts.allConnections.first(where: { $0.id == hostID }) {
                RemoteDirectoryPicker(
                    hostName: connection.config.name,
                    list: { path in try await vm.remoteHosts.listDir(hostID: hostID, path: path) },
                    choose: { path in
                        vm.spacePickerTarget = nil
                        Task {
                            do {
                                let spaceID = try await vm.addRemoteSpace(hostID: hostID, path: path)
                                vm.openNewThread(in: spaceID, hostID: hostID)
                            } catch {
                                vm.remoteActionError = "Couldn't add the space on \(connection.config.name): \(error)"
                            }
                        }
                    },
                    cancel: { vm.spacePickerTarget = nil }
                )
            }
        }
    }
}

/// Delete Worktree Agent: confirmed unless Settings ▸ Worktrees remembers a delete
/// (`requestWorktreeDelete`). The warning about unreconciled work comes from git off the main
/// thread; until it is in, removing the worktree stays disabled so the warning can never arrive
/// after the click. The background host's worktree agents use it too, with the host's probe.
struct WorktreeDeleteDialog: View {
    let agent: Agent
    let path: String
    let settings: AppSettings
    /// The loss warning, nil when nothing would be lost. A throw keeps the worktree.
    let probe: () async throws -> String?
    let cancel: () -> Void
    /// Runs after "Don't ask again" is remembered.
    let delete: (_ removeWorktree: Bool) -> Void
    @State private var warning: String?
    @State private var probeFailure: String?
    @State private var checked = false
    @State private var remember: Bool

    init(agent: Agent, path: String, settings: AppSettings, probe: @escaping () async throws -> String?,
         cancel: @escaping () -> Void, delete: @escaping (_ removeWorktree: Bool) -> Void) {
        self.agent = agent; self.path = path; self.settings = settings
        self.probe = probe; self.cancel = cancel; self.delete = delete
        _remember = State(initialValue: settings.worktreeDeleteAction != .ask)
    }

    /// An agent of this Mac's own workspace: git probes its checkout here, or the background
    /// host that runs it reports it (`hostWorktreeInfo`).
    init(vm: ShepherdViewModel, agent: Agent) {
        let path = vm.worktreeCheckoutPath(agent), branch = agent.worktreeBranch ?? ""
        let ref = vm.localRef(agent.id)
        self.init(agent: agent, path: path, settings: vm.settings, probe: {
            if let ref {
                let info = if let known = vm.hostWorktreeInfo { known } else { try await vm.thisMacWorktreeInfo(ref) }
                vm.hostWorktreeInfo = info
                return info.warning
            }
            // No checkout to probe (its space is gone): `git -C ""` would probe the app's own
            // working directory instead.
            guard !path.isEmpty else { return nil }
            return await Task.detached(priority: .userInitiated) {
                GitWorktree.unreconciledWork(worktree: path, branch: branch)
            }.value
        }, cancel: { vm.worktreeDeleteTarget = nil; vm.hostWorktreeInfo = nil }) { removeWorktree in
            // Same dismissal choreography as Remove Space: deleting tears down a mounted layout,
            // so the sheet finishes dismissing first (`onDismiss`).
            let id = agent.id
            vm.afterDialogDismiss = {
                vm.deleteWorktreeAgent(id, removeWorktree: removeWorktree)
                vm.hostWorktreeInfo = nil
            }
            vm.worktreeDeleteTarget = nil
        }
    }

    private var branch: String { agent.worktreeBranch ?? "" }

    var body: some View {
        DialogSheet(
            title: "Delete worktree agent",
            subtitle: "Stops \(agent.name). “Delete agent and worktree” also removes its checkout and branch.",
            width: AppLayout.confirmSheetWideWidth,
            status: checked ? nil : "Checking for unsaved work…",
            actions: [
                DialogAction("Cancel", kind: .cancel, action: cancel),
                DialogAction("Delete agent only") { confirm(removeWorktree: false) },
                DialogAction("Delete agent and worktree", kind: .destructive, isEnabled: checked && probeFailure == nil) {
                    confirm(removeWorktree: true)
                },
            ]
        ) {
            SheetRow("Worktree") {
                Text(path)
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .textSelection(.enabled)
            }
            SheetRow("Branch") {
                Text(branch)
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textSecondary)
                    .textSelection(.enabled)
            }
            if let warning {
                DialogBanner(title: "Unreconciled work", message: "\(warning) will be lost with the worktree.")
            }
            if let probeFailure {
                DialogBanner(state: .failed, title: "Couldn’t check the worktree", message: probeFailure)
            }
            DontAskAgainToggle(isOn: $remember, caption: DontAskAgainToggle.worktreeCaption).dialogInset()
        }
        // The probe's answer arrives after the sheet is up: the warning discloses and the
        // "Checking…" status fades as the destructive action enables.
        .shAnimation(.disclosure, value: checked)
        .task(id: agent.id) {
            do { warning = try await probe() } catch { probeFailure = ActionError.describe(error) }
            checked = true
        }
    }

    private func confirm(removeWorktree: Bool) {
        settings.rememberWorktreeDelete(remember, removeWorktree: removeWorktree)
        delete(removeWorktree)
    }
}

/// Delete Agent: confirmed unless remembered. It stops the agent's run and drops the thread from the sidebar,
/// and nothing in the app brings it back. A host's agent goes from its host, so its thread closes on every device.
struct AgentDeleteDialog: View {
    let agent: Agent
    /// The host's name, for a host's agent; nil for This Mac's.
    var host: String? = nil
    let settings: AppSettings
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        DialogSheet(
            title: "Delete agent",
            subtitle: Self.subtitle(agent, host: host),
            actions: [
                DialogAction("Cancel", kind: .cancel, action: cancel),
                DialogAction("Delete", kind: .destructive, action: delete),
            ],
            dontAskAgain: .deleteAgent,
            settings: settings
        )
    }

    static func subtitle(_ agent: Agent, host: String? = nil) -> String {
        let stops = agent.status == .idle ? "Removes" : "Stops and removes"
        guard let host else {
            return "\(stops) “\(agent.name)”. Its conversation stays on disk, but the thread leaves the sidebar and cannot be reopened here."
        }
        return "\(stops) “\(agent.name)” on \(host). Its conversation stays on \(host), but the thread closes on every device and cannot be reopened."
    }
}

struct ProjectRenameDialog: View {
    var vm: ShepherdViewModel
    let space: Space
    @State var error: String?

    static func problem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 256 && name.rangeOfCharacter(from: .controlCharacters) == nil
            ? nil : "Use a name of 1–256 characters without control characters."
    }

    var body: some View {
        RenameDialog(title: "Rename space", caption: error ?? "Display name only. The folder name and location stay unchanged.", name: space.name) { name in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = Self.problem(name) { error = problem; return }
            vm.renameSpace(space.id, to: name)
            vm.spaceRenameTarget = nil
        } onCancel: { vm.spaceRenameTarget = nil }
    }
}

/// Remove Project: always confirmed, since it stops the project's agents.
struct SpaceDeleteDialog: View {
    var vm: ShepherdViewModel
    let space: Space

    var body: some View {
        let count = vm.state.agents.count { $0.spaceID == space.id }
        DialogSheet(
            title: "Remove space",
            subtitle: "Removes \(space.name) from the sidebar and stops its \(count) agent\(count == 1 ? "" : "s"). "
                + "The local folder and all its files are kept. Saved conversations and space history remain. Child spaces stay registered.",
            actions: [
                DialogAction("Cancel", kind: .cancel) { vm.spaceDeleteTarget = nil },
                DialogAction("Remove space", kind: .destructive) {
                    let id = space.id
                    // Deleting a space tears down mounted terminal layouts — a huge view-tree
                    // change. The sheet's `onDismiss` runs it once the sheet is gone; mutating
                    // its host mid-dismissal wedges the modal session.
                    vm.afterDialogDismiss = { vm.deleteSpace(id) }
                    vm.spaceDeleteTarget = nil
                },
            ],
            dontAskAgain: vm.spaceDeleteRequested ? nil : .removeSpace,
            settings: vm.settings
        )
    }
}
