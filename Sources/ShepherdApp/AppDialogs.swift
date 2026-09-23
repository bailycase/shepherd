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
            }
            .sheet(item: $vm.worktreeSheetSpace) { space in
                NewWorktreeSheet(vm: vm, space: space)
            }
            .sheet(item: $vm.finalizeRequest) { request in
                FinalizeWorktreeSheet(vm: vm, agent: request.agent, space: request.space)
            }
            .sheet(item: $vm.spacePickerTarget) { target in
                spacePicker(target)
            }
            .sheet(item: $vm.remoteRenameItem) { item in
                RenameDialog(title: "Rename agent", name: vm.remoteAgent(item.value)?.name ?? "") { name in
                    vm.performRemoteAction(item.value, action: .rename(name: name))
                    vm.remoteRenameTarget = nil
                } onCancel: {
                    vm.remoteRenameTarget = nil
                }
            }
            .sheet(item: $vm.remoteWorktreeItem) { item in
                RemoteWorktreeSheet(vm: vm, target: item.target, finalize: item.finalize)
            }
            .sheet(item: $vm.spaceRenameSpace) { space in
                RenameDialog(title: "Rename space", caption: "Sidebar label only — the folder on disk is not renamed.",
                             name: space.name) { name in
                    vm.renameSpace(space.id, to: name)
                    vm.spaceRenameTarget = nil
                } onCancel: {
                    vm.spaceRenameTarget = nil
                }
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
            }
            .sheet(item: $vm.spaceDeleteSpace) { space in
                SpaceDeleteDialog(vm: vm, space: space)
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
                                _ = try await vm.addRemoteSpace(hostID: hostID, path: path)
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
        .task(id: agent.id) {
            let (path, branch) = (path, branch)
            warning = await Task.detached(priority: .userInitiated) {
                GitWorktree.unreconciledWork(worktree: path, branch: branch)
            }.value
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

/// Remove Space: always confirmed, since it stops the space's agents.
struct SpaceDeleteDialog: View {
    var vm: ShepherdViewModel
    let space: Space

    var body: some View {
        let count = vm.state.agents.count { $0.spaceID == space.id }
        DialogSheet(
            title: "Remove space",
            subtitle: "Removes \(space.name) from the sidebar and stops its \(count) agent\(count == 1 ? "" : "s"). "
                + "Conversations stay on disk; the checkout is untouched. Nested project spaces are separate and survive.",
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
