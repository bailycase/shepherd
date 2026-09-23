import SwiftUI
import Combine
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdRemote

struct RootView: View {
    @Bindable var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var appearance: AppSettings
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var renameDraft = ""
    @State private var liveSidebarWidth: Double?
    /// Unreconciled-work warning for the Delete Worktree Agent alert,
    /// computed once when the target is set (a couple of quick git probes).
    @State private var worktreeDeleteWarning: String?
    @State private var windowWidth = AppLayout.windowDefaultWidth
    /// In full screen the window controls are gone, so nothing needs to clear them.
    @State private var isFullScreen = false

    init(vm: ShepherdViewModel) {
        self.vm = vm
        _appearance = ObservedObject(wrappedValue: vm.settings)
    }

    private var sidebar: ShellLayout.Sidebar {
        ShellLayout.sidebar(windowWidth: windowWidth, preferredWidth: CGFloat(liveSidebarWidth ?? appearance.sidebarWidth),
                            userHidden: vm.sidebarHidden, overlayShown: vm.sidebarOverlayShown)
    }

    var body: some View {
        let sidebar = sidebar
        let docked = sidebar.mode == .docked
        HStack(spacing: 0) {
            // The flat base runs continuously behind the window controls and the tree. ⇧⌘S
            // hides it; a window too narrow to dock it overlays it instead. It keeps its width
            // while a right pane is open.
            if docked {
                SidebarView(vm: vm)
                    .frame(width: sidebar.width)
                    .background(Color.nw.bgBase.ignoresSafeArea())
                sidebarResizeHandle(width: sidebar.width)
            }

            VStack(spacing: 0) {
                WorkspaceHeaderView(
                    vm: vm,
                    leadingInset: docked || isFullScreen ? 0 : AppLayout.trafficLightInset,
                    showSidebar: docked ? nil : { vm.toggleSidebar() }
                )
                WorkspaceView(vm: vm)
            }
            .frame(maxWidth: .infinity)
            .background(Color.nw.bgWindow)
        }
        .coordinateSpace(.named("root-layout"))
        .overlay(alignment: .leading) {
            if sidebar.mode == .overlay {
                sidebarOverlay(width: sidebar.width)
            }
        }
        .overlay {
            if vm.showComponentGallery {
                ComponentGallery()
                    .overlay(alignment: .topTrailing) {
                        Button("Close") { vm.showComponentGallery = false }
                            .buttonStyle(NWButtonStyle(.secondary)).padding(20)
                    }
            } else if vm.showSettings {
                SettingsView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ⌘K floats over everything, 18% down and capped to the window; the scrim dismisses.
        .nwCommandPalette(isPresented: Binding(
            get: { vm.showCommandPalette && !vm.showSettings && !vm.showComponentGallery },
            set: { vm.showCommandPalette = $0 }
        )) {
            CommandPaletteView(vm: vm)
        }
        .background { MenuStateSync(vm: vm) }
        .nwDensity(appearance.sidebarRowDensity)
        .environment(\.threadCommands, vm.threadCommands)
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowWidth = width
            vm.setSidebarAutoHidden(ShellLayout.sidebar(windowWidth: width, preferredWidth: CGFloat(appearance.sidebarWidth),
                                                        userHidden: vm.sidebarHidden, overlayShown: false).autoHidden)
        }
        .preferredColorScheme(themes.mode.colorScheme)
        .ignoresSafeArea()
        .onAppear {
            vm.systemAppearanceChanged(systemColorScheme)
            MainWindow.open = { [openWindow] in openWindow(id: MainWindow.id) }
        }
        .onChange(of: systemColorScheme) { vm.systemAppearanceChanged(systemColorScheme) }
        // The overlaid sidebar is for picking: it closes once something is picked.
        .onChange(of: vm.selectedAgentID) { vm.dismissSidebarOverlay() }
        .onChange(of: vm.selectedRemoteAgent) { vm.dismissSidebarOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in isFullScreen = false }
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

    /// The sidebar over the workspace in a window too narrow to dock it. Clicking outside
    /// closes it, as does picking a row.
    private func sidebarOverlay(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.dismissSidebarOverlay() }
                .accessibilityHidden(true)
            SidebarView(vm: vm)
                .frame(width: width)
                .background(Color.nw.bgBase.ignoresSafeArea())
                .overlay(alignment: .trailing) { NWHairline(.vertical) }
                .shadow(color: Color.nw.popoverShadow, radius: 16)
        }
    }

    /// The sidebar's trailing edge, and its drag handle (adjustable with VoiceOver). Resizing
    /// never narrows the main column below its minimum.
    private func sidebarResizeHandle(width: CGFloat) -> some View {
        Color.nw.lineSubtle
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("root-layout"))
                            .onChanged { liveSidebarWidth = fittedSidebarWidth(Double($0.location.x)) }
                            .onEnded { _ in
                                if let width = liveSidebarWidth {
                                    appearance.sidebarWidth = width
                                }
                                liveSidebarWidth = nil
                            }
                    )
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 16 : direction == .decrement ? -16 : 0
                appearance.sidebarWidth = fittedSidebarWidth(Double(width) + step)
            }
    }

    /// A sidebar width within its range that leaves the main column its minimum.
    private func fittedSidebarWidth(_ width: Double) -> Double {
        AppSettings.clampSidebarWidth(min(width, Double(windowWidth - 1 - AppLayout.mainColumnMinWidth)))
    }
}

// MARK: Workspace header

/// The 44pt toolbar over the workspace: the thread toolbar for the agent on screen (local or
/// remote), else the space's name. The window has no other title.
struct WorkspaceHeaderView: View {
    var vm: ShepherdViewModel
    /// Clears the window controls while the sidebar is not docked (zero in full screen).
    var leadingInset: CGFloat = 0
    /// Shown while the sidebar is not docked.
    var showSidebar: (() -> Void)?
    @ObservedObject private var keys: KeybindingsStore

    init(vm: ShepherdViewModel, leadingInset: CGFloat = 0, showSidebar: (() -> Void)? = nil) {
        self.vm = vm
        self.leadingInset = leadingInset
        self.showSidebar = showSidebar
        _keys = ObservedObject(wrappedValue: vm.keybindings)
    }

    var body: some View {
        Group {
            if let remote = vm.selectedRemoteAgent,
               let connection = vm.remoteHosts.connections.first(where: { $0.id == remote.hostID }),
               let agent = connection.state.agents.first(where: { $0.id == remote.agentID }) {
                if vm.remoteInspectingAgent == remote {
                    PlainHeader(title: "\(agent.name) · terminal", leadingInset: leadingInset, showSidebar: showSidebar)
                } else {
                    threadHeader(store: vm.remoteThreadStores.store(for: remote), project: "⌁ \(connection.config.name)",
                                 title: agent.name, rename: { vm.remoteRenameTarget = remote })
                }
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID,
                      let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) {
                threadHeader(store: vm.threadStores.store(for: agent.id), project: space.name, title: agent.name,
                             rename: { vm.agentRenameTarget = agent.id })
            } else {
                PlainHeader(title: vm.selectedSpace?.name ?? "Shepherd", leadingInset: leadingInset, showSidebar: showSidebar)
            }
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func threadHeader(store: NativeThreadStore, project: String, title: String, rename: @escaping () -> Void) -> ThreadHeader {
        ThreadHeader(store: store, project: project, title: title, leadingInset: leadingInset, showSidebar: showSidebar,
                     reviewOpen: vm.isReviewPaneShowing, inspectorOpen: vm.isInspectorShowing,
                     reviewShortcut: keys.display(.toggleRightPane), inspectShortcut: keys.display(.inspectSubagent),
                     toggleReview: { vm.toggleReviewPane() }, toggleSubagents: { vm.toggleSubagentPane() }, rename: rename)
    }
}
