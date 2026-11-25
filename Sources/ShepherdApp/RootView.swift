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
    /// The window is mid live resize (its drag, not a frame set in code): threads lay out
    /// only the rows that cover them while it lasts (`ThreadView.eagerCount`).
    @State private var windowLiveResizing = false
    @State private var windowWidth = AppLayout.windowDefaultWidth
    /// In full screen the window controls are gone, so nothing needs to clear them.
    @State private var isFullScreen = false

    private var appearance: AppSettings { vm.settings }

    private var sidebar: ShellLayout.Sidebar {
        ShellLayout.sidebar(windowWidth: windowWidth, preferredWidth: CGFloat(liveSidebarWidth ?? appearance.sidebarWidth),
                            userHidden: vm.sidebarHidden, overlayShown: vm.sidebarOverlayShown)
    }

    var body: some View {
        let _ = SHRenderProbe.tick("shell.root")
        let sidebar = sidebar
        // The side pane maximized over the window (ChangesWide): its rail takes the sidebar's
        // place and the toolbar's, and draws the window controls.
        let wide = vm.isSidePaneWide
        let docked = sidebar.mode == .docked && !wide
        HStack(spacing: 0) {
            if wide {
                SHSidePaneRail(windowControls: isFullScreen ? nil : SHWindowControls(
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
                // The glass panel, inset from the window's leading, top and bottom edges; its
                // trailing edge is the resize handle.
                SidebarView(vm: vm)
                    .frame(width: sidebar.width)
                    .overlay(alignment: .trailing) { sidebarResizeHandle(width: sidebar.width) }
                    .padding([.leading, .vertical], SHSidebarMetrics.panelInset)
                // Over the main column, which takes its new frame at once as it slides.
                .zIndex(1)
                .shTransition(.pane, edge: .leading)
            }

            // The toolbar rides over the column's top: a thread's pane card runs up beside it (GXSidePane), so the
            // toolbar ends where the card begins and the workspace starts under it (`workspaceTopInset`).
            let noticed = updater.nightlyMovedNoticePending
            let toolbar = wide ? 0 : AppLayout.headerHeight + AppLayout.toolbarTop
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Once, after an update moved this copy off the retired nightly channel. It
                    // leaves at once: easing the column's height would relay out every mounted
                    // layout on each frame.
                    if noticed {
                        Color.clear.frame(height: toolbar)
                        NightlyMovedNotice(download: { updater.downloadShepherdNightly() },
                                           dismiss: { updater.dismissNightlyMovedNotice() })
                    }
                    WorkspaceView(vm: vm)
                        .environment(\.workspaceTopInset, noticed ? 0 : toolbar)
                }
                if !wide {
                    WorkspaceHeaderView(
                        vm: vm,
                        leadingInset: docked || isFullScreen ? 0 : AppLayout.trafficLightInset,
                        showSidebar: docked ? nil : { vm.toggleSidebar() }
                    )
                    // The boards' window padding: the toolbar's row is the sidebar top bar's and the window controls'.
                    .padding(.top, AppLayout.toolbarTop)
                    .background(Color.sh.bgWindow)
                    .modifier(PaneReserve(vm: vm))
                    // Over the workspace: the side-pane button's tip hangs below the toolbar.
                    .zIndex(1)
                }
            }
            // A page (New thread, Automations, Hosts) covers the whole column, toolbar included;
            // the layouts under it stay mounted and hidden, as when switching agents.
            .overlay {
                DestinationLayer(vm: vm, chrome: PageHeaderChrome(
                    leadingInset: docked || isFullScreen ? 0 : AppLayout.trafficLightInset,
                    showSidebar: docked ? nil : { vm.toggleSidebar() }))
            }
            // A deletion's toast, over the bottom of the column (DesignDeleted).
            .overlay { DesignToastLayer(vm: vm) }
            .frame(maxWidth: .infinity)
            .background(Color.sh.bgWindow)
            // Every mounted layout reflows when the column's width changes; relaid out on each
            // frame of the slide they drop frames, so the column snaps as the sidebar moves.
            .animation(nil, value: docked)
        }
        // What the sliding sidebar uncovers reads as its own base.
        .background(Color.sh.bgBase.ignoresSafeArea())
        // ⇧⌘S, the toolbar's button, the palette: the docked sidebar slides from the leading
        // edge. Keyed on the preference alone: a window resize that docks or undocks it is instant.
        .shAnimation(.pane, value: vm.sidebarHidden)
        // The rail draws the window controls; the window's own hide while it shows.
        .background { SystemWindowControls(hidden: wide && !isFullScreen) }
        .coordinateSpace(.named("root-layout"))
        .overlay(alignment: .leading) {
            sidebarOverlay(width: sidebar.width, shown: sidebar.mode == .overlay && !wide)
                // A resize that crosses the fit point closes the overlay at once.
                .animation(nil, value: vm.sidebarAutoHidden)
                .shAnimation(.pane, value: vm.sidebarOverlayShown)
        }
        .overlay {
            if vm.showComponentGallery {
                ComponentGallery()
                    .overlay(alignment: .topTrailing) {
                        Button("Close") { vm.showComponentGallery = false }
                            .buttonStyle(SHButtonStyle(.secondary)).padding(SH.Space.xl)
                    }
            }
        }
        .overlay { SettingsOverlay(vm: vm) }
        // Export (DZExport) sits over the whole window on its own scrim.
        .overlay { DesignExportOverlay(vm: vm) }
        .overlay { DesignGitSheetsOverlay(vm: vm) }
        .overlay { ImplementSheetOverlay(vm: vm) }
        // Over a design, the palette's chord jumps to a board instead (JumpInContext).
        .overlay { DesignJumpOverlay(vm: vm) }
        .overlay { ImageViewerOverlay(vm: vm) }
        .overlay { FileViewerOverlay(vm: vm) }
        .overlay { DiagramViewerOverlay(vm: vm) }
        // ⌘K floats over everything, 18% down and capped to the window; the scrim dismisses.
        .shCommandPalette(isPresented: Binding(
            get: { vm.showCommandPalette && !vm.showSettings && !vm.showComponentGallery },
            set: { vm.showCommandPalette = $0 }
        )) {
            CommandPaletteView(vm: vm)
        }
        .background { MenuStateSync(vm: vm) }
        .background { ThreadLinksSync(vm: vm) }
        .background { MainWindowReader() }
        .shDensity(appearance.sidebarRowDensity)
        .environment(\.threadCommands, vm.threadCommands)
        .environment(\.presentImages, ImageViewerPresenter(model: vm))
        .environment(\.hookPresenter, HookPresenter(model: vm))
        .environment(\.threadReaderPins, vm.threadReaderPins)
        .environment(\.userActivity, vm.userActivity)
        .environment(\.liveResizing, windowLiveResizing)
        .environment(\.shDiagramPresentation, vm.diagramPresentation)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
            if let window = vm.workspaceColumn.window, note.object as? NSWindow === window { windowLiveResizing = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            if let window = vm.workspaceColumn.window, note.object as? NSWindow === window { windowLiveResizing = false }
        }
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
                    // The panel floats on the popover's shadow, cast by a fill under it.
                    .background { RoundedRectangle(cornerRadius: SH.Radius.xl).fill(Color.sh.bgWindow).shFloatShadow() }
                    .padding([.leading, .vertical], SHSidebarMetrics.panelInset)
                    .shTransition(.pane, edge: .leading)
            }
        }
    }

    /// The sidebar's trailing edge, and its drag handle (adjustable with VoiceOver). Resizing
    /// never narrows the main column below its minimum.
    private func sidebarResizeHandle(width: CGFloat) -> some View {
        Color.clear
            .frame(width: AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("root-layout"))
                            .onChanged { liveSidebarWidth = fittedSidebarWidth(Double($0.location.x - AppLayout.sidebarGutter)) }
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
        AppSettings.clampSidebarWidth(min(width, Double(windowWidth - AppLayout.sidebarGutter - AppLayout.mainColumnMinWidth)))
    }
}

/// Places the window's close, minimize and zoom on the 44pt row the sidebar's top bar and the toolbar share
/// (GXThread, GXSidebarHidden): the close button's centre `AppLayout.windowControlsCenter` from the window's top
/// leading corner, the others at AppKit's own spacing. Hides them while the maximized side pane's rail draws its
/// own (ChangesWide), and shows them again after. In full screen AppKit owns them and they are left alone.
private struct SystemWindowControls: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ reader: Reader, context: Context) {
        reader.controlsHidden = hidden
        reader.apply()
    }

    final class Reader: NSView {
        var controlsHidden = false
        private var observed: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observed.forEach(NotificationCenter.default.removeObserver)
            observed = []
            if let window {
                // AppKit lays the title bar out again on these, putting the buttons back where it keeps them.
                let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                                  NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                                  NSWindow.didResignKeyNotification, NSWindow.didChangeBackingPropertiesNotification]
                observed = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    }
                }
            }
            apply()
        }

        isolated deinit { observed.forEach(NotificationCenter.default.removeObserver) }

        func apply() {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            for button in buttons where button.isHidden != controlsHidden { button.isHidden = controlsHidden }
            guard !controlsHidden, !window.styleMask.contains(.fullScreen) else { return }
            place(buttons, in: window)
        }

        /// Grows the title bar's container to hold the row, then sets each button's centre on it.
        private func place(_ buttons: [NSButton], in window: NSWindow) {
            guard let first = buttons.first, let bar = first.superview, let container = bar.superview else { return }
            let center = AppLayout.windowControlsCenter
            let height = 2 * center.y
            let frame = window.frame
            let wanted = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
            if container.frame != wanted { container.frame = wanted }
            if bar.frame != container.bounds { bar.frame = container.bounds }
            // AppKit's spacing between the buttons, kept as it draws them.
            let pitch = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.minX : 0
            for (index, button) in buttons.enumerated() {
                let size = button.frame.size
                let y = bar.isFlipped ? center.y - size.height / 2 : bar.bounds.height - center.y - size.height / 2
                let origin = NSPoint(x: (center.x - first.frame.width / 2 + CGFloat(index) * pitch).rounded(),
                                     y: y.rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
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
        case .forge?: ForgeDestination(vm: vm, chrome: chrome)
        case .fleet?: FleetDestination(vm: vm, chrome: chrome)
        case .project?: LogicalProjectDestination(vm: vm, chrome: chrome)
        case .projectSettings?: LogicalProjectSettingsDestination(vm: vm, chrome: chrome)
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
               let connection = vm.remoteHosts.allConnections.first(where: { $0.id == remote.hostID }),
               let agent = connection.state.agents.first(where: { $0.id == remote.agentID }) {
                if vm.remoteInspectingAgent == remote {
                    PlainHeader(title: "\(vm.presentedThreadName(.remote(remote), hostName: agent.name)) · terminal", leadingInset: leadingInset, showSidebar: showSidebar)
                } else if let (_, design) = vm.remoteDesign(drawnBy: remote) {
                    // The host's design: Export draws here from this Mac's synced copy.
                    let ref = RemoteDesignRef(hostID: remote.hostID, designID: design.id)
                    DesignToolbar(name: design.name, system: design.systemNamespace,
                                  openSystem: design.systemNamespace.map { namespace in
                                      { vm.openRemoteDesignSystem(RemoteSystemRef(hostID: remote.hostID, namespace: namespace)) }
                                  }, leadingInset: leadingInset,
                                  showSidebar: showSidebar, designs: { vm.openDestination(.designs) },
                                  screen: vm.remoteDesignScreen(ref),
                                  export: { vm.openRemoteDesignExport(ref) },
                                  menu: vm.designMenu(.remote(ref), context: .toolbar),
                                  perform: { vm.performDesignMenu($0, on: .remote(ref)) })
                        .equatable()
                        .id(remote)
                } else {
                    let space = connection.state.spaces.first { $0.id == agent.spaceID }?.name
                    threadHeader(store: vm.remoteThreadStores.store(for: remote), owner: .remote(remote),
                                 project: space ?? connection.config.name, title: vm.presentedThreadName(.remote(remote), hostName: agent.name),
                                 branch: nil, directory: nil,
                                 showChanges: { vm.openRemoteReview(remote, path: nil) }, rename: { vm.remoteRenameTarget = remote },
                                 pin: vm.offersPin(for: .remote(remote)) ? .remote(remote) : nil, row: .remote(remote),
                                 fleet: vm.fleetSurface(for: agent, onRemote: connection.config.name, hostID: connection.id), online: connection.phase == .connected,
                                 remoteHost: connection.config.name)
                        .id(remote)
                }
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID, let design = vm.design(drawnBy: agent),
                      design.buildsSystem {
                let target = vm.systemTarget(ofBuild: design.id)
                DesignSystemHeader(model: vm.designSystemPage(.build(design.id)), toolbar: true, leadingInset: leadingInset,
                                   showSidebar: showSidebar, designs: { vm.openDestination(.designs) },
                                   menu: vm.designSystemMenu(target), perform: { vm.performDesignSystemMenu($0, on: target) })
                    .equatable()
                    .id(agent.id)
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID, let design = vm.design(drawnBy: agent) {
                let system = design.systemNamespace.flatMap { vm.designSystems.summary($0) }?.namespace
                DesignToolbar(name: design.name, system: vm.designSystemName(design),
                              swatches: vm.designSystemSwatches(system, count: 3),
                              openSystem: system.map { namespace in { vm.openDesignSystem(namespace) } }, leadingInset: leadingInset,
                              showSidebar: showSidebar, designs: { vm.openDestination(.designs) }, screen: vm.designScreen(design.id),
                              export: { vm.openDesignExport(design.id) },
                              menu: vm.designMenu(.local(design.id), context: .toolbar),
                              perform: { vm.performDesignMenu($0, on: .local(design.id)) },
                              jump: { vm.designJump == nil ? vm.openDesignJump(design.id) : (vm.designJump = nil) },
                              jumpOpen: vm.designJump?.design == design.id,
                              git: DesignGitPresentation.chip(vm.designGit(design.id).state, drawing: false),
                              gitOpen: vm.designGit(design.id).panelOpen,
                              pressGit: { vm.pressDesignGitChip(design.id) },
                              placeGit: { vm.designGit(design.id).placeChip(trailing: $0) })
                    .equatable()
                    .id(agent.id)
            } else if let agent = vm.selectedAgent, vm.activeTabID == agent.tabID,
                      let space = vm.state.spaces.first(where: { $0.id == agent.spaceID }) {
                threadHeader(store: vm.threadStores.store(for: agent.id), owner: .local(agent.id), project: space.name, title: vm.presentedThreadName(.local(agent.id), hostName: agent.name),
                             branch: nil, directory: nil,
                             showChanges: { vm.openReview(agentID: agent.id, path: nil) }, rename: { vm.agentRenameTarget = agent.id },
                             pin: vm.offersPin(for: .local(agent.id)) ? .local(agent.id) : nil, row: .local(agent.id),
                             apps: vm.quickApps(in: agent.spaceID), fleet: vm.fleetSurface(for: agent))
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
                              rename: @escaping () -> Void, pin: SidebarRowID?, row: SidebarRowID, apps: QuickApps? = nil,
                              fleet: FleetThreadSurface? = nil, online: Bool = true, remoteHost: String? = nil) -> EquatableView<ThreadHeader> {
        let muted = vm.pushMuted(row)
        let pane = vm.sidePaneButton(for: owner)
        return ThreadHeader(store: store, project: project, title: title, leadingInset: leadingInset, showSidebar: showSidebar,
                            branch: branch, directory: directory,
                            paneOpen: pane.isOn, paneNews: pane.news, paneShortcut: keys.display(.toggleRightPane),
                            togglePane: { vm.toggleRightPane() }, showChanges: showChanges, rename: rename,
                            pinned: pin.map { vm.isPinned($0) }, togglePin: pin.map { row in { vm.togglePin(row) } },
                            muted: muted, toggleMute: muted == nil ? nil : { vm.togglePushMuted(row) },
                            move: vm.fleetMoveHeader(for: row), moveTo: { vm.requestFleetMove(row, to: $0) },
                            sentBy: fleet?.sentBy, sentByOnline: online,
                            openSender: fleet?.sender.map { row in { vm.selectSidebarRow(row) } }, remoteHost: remoteHost,
                            apps: apps, runApp: { vm.runQuickApp($0, showOutput: true) }, stopApp: { vm.stopApp($0) },
                            restartApp: { vm.restartApp($0) }, appOutput: { vm.showAppOutput($0) }, editApps: { vm.openAppsSettings() })
            .equatable()
    }
}

/// The toolbar ends where a thread's pane card begins. Its own modifier reads the card's width, so a drag of the card's handle
/// reruns this and not the whole shell.
private struct PaneReserve: ViewModifier {
    var vm: ShepherdViewModel

    func body(content: Content) -> some View { content.padding(.trailing, vm.sidePaneReserve) }
}
