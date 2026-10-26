import SwiftUI
import ShepherdUI
import ShepherdRemote

/// iPad (iPadThread, iPadSidebar, iPadPortrait boards) and iPhone Duo's inner display (DuoOpenThread, DuoBook): the sidebar beside
/// the selected thread in landscape; in portrait the thread takes the width and the sidebar slides over it. The sidebar is the home
/// track's `PadSidebar`; with no thread selected the detail shows its `PadOverview`. Other screens are pushed over the detail. The
/// thread's side pane docks beside it (`ThreadWithSidePane`), by the Mac's rule: where it leaves the thread too little beside the
/// sidebar, the sidebar slides over the thread instead (`PadSplitLayout.sidebarFitsBesidePane`). In the laptop pose the thread
/// takes the window as an arrangement (DuoLaptop, `PadArrangedThread`).
struct PadShell: View {
    @Environment(MobileNavigator.self) private var navigator
    /// Until when the columns the layout calls for are held against the split view's own.
    @State private var settling: ContinuousClock.Instant?

    /// How long the split view may still write its own idea of the columns after a change of
    /// style or its first layout (a new window opened on a thread).
    private static let settleTime: Duration = .milliseconds(600)

    /// The columns the layout calls for: where the sidebar overlays, the thread alone, but with no
    /// thread chosen the sidebar stays out (the overview alone offers no way to one); else both.
    /// A design takes the whole window either way (iPadDesign; DesignPad/).
    private static func columns(_ navigator: MobileNavigator) -> NavigationSplitViewVisibility {
        if navigator.padShowsDesign { return .detailOnly }
        return navigator.padSidebarOverlays && (navigator.padSelection != nil || !navigator.padPath.isEmpty) ? .detailOnly : .all
    }

    var body: some View {
        @Bindable var navigator = navigator
        GeometryReader { proxy in
            // The sidebar slides over the thread in portrait, and beside an open pane that leaves
            // the thread too little (iPhone Duo's inner display).
            let crowded = navigator.sidePane.isOpen && navigator.padSelection != nil
                && !PadSplitLayout.sidebarFitsBesidePane(window: proxy.size.width, sidebar: MobileLayout.sidebarWidth)
            let overlays = PadSplitLayout.sidebarOverlays(window: proxy.size) || crowded
            let laptop = proxy.horizontalFold != nil
            Group {
                if let arranged = navigator.sidePane.arranged, arranged == navigator.padSelection {
                    PadArrangedThread(ref: arranged)
                } else {
                    NavigationSplitView(columnVisibility: $navigator.padColumns) {
                        // Half open (iPhone Duo), no width: the split view meets the fold itself, a column
                        // on each side. Any width of ours, even a range, would hold it off the fold.
                        PadSidebar()
                            .columnWidth(proxy.verticalFold == nil ? (overlays ? MobileLayout.sidebarOverlayWidth : MobileLayout.sidebarWidth) : nil)
                            // Beside an open pane the thread's own Show sidebar brings it back
                            // (`ThreadSidebarButton`), by its title where the bars run down the side.
                            .toolbar(removing: overlays && navigator.sidePane.isOpen && navigator.padSelection != nil ? .sidebarToggle : nil)
                    } detail: {
                        NavigationStack(path: $navigator.padPath) {
                            PadDetailRoot().mobileDestinations()
                        }
                    }
                    // Side by side in landscape; in portrait the thread keeps the width and the sidebar
                    // slides over it. One split view either way, so rotating keeps the selection and the
                    // pushed screens, but a change of style builds the columns anew (hence the composer's
                    // refocus below, and the pane and drafts kept in the navigator).
                    .navigationSplitViewStyle(PadSplitStyle(portrait: overlays))
                }
            }
            .onChange(of: overlays, initial: true) { _, overlays in
                navigator.padSidebarOverlays = overlays
                // The new style builds the columns anew: the composer that had the focus takes
                // it back as it mounts, and only then.
                navigator.refocusComposer = navigator.focusedComposer
                Task { @MainActor in
                    try? await Task.sleep(for: Self.settleTime)
                    navigator.refocusComposer = nil
                }
                // While the split view takes its new style, or lays out for the first time (a new
                // window opened on a thread), it writes its own idea of the columns back through
                // the binding, before or after this: set them now, again once it has changed,
                // and put them back over any write-back for a moment.
                settling = .now + Self.settleTime
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
                Task { @MainActor in navigator.padColumns = Self.columns(navigator) }
            }
            // Folding into the laptop pose with a thread open arranges it (DuoLaptop); laid flat it
            // stays so, its composer a card (DuoLaptopOpen), until Back.
            .onChange(of: laptop, initial: true) { _, laptop in
                guard laptop, let thread = navigator.padSelection, navigator.padPath.isEmpty else { return }
                navigator.sidePane.arranged = thread
            }
            .onChange(of: navigator.padPath.isEmpty) { _, _ in
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
            }
            .onChange(of: navigator.padShowsDesign) { _, _ in
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
            }
            .onChange(of: navigator.padColumns) { _, current in
                guard let settling else { return }
                guard ContinuousClock.now < settling else {
                    self.settling = nil
                    return
                }
                if current != Self.columns(navigator) {
                    Task { @MainActor in navigator.padColumns = Self.columns(navigator) }
                }
            }
        }
        // The window's shape, not what the keyboard leaves of it (`PadSplitLayout`).
        .ignoresSafeArea(.keyboard)
    }
}

/// The laptop pose's thread (DuoLaptop): the whole window, its own stack, no split view around it (HIG: never an arrangement view
/// inside a split view). Back returns to the split view; the thread, its draft and scroll are the navigator's, so nothing is lost.
private struct PadArrangedThread: View {
    let ref: AgentRef
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.padPath) {
            ThreadScreen(ref: ref)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.left") { navigator.sidePane.arranged = nil }
                    }
                }
                .mobileDestinations()
        }
    }
}

private extension View {
    @ViewBuilder func columnWidth(_ width: CGFloat?) -> some View {
        if let width { navigationSplitViewColumnWidth(width) } else { self }
    }
}

/// The detail column's root: the selected thread with its side pane, or the overview.
private struct PadDetailRoot: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let ref = navigator.padSelection {
            // One screen per thread: switching agents is a new identity, not a reused view.
            ThreadWithSidePane(ref: ref).id(ref)
        } else {
            PadOverview()
        }
    }
}

/// `.balanced` in landscape, `.prominentDetail` in portrait, as one style type.
private struct PadSplitStyle: NavigationSplitViewStyle {
    let portrait: Bool

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if portrait {
            ProminentDetailNavigationSplitViewStyle().makeBody(configuration: configuration)
        } else {
            BalancedNavigationSplitViewStyle().makeBody(configuration: configuration)
        }
    }
}
