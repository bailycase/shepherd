import SwiftUI
import Combine
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdRemote

struct RootView: View {
    @Bindable var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    private var updater: AppUpdater { .shared }
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var liveSidebarWidth: Double?
    @State private var windowWidth = AppLayout.windowDefaultWidth
    /// In full screen the window controls are gone, so nothing needs to clear them.
    @State private var isFullScreen = false

    private var appearance: AppSettings { vm.settings }

    private var sidebar: ShellLayout.Sidebar {
        ShellLayout.sidebar(windowWidth: windowWidth, preferredWidth: CGFloat(liveSidebarWidth ?? appearance.sidebarWidth),
                            userHidden: vm.sidebarHidden, overlayShown: vm.sidebarOverlayShown)
    }

    var body: some View {
        let _ = NWRenderProbe.tick("shell.root")
        let sidebar = sidebar
        // The side pane maximized over the window (ChangesWide): its rail takes the sidebar's
        // place and the toolbar's, and draws the window controls.
        let wide = vm.isSidePaneWide
        let docked = sidebar.mode == .docked && !wide
        HStack(spacing: 0) {
            if wide {
                NWSidePaneRail(windowControls: isFullScreen ? nil : NWWindowControls(
                    close: { MainWindow.window?.performClose(nil) },
                    minimize: { MainWindow.window?.performMiniaturize(nil) },
                    zoom: { MainWindow.window?.toggleFullScreen(nil) }
                ), back: { vm.restoreWideSidePane() })
                // The column takes the window at once (easing it would relay out the layout on
                // each frame); the pane's own growth carries the motion.
                .ignoresSafeArea()
            }
            // The flat base runs continuously behind the window controls and the tree. ⇧⌘S
            // hides it; a window too narrow to dock it overlays it instead. It keeps its width
            // while a right pane is open.
            if docked {
                HStack(spacing: 0) {
                    SidebarView(vm: vm)
                        .frame(width: sidebar.width)
                        .background(Color.nw.bgBase.ignoresSafeArea())
                    sidebarResizeHandle(width: sidebar.width)
                }
                // Over the main column, which takes its new frame at once as it slides.
                .zIndex(1)
                .nwTransition(.pane, edge: .leading)
            }

            VStack(spacing: 0) {
                if !wide {
                    WorkspaceHeaderView(
                        vm: vm,
                        leadingInset: docked || isFullScreen ? 0 : AppLayout.trafficLightInset,
                        showSidebar: docked ? nil : { vm.toggleSidebar() }
                    )
                    // Over the workspace: the side-pane button's tip hangs below the toolbar.
                    .zIndex(1)
                }
                // Once, after an update moved this copy off the retired nightly channel. It
                // leaves at once: easing the column's height would relay out every mounted
                // layout on each frame.
                if updater.nightlyMovedNoticePending {
                    NightlyMovedNotice(download: { updater.downloadShepherdNightly() },
                                       dismiss: { updater.dismissNightlyMovedNotice() })
                }
                WorkspaceView(vm: vm)
            }
            // A page (New thread, Automations, Hosts) covers the whole column, toolbar included;
            // the layouts under it stay mounted and hidden, as when switching agents.
            .overlay {
                DestinationLayer(vm: vm, chrome: PageHeaderChrome(
                    leadingInset: docked || isFullScreen ? 0 : AppLayout.trafficLightInset,
                    showSidebar: docked ? nil : { vm.toggleSidebar() }))
            }
            .frame(maxWidth: .infinity)
            .background(Color.nw.bgWindow)
            // Every mounted layout reflows when the column's width changes; relaid out on each
            // frame of the slide they drop frames, so the column snaps as the sidebar moves.
            .animation(nil, value: docked)
        }
        // What the sliding sidebar uncovers reads as its own base.
        .background(Color.nw.bgBase.ignoresSafeArea())
        // ⇧⌘S, the toolbar's button, the palette: the docked sidebar slides from the leading
        // edge. Keyed on the preference alone: a window resize that docks or undocks it is instant.
        .nwAnimation(.pane, value: vm.sidebarHidden)
        // The rail draws the window controls; the window's own hide while it shows.
        .background { SystemWindowControls(hidden: wide && !isFullScreen) }
        .coordinateSpace(.named("root-layout"))
        .overlay(alignment: .leading) {
            sidebarOverlay(width: sidebar.width, shown: sidebar.mode == .overlay && !wide)
                // A resize that crosses the fit point closes the overlay at once.
                .animation(nil, value: vm.sidebarAutoHidden)
                .nwAnimation(.pane, value: vm.sidebarOverlayShown)
        }
        .overlay {
            if vm.showComponentGallery {
                ComponentGallery()
                    .overlay(alignment: .topTrailing) {
                        Button("Close") { vm.showComponentGallery = false }
                            .buttonStyle(NWButtonStyle(.secondary)).padding(NW.Space.xl)
                    }
            } else if vm.showSettings {
                SettingsView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Export (DZExport) sits over the whole window on its own scrim.
        .overlay { DesignExportOverlay(vm: vm) }
        // ⌘K floats over everything, 18% down and capped to the window; the scrim dismisses.
        .nwCommandPalette(isPresented: Binding(
            get: { vm.showCommandPalette && !vm.showSettings && !vm.showComponentGallery },
            set: { vm.showCommandPalette = $0 }
        )) {
            CommandPaletteView(vm: vm)
        }
        .background { MenuStateSync(vm: vm) }
        .background { MainWindowReader() }
        .nwDensity(appearance.sidebarRowDensity)
        .environment(\.threadCommands, vm.threadCommands)
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        // Only the width the shell's layout can tell apart: past the widest window that still
        // narrows the sidebar, a resize changes nothing here, so it reruns none of this.
        .onGeometryChange(for: CGFloat.self) { ShellLayout.layoutWidth($0.size.width) } action: { width in
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
        .modifier(SidebarOverlayDismissal(vm: vm))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in isFullScreen = false }
        .modifier(AppDialogs(vm: vm))
    }

    /// The sidebar over the workspace in a window too narrow to dock it; it slides in from the
    /// leading edge. Clicking outside closes it, as does picking a row.
    private func sidebarOverlay(width: CGFloat, shown: Bool) -> some View {
        ZStack(alignment: .leading) {
            if shown {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { vm.dismissSidebarOverlay() }
                    .accessibilityHidden(true)
                SidebarView(vm: vm)
                    .frame(width: width)
                    // The shadow from the fill, never from the scrolling list over it.
                    .nwFloatBackground(Color.nw.bgBase.ignoresSafeArea())
                    .overlay(alignment: .trailing) { NWHairline(.vertical) }
                    .nwTransition(.pane, edge: .leading)
            }
        }
    }

    /// The sidebar's trailing edge, and its drag handle (adjustable with VoiceOver). Resizing
    /// never narrows the main column below its minimum.
    private func sidebarResizeHandle(width: CGFloat) -> some View {
        Color.nw.lineSubtle
            .frame(width: AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
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
                let step = Double(direction == .increment ? AppLayout.sidebarAdjustStep
                                  : direction == .decrement ? -AppLayout.sidebarAdjustStep : 0)
                appearance.sidebarWidth = fittedSidebarWidth(Double(width) + step)
            }
    }

    /// A sidebar width within its range that leaves the main column its minimum.
    private func fittedSidebarWidth(_ width: Double) -> Double {
        AppSettings.clampSidebarWidth(min(width, Double(windowWidth - AppLayout.dividerWidth - AppLayout.mainColumnMinWidth)))
    }
}

/// Hides the window's close, minimize and zoom while the maximized side pane's rail draws its
/// own (ChangesWide), and shows them again after.
private struct SystemWindowControls: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ reader: Reader, context: Context) {
        reader.controlsHidden = hidden
        reader.apply()
    }

    final class Reader: NSView {
        var controlsHidden = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.isHidden != controlsHidden {
                    button.isHidden = controlsHidden
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Closes the overlaid sidebar once something is picked. Its own view, so a selection reruns
/// this and not the root view around it.
private struct SidebarOverlayDismissal: ViewModifier {
    var vm: ShepherdViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: vm.selectedAgentID) { vm.dismissSidebarOverlay() }
            .onChange(of: vm.selectedRemoteAgent) { vm.dismissSidebarOverlay() }
            .onChange(of: vm.destination) { vm.dismissSidebarOverlay() }
    }
}

/// The page the main column shows in place of a thread, if any. Its own view, so a page coming
/// or going reruns this and not the root view around it.
private struct DestinationLayer: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome

    var body: some View {
        switch vm.shownDestination {
        case .newThread?: NewThreadPage(vm: vm, chrome: chrome)
        case .designs?: DesignsDestination(vm: vm, chrome: chrome)
        case .newDesign?: NewDesignPage(vm: vm, chrome: chrome)
        case .designSystem?: DesignSystemDestination(vm: vm, chrome: chrome)
        case .automations?: AutomationsDestination(vm: vm, chrome: chrome)
        case .hosts?: HostsDestination(vm: vm, chrome: chrome)
        case nil: EmptyView()
        }
    }
}

// MARK: Workspace header

/// The 44pt toolbar over the workspace: the thread toolbar for the agent on screen (local or
/// remote), else the space's name. The window has no other title. It sits over the workspace, so
/// the side-pane button's tip can hang below it.
struct WorkspaceHeaderView: View {
    var vm: ShepherdViewModel
    /// Clears the window controls while the sidebar is not docked (zero in full screen).
    var leadingInset: CGFloat = 0
    /// Shown while the sidebar is not docked.
    var showSidebar: (() -> Void)?

    private var keys: KeybindingsStore { vm.keybindings }

    var body: some View {
        Group {
            if let remote = vm.selectedRemoteAgent,
               let connection = vm.remoteHosts.connections.first(where: { $0.id == remote.hostID }),
               let agent = connection.state.agents.first(where: { $0.id == remote.agentID }) {
                if vm.remoteInspectingAgent == remote {
                    PlainHeader(title: "\(agent.name) · terminal", leadingInset: leadingInset, showSidebar: showSidebar)
                } else if let (_, design) = vm.remoteDesign(drawnBy: remote) {
                    // The host's design: its system's page and Export stay on the host for now.
                    DesignToolbar(name: design.name, system: design.systemNamespace, leadingInset: leadingInset,
                                  showSidebar: showSidebar, designs: { vm.openDestination(.designs) },
                                  screen: vm.remoteDesignScreen(RemoteDesignRef(hostID: remote.hostID, designID: design.id)))
                        .equatable()
                        .id(remote)
                } else {
                    let space = connection.state.spaces.first { $0.id == agent.spaceID }?.name
                    threadHeader(store: vm.remoteThreadStores.store(for: remote), owner: .remote(remote),
                                 project: space ?? connection.config.name, title: agent.name,
                                 branch: AgentBranchLabel(agent: agent, host: connection.config.name), directory: nil,
                                 showChanges: { vm.openRemoteReview(remote, path: nil) }, rename: { vm.remoteRenameTarget = remote })
                        .id(remote)
                }
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID, let design = vm.design(drawnBy: agent),
                      design.buildsSystem {
                DesignSystemHeader(model: vm.designSystemPage(.build(design.id)), toolbar: true, leadingInset: leadingInset,
                                   showSidebar: showSidebar, designs: { vm.openDestination(.designs) })
                    .equatable()
                    .id(agent.id)
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID, let design = vm.design(drawnBy: agent) {
                let system = design.systemNamespace.flatMap { vm.designSystems.summary($0) }?.namespace
                DesignToolbar(name: design.name, system: vm.designSystemName(design),
                              swatches: vm.designSystemSwatches(system, count: 3),
                              openSystem: system.map { namespace in { vm.openDesignSystem(namespace) } }, leadingInset: leadingInset,
                              showSidebar: showSidebar, designs: { vm.openDestination(.designs) }, screen: vm.designScreen(design.id),
                              export: { vm.openDesignExport(design.id) })
                    .equatable()
                    .id(agent.id)
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID,
                      let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) {
                threadHeader(store: vm.threadStores.store(for: agent.id), owner: .local(agent.id), project: space.name, title: agent.name,
                             branch: AgentBranchLabel(agent: agent), directory: vm.checkoutDirectory(of: agent.id),
                             showChanges: { vm.openReview(agentID: agent.id, path: nil) }, rename: { vm.agentRenameTarget = agent.id })
                    // One toolbar per agent: switching replaces it at once instead of animating
                    // one agent's chip and pane button into another's.
                    .id(agent.id)
            } else {
                PlainHeader(title: vm.selectedSpace?.name ?? "Shepherd", leadingInset: leadingInset, showSidebar: showSidebar)
            }
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        // Switching agents is a visibility flip: the next agent's toolbar lands at once, even when
        // the switch rides an animation (the palette closing), and its controls (a pane toggle,
        // the counters) don't fade their own state into it.
        .transaction(value: vm.selectedAgentID, Self.switchAtOnce)
        .transaction(value: vm.selectedRemoteAgent, Self.switchAtOnce)
    }

    private static func switchAtOnce(_ transaction: inout Transaction) {
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    /// Compared by value: this header reruns for every status report, and the toolbar under it
    /// reruns only when what it shows changed.
    private func threadHeader(store: NativeThreadStore, owner: SidePaneOwner, project: String, title: String,
                              branch: AgentBranchLabel?, directory: String?, showChanges: @escaping () -> Void,
                              rename: @escaping () -> Void) -> EquatableView<ThreadHeader> {
        let pane = vm.sidePaneButton(for: owner)
        return ThreadHeader(store: store, project: project, title: title, leadingInset: leadingInset, showSidebar: showSidebar,
                            branch: branch, directory: directory,
                            paneOpen: pane.isOn, paneNews: pane.news, paneShortcut: keys.display(.toggleRightPane),
                            togglePane: { vm.toggleRightPane() }, showChanges: showChanges, rename: rename)
            .equatable()
    }
}
