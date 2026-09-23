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
    @State private var liveSidebarWidth: Double?
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
        .modifier(AppDialogs(vm: vm))
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
