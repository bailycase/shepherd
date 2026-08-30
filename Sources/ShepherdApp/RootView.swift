import SwiftUI
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
            // Left column: flat sidebar surface runs continuously behind the
            // traffic lights and the tree. No vibrancy material — the design
            // is flat color everywhere.
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Metrics.trafficLightHeight)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                SidebarView(vm: vm)
            }
            .frame(width: CGFloat(liveSidebarWidth ?? appearance.sidebarWidth))
            .background(Tokens.sidebarBg.ignoresSafeArea())
            // Rebuild chrome (not terminal panes) when density/text scale
            // change; fonts and metrics are read inside row bodies where
            // SwiftUI's input diffing cannot see them.
            .id(appearance.appearanceKey)

            sidebarResizeHandle

            VStack(spacing: 0) {
                WorkspaceHeaderView(vm: vm)
                WorkspaceView(vm: vm)
            }
            .background(Tokens.workspaceBg)
        }
        .coordinateSpace(name: "root-layout")
        .overlay {
            if vm.showSettings {
                SettingsView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(10)
            // ⌘K palette floats over everything; the dimmer click-dismisses.
            } else if vm.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { vm.showCommandPalette = false }
                    CommandPaletteView(vm: vm)
                        .padding(.top, 90)
                }
            }
        }
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
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
        .onChange(of: vm.shellRenameTarget) {
            if let id = vm.shellRenameTarget,
               let shell = vm.state.tabs.first(where: { $0.id == id }) {
                renameDraft = ShepherdViewModel.shellLabel(shell)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { vm.shellRenameTarget != nil },
                set: { if !$0 { vm.shellRenameTarget = nil } }
            )
        ) {
            RenameDialog(
                title: "Rename Shell",
                text: $renameDraft,
                onRename: {
                    if let id = vm.shellRenameTarget {
                        vm.renameShell(id, to: renameDraft)
                    }
                    vm.shellRenameTarget = nil
                },
                onCancel: { vm.shellRenameTarget = nil }
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
                SheetRow("worktree") {
                    Text(path)
                        .font(Fonts.mono(11))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                SheetRow("branch") {
                    Text(branch)
                        .font(Fonts.mono(11))
                        .foregroundStyle(Tokens.textSecondary)
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
    /// mounted terminal layout, so let the alert finish dismissing first.
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
        Tokens.separator
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

/// The 42pt strip above the pane frame: `space / agent` breadcrumb and
/// trailing `status ⟨age⟩` in the status color. This is the selected agent's
/// identity line — the window has no other title.
struct WorkspaceHeaderView: View {
    var vm: ShepherdViewModel
    /// Re-render on density/text-scale changes; never `.id`-keyed — that
    /// would remount, which is harmless here but banned near terminal panes.
    @ObservedObject private var appearance = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            if let remote = vm.selectedRemoteAgent,
               let connection = vm.remoteHosts.connections.first(where: { $0.id == remote.hostID }) {
                let agent = connection.state.agents.first { $0.id == remote.agentID }
                breadcrumb(space: "⌁ \(connection.config.name)", leaf: agent?.name ?? "agent")
                Spacer(minLength: 0)
                if let agent {
                    statusLabel(agent)
                }
            } else if let shellID = vm.selectedShellID,
               let shell = vm.state.tabs.first(where: { $0.id == shellID }) {
                breadcrumb(space: "shells", leaf: ShepherdViewModel.shellLabel(shell))
                Spacer(minLength: 0)
            } else if let agent = vm.selectedAgent,
               let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) {
                breadcrumb(
                    space: space.name,
                    leaf: vm.inspectingAgentID == agent.id ? "\(agent.name) / subagents" : agent.name
                )
                Spacer(minLength: 0)
                statusLabel(agent)
            } else if let space = vm.selectedSpace {
                breadcrumb(space: space.name, leaf: "shell")
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Tokens.workspaceBg)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func breadcrumb(space: String, leaf: String) -> some View {
        HStack(spacing: 5) {
            Text(space)
                .font(Fonts.mono(12.5))
                .foregroundStyle(Tokens.textSecondary)
            Text("/")
                .font(Fonts.mono(12.5))
                .foregroundStyle(Tokens.textDim)
            Text(leaf)
                .font(Fonts.mono(12.5, .semibold))
                .foregroundStyle(Tokens.textPrimary)
        }
        .lineLimit(1)
    }

    private func statusLabel(_ agent: Agent) -> some View {
        // The idle dot color is deliberately near-invisible; text needs the
        // metadata ramp to stay readable.
        let color = agent.status == .idle ? Tokens.textMetadata : Tokens.statusColor(agent.status)
        // TimelineView drives the once-a-second re-render; without it the age
        // only updates when some unrelated state change repaints the header.
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            let age = vm.statusAge(for: agent.id).map { " \($0)" } ?? ""
            Text(agent.status.rawValue + age)
                .font(Fonts.mono(11))
                .foregroundStyle(color)
        }
    }
}
