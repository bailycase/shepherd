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
            .sheet(item: $vm.worktreeSheetSpace) { space in
                NewWorktreeSheet(vm: vm, space: space)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.finalizeRequest) { request in
                FinalizeWorktreeSheet(vm: vm, agent: request.agent, space: request.space)
                    .dialogSheetFrame()
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
            .sheet(item: $vm.remoteAutomationItem) { item in
                RemoteAutomationSheet(vm: vm, key: item.value)
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.remoteWorktreeItem) { item in
                RemoteWorktreeSheet(vm: vm, target: item.target, finalize: item.finalize)
                    .dialogSheetFrame()
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
                    .dialogSheetFrame()
            }
            .sheet(item: $vm.spaceDeleteSpace) { space in
                SpaceDeleteDialog(vm: vm, space: space)
            }
            .sheet(item: $vm.peerDeleteItem) { confirmation in
                let agent = confirmation.agent
                PeerDeleteDialog(
                    requester: confirmation.senderName,
                    agent: agent.name,
                    space: vm.state.spaces.first { $0.id == agent.spaceID }?.name,
                    branch: agent.worktreeBranch,
                    directory: vm.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.first { $0.agentID == agent.id }
                        .map { ($0.cwd as NSString).abbreviatingWithTildeInPath },
                    delete: {
                        // Deleting tears down a mounted layout: the sheet finishes dismissing first.
                        Task { await vm.confirmPeerDeletion(requestID: confirmation.requestID, dismissal: .milliseconds(300)) }
                    },
                    cancel: { vm.cancelPeerDeletion(requestID: confirmation.requestID) }
                )
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

/// An agent's `agent_delete`: only the user can approve it, here. Cancel, or no answer before
/// the request times out, keeps the agent; approving deletes it like Delete Agent, keeping its
/// worktree and branch. Its branch, else its directory, tells it apart from agents sharing its
/// name.
struct PeerDeleteDialog: View {
    let requester: String
    let agent: String
    var space: String?
    var branch: String?
    var directory: String?
    let delete: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogSheet(
            title: "Delete agent",
            subtitle: "Another agent asks you to delete this one. If you don't answer within two minutes, it is kept.",
            actions: [
                DialogAction("Cancel", kind: .cancel, action: cancel),
                DialogAction("Delete agent", kind: .destructive, action: delete),
            ]
        ) {
            SheetRow("Agent") {
                Text(agent)
                    .nwText(.ui)
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(agent)
            }
            if let branch {
                SheetRow("Branch") { mono(branch) }
            } else if let directory {
                SheetRow("Directory") { mono(directory) }
            }
            if let space {
                SheetRow("Space") {
                    Text(space)
                        .nwText(.ui)
                        .foregroundStyle(Color.nw.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            SheetRow("Asked by") {
                Text(requester)
                    .nwText(.ui)
                    .foregroundStyle(Color.nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            DialogBanner(title: "Stops the agent and everything it started",
                         message: "Its pi session ends mid-turn and its terminal panes close."
                             + (branch == nil ? "" : " Its worktree and branch are kept."))
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.nw(.mono))
            .foregroundStyle(Color.nw.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .textSelection(.enabled)
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
