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
                              close: { vm.finishImport() })
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
            .sheet(item: $vm.finalizeRequest) { request in
                FinalizeWorktreeSheet(vm: vm, agent: request.agent, space: request.space)
                    .dialogSheetFrame()
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
                RemoteWorktreeSheet(vm: vm, target: item.target, finalize: item.finalize)
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
            .sheet(item: $vm.worktreeDeleteAgent) { agent in
                WorktreeDeleteDialog(vm: vm, agent: agent)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.spaceDeleteSpace) { space in
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
                let system: Bool = if case .system = request.subject { true } else { false }
                RenameDialog(title: system ? "Rename design system" : "Rename design", name: request.name) { name in
                    vm.commitDesignRename(request, to: name)
                } onCancel: {
                    vm.designRename = nil
                }
            }
            .sheet(item: $vm.actionErrorItem) { item in
                ActionErrorDialog(message: item.value) { vm.remoteActionError = nil }
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
            if let connection = vm.remoteHosts.connections.first(where: { $0.id == hostID }) {
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

/// Delete Worktree Agent: always confirmed, since it may remove the checkout. The warning about
/// unreconciled work comes from git off the main thread; until it is in, removing the worktree
/// stays disabled so the warning can never arrive after the click.
struct WorktreeDeleteDialog: View {
    var vm: ShepherdViewModel
    let agent: Agent
    @State private var warning: String?
    @State private var checked = false

    private var branch: String { agent.worktreeBranch ?? "" }

    private var path: String {
        agent.worktreePath ?? vm.state.spaces.first { $0.id == agent.spaceID }
            .map { GitWorktree.destination(repo: $0.path, branch: branch) } ?? ""
    }

    var body: some View {
        DialogSheet(
            title: "Delete worktree agent",
            subtitle: "Stops \(agent.name). “Delete agent and worktree” also removes its checkout and branch.",
            width: AppLayout.confirmSheetWideWidth,
            status: checked ? nil : "Checking for unsaved work…",
            actions: [
                DialogAction("Cancel", kind: .cancel) { vm.worktreeDeleteTarget = nil },
                DialogAction("Delete agent only") { confirm(removeWorktree: false) },
                DialogAction("Delete agent and worktree", kind: .destructive, isEnabled: checked) { confirm(removeWorktree: true) },
            ]
        ) {
            SheetRow("Worktree") {
                Text(path)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .textSelection(.enabled)
            }
            SheetRow("Branch") {
                Text(branch)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .textSelection(.enabled)
            }
            if let warning {
                DialogBanner(title: "Unreconciled work", message: "\(warning) will be lost with the worktree.")
            }
        }
        // The probe's answer arrives after the sheet is up: the warning discloses and the
        // "Checking…" status fades as the destructive action enables.
        .nwAnimation(.disclosure, value: checked)
        .task(id: agent.id) {
            let (path, branch) = (path, branch)
            // No checkout to probe (its space is gone): `git -C ""` would probe the app's own
            // working directory instead.
            if !path.isEmpty {
                warning = await Task.detached(priority: .userInitiated) {
                    GitWorktree.unreconciledWork(worktree: path, branch: branch)
                }.value
            }
            checked = true
        }
    }

    /// Same dismissal choreography as Remove Space: deleting tears down a mounted layout, so
    /// the sheet finishes dismissing first.
    private func confirm(removeWorktree: Bool) {
        let id = agent.id
        vm.worktreeDeleteTarget = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            vm.deleteWorktreeAgent(id, removeWorktree: removeWorktree)
        }
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
                    vm.spaceDeleteTarget = nil
                    // Deleting a space tears down mounted terminal layouts — a huge view-tree
                    // change. Let the sheet finish dismissing first; mutating its host
                    // mid-dismissal wedges the modal session.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        vm.deleteSpace(id)
                    }
                },
            ]
        )
    }
}
