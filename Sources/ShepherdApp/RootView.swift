import SwiftUI
import ShepherdUI
import ShepherdCore

struct RootView: View {
    @Bindable var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var appearance = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var renameDraft = ""
    @State private var liveSidebarWidth: Double?
    /// Unreconciled-work warning for the Delete Worktree Agent alert,
    /// computed once when the target is set (a couple of quick git probes).
    @State private var worktreeDeleteWarning: String?

    var body: some View {
        HStack(spacing: 0) {
            // Left column: the flat canvas runs continuously behind the traffic lights and the
            // tree. ⌘⇧S hides it. It keeps its width while a right pane is open.
            if !vm.sidebarHidden {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: AppLayout.trafficLightHeight)
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                    SidebarView(vm: vm)
                }
                .frame(width: CGFloat(liveSidebarWidth ?? appearance.sidebarWidth))
                .background(Color.nw.bgBase.ignoresSafeArea())

                sidebarResizeHandle
            }

            VStack(spacing: 0) {
                WorkspaceHeaderView(vm: vm)
                WorkspaceView(vm: vm)
            }
            .frame(minWidth: AppLayout.mainColumnMinWidth)
            .background(Color.nw.bgWindow)
        }
        .coordinateSpace(.named("root-layout"))
        .overlay {
            if vm.showComponentGallery {
                ComponentGallery()
                    .overlay(alignment: .topTrailing) {
                        Button("Close") { vm.showComponentGallery = false }
                            .buttonStyle(NWButtonStyle(.secondary)).padding(20)
                    }
                    .zIndex(11)
            } else if vm.showSettings {
                SettingsView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(10)
            // ⌘K palette floats over everything; the scrim click-dismisses.
            } else if vm.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.nw.scrim
                        .ignoresSafeArea()
                        .onTapGesture { vm.showCommandPalette = false }
                    CommandPaletteView(vm: vm)
                        .padding(.top, AppLayout.paletteTop)
                }
                .zIndex(12)
            }
        }
        .environment(\.threadCommands, vm.threadCommands)
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .preferredColorScheme(themes.mode.colorScheme)
        .ignoresSafeArea()
        .onAppear { vm.systemAppearanceChanged(systemColorScheme) }
        .onChange(of: systemColorScheme) { vm.systemAppearanceChanged(systemColorScheme) }
        .sheet(isPresented: $vm.showNewAgentSheet) {
            NewAgentSheet(vm: vm)
        }
        .sheet(
            isPresented: Binding(
                get: { vm.worktreeSheetTarget != nil },
                set: { if !$0 { vm.worktreeSheetTarget = nil } }
            )
        ) {
            if let space = vm.state.spaces.first(where: { $0.id == vm.worktreeSheetTarget }) {
                NewWorktreeSheet(vm: vm, space: space)
            }
        }
        .sheet(item: $vm.finalizeRequest) { request in
            FinalizeWorktreeSheet(vm: vm, agent: request.agent, space: request.space)
        }
        .sheet(item: $vm.spacePickerTarget) { target in
            switch target {
            case .local:
                RemoteDirectoryPicker(
                    hostName: "this mac",
                    list: { path in try LocalDirectoryLister.list(path: path) },
                    choose: { path in
                        vm.spacePickerTarget = nil
                        Task { await vm.addSpace(at: URL(fileURLWithPath: path)) }
                    },
                    cancel: { vm.spacePickerTarget = nil }
                )
            case .importWorktree(let target):
                RemoteDirectoryPicker(
                    title: "Import Existing Worktree",
                    actionTitle: "Import",
                    hostName: "this mac",
                    startPath: target.startPath,
                    list: { path in try LocalDirectoryLister.list(path: path) },
                    choose: { path in
                        vm.spacePickerTarget = nil
                        Task {
                            await vm.importExistingCheckout(
                                at: URL(fileURLWithPath: path),
                                into: target.spaceID
                            )
                        }
                    },
                    cancel: { vm.spacePickerTarget = nil }
                )
            case .host(let hostID):
                if let connection = vm.remoteHosts.connections.first(where: { $0.id == hostID }) {
                    RemoteDirectoryPicker(
                        hostName: connection.config.name,
                        list: { path in
                            try await vm.remoteHosts.listDir(hostID: hostID, path: path)
                        },
                        choose: { path in
                            vm.spacePickerTarget = nil
                            Task {
                                do {
                                    _ = try await vm.addRemoteSpace(hostID: hostID, path: path)
                                } catch {
                                    NSLog("Shepherd: remote space creation failed: \(error)")
                                    NSSound.beep()
                                }
                            }
                        },
                        cancel: { vm.spacePickerTarget = nil }
                    )
                }
            }
        }
        .onChange(of: vm.remoteRenameTarget) {
            if let target = vm.remoteRenameTarget { renameDraft = vm.remoteAgent(target)?.name ?? "" }
        }
        .sheet(isPresented: Binding(
            get: { vm.remoteRenameTarget != nil },
            set: { if !$0 { vm.remoteRenameTarget = nil } }
        )) {
            RenameDialog(title: "Rename Agent", text: $renameDraft, onRename: {
                if let target = vm.remoteRenameTarget {
                    vm.performRemoteAction(target, action: .rename(name: renameDraft))
                }
                vm.remoteRenameTarget = nil
            }, onCancel: { vm.remoteRenameTarget = nil })
        }
        .sheet(isPresented: Binding(
            get: { vm.remoteWorktreeSheet != nil },
            set: { if !$0 { vm.remoteWorktreeSheet = nil } }
        )) {
            if let target = vm.remoteWorktreeSheet {
                RemoteWorktreeSheet(vm: vm, target: target, finalize: vm.remoteWorktreeFinalize)
            }
        }
        .alert("Agent action failed", isPresented: Binding(
            get: { vm.remoteActionError != nil },
            set: { if !$0 { vm.remoteActionError = nil } }
        )) {
            Button("OK") { vm.remoteActionError = nil }
        } message: { Text(vm.remoteActionError ?? "") }
        .onChange(of: vm.agentRenameTarget) {
            if let agent = vm.agent(id: vm.agentRenameTarget) {
                renameDraft = agent.name
            }
        }
        .onChange(of: vm.spaceRenameTarget) {
            if let id = vm.spaceRenameTarget,
               let space = vm.state.spaces.first(where: { $0.id == id }) {
                renameDraft = space.name
            }
        }
        .sheet(
            isPresented: Binding(
                get: { vm.spaceRenameTarget != nil },
                set: { if !$0 { vm.spaceRenameTarget = nil } }
            )
        ) {
            RenameDialog(
                title: "Rename Space",
                caption: "Sidebar label only — the folder on disk is not renamed.",
                text: $renameDraft,
                onRename: {
                    if let id = vm.spaceRenameTarget {
                        vm.renameSpace(id, to: renameDraft)
                    }
                    vm.spaceRenameTarget = nil
                },
                onCancel: { vm.spaceRenameTarget = nil }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { vm.agentRenameTarget != nil },
                set: { if !$0 { vm.agentRenameTarget = nil } }
            )
        ) {
            RenameDialog(
                title: "Rename Agent",
                text: $renameDraft,
                onRename: {
                    if let id = vm.agentRenameTarget {
                        vm.renameAgent(id, to: renameDraft)
                    }
                    vm.agentRenameTarget = nil
                },
                onCancel: { vm.agentRenameTarget = nil }
            )
        }
        .onChange(of: vm.worktreeDeleteTarget) {
            worktreeDeleteWarning = nil
            guard let agent = vm.agent(id: vm.worktreeDeleteTarget),
                  let branch = agent.worktreeBranch,
                  let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) else { return }
            worktreeDeleteWarning = GitWorktree.unreconciledWork(
                worktree: agent.worktreePath ?? GitWorktree.destination(repo: space.path, branch: branch),
                branch: branch
            )
        }
        .sheet(
            isPresented: Binding(
                get: { vm.worktreeDeleteTarget != nil },
                set: { if !$0 { vm.worktreeDeleteTarget = nil } }
            )
        ) {
            let agent = vm.agent(id: vm.worktreeDeleteTarget)
            let branch = agent?.worktreeBranch ?? ""
            let path = agent?.worktreePath ?? vm.state.spaces.first { $0.id == agent?.spaceID }
                .map { GitWorktree.destination(repo: $0.path, branch: branch) } ?? ""
            DialogSheet(
                title: "Delete Worktree Agent",
                subtitle: "Stops \(agent?.name ?? "the agent"). “Delete Agent & Worktree” also removes its checkout and branch.",
                width: 520,
                actions: [
                    DialogAction("Cancel", kind: .cancel) { vm.worktreeDeleteTarget = nil },
                    DialogAction("Delete Agent, Keep Worktree") {
                        confirmWorktreeDelete(removeWorktree: false)
                    },
                    DialogAction("Delete Agent & Worktree", kind: .destructive) {
                        confirmWorktreeDelete(removeWorktree: true)
                    },
                ]
            ) {
                SheetRow("Worktree") {
                    Text(path)
                        .font(Font.nwMono(11))
                        .foregroundStyle(Color.nw.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                SheetRow("Branch") {
                    Text(branch)
                        .font(Font.nwMono(11))
                        .foregroundStyle(Color.nw.textSecondary)
                }
                if let warning = worktreeDeleteWarning {
                    DialogWarning(text: "\(warning) will be lost with the worktree.")
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { vm.spaceDeleteTarget != nil },
                set: { if !$0 { vm.spaceDeleteTarget = nil } }
            )
        ) {
            let space = vm.state.spaces.first { $0.id == vm.spaceDeleteTarget }
            let count = vm.state.agents.count { $0.spaceID == vm.spaceDeleteTarget }
            DialogSheet(
                title: "Remove Space",
                subtitle: "Removes \(space?.name ?? "this space") from the sidebar and stops its "
                    + "\(count) agent\(count == 1 ? "" : "s"). Conversations stay on disk; the checkout "
                    + "is untouched. Nested project spaces are separate and survive.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { vm.spaceDeleteTarget = nil },
                    DialogAction("Remove Space", kind: .destructive) {
                        let id = vm.spaceDeleteTarget
                        vm.spaceDeleteTarget = nil
                        // Deleting a space tears down mounted terminal
                        // layouts — a huge view-tree change. Let the sheet
                        // finish dismissing first; mutating its host
                        // mid-dismissal wedges the modal session.
                        if let id {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(300))
                                vm.deleteSpace(id)
                            }
                        }
                    },
                ]
            )
        }
    }

    /// Same dismissal choreography as Remove Space: deleting tears down a
    /// mounted layout, so let the sheet finish dismissing first.
    private func confirmWorktreeDelete(removeWorktree: Bool) {
        let id = vm.worktreeDeleteTarget
        vm.worktreeDeleteTarget = nil
        guard let id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            vm.deleteWorktreeAgent(id, removeWorktree: removeWorktree)
        }
    }

    private var sidebarResizeHandle: some View {
        Color.nw.lineSubtle
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("root-layout"))
                            .onChanged { value in
                                liveSidebarWidth = AppSettings.clampSidebarWidth(Double(value.location.x))
                            }
                            .onEnded { _ in
                                if let width = liveSidebarWidth {
                                    appearance.sidebarWidth = width
                                }
                                liveSidebarWidth = nil
                            }
                    )
            }
            .zIndex(1)
    }
}

// MARK: Workspace header

/// The 52pt header over the workspace: the thread header for the agent on screen (local or
/// remote), else a breadcrumb. The window has no other title.
struct WorkspaceHeaderView: View {
    var vm: ShepherdViewModel

    /// With the sidebar hidden the header runs under the traffic lights.
    private var inset: CGFloat { vm.sidebarHidden ? 64 : 0 }

    var body: some View {
        Group {
            if let remote = vm.selectedRemoteAgent,
               let connection = vm.remoteHosts.connections.first(where: { $0.id == remote.hostID }),
               let agent = connection.state.agents.first(where: { $0.id == remote.agentID }) {
                if vm.remoteInspectingAgent == remote {
                    PlainHeader(project: "⌁ \(connection.config.name)", title: "\(agent.name) · terminal", leadingInset: inset)
                } else {
                    ThreadHeader(store: vm.remoteThreadStores.store(for: remote), project: "⌁ \(connection.config.name)",
                                 title: agent.name, leadingInset: inset, paneOpen: vm.isRightPaneOpen,
                                 togglePane: { vm.toggleRightPane() }, rename: { vm.remoteRenameTarget = remote })
                }
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID,
                      let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) {
                ThreadHeader(store: vm.threadStores.store(for: agent.id), project: space.name, title: agent.name,
                             leadingInset: inset, paneOpen: vm.isRightPaneOpen,
                             togglePane: { vm.toggleRightPane() }, rename: { vm.agentRenameTarget = agent.id })
            } else if let space = vm.selectedSpace {
                PlainHeader(project: space.name, title: "No agent selected", leadingInset: inset)
            } else {
                PlainHeader(project: "Shepherd", title: "No agent selected", leadingInset: inset)
            }
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}
