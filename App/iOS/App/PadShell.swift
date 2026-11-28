import SwiftUI
import ShepherdUI
import ShepherdRemote

/// iPad (iPadThread, iPadSidebar, iPadPortrait boards) and iPhone Duo's inner display (DuoOpenThread, DuoBook): the Mac's sidebar as the
/// boards' floating glass card beside the selected thread in landscape; in portrait the thread takes the width and the card slides over
/// it. The sidebar is the home track's `PadSidebar`; with no thread selected the detail shows its `PadOverview`. Other screens are pushed
/// over the detail. The thread's side pane docks beside it (`ThreadWithSidePane`), by the Mac's rule: where it leaves the thread too
/// little beside the sidebar, the sidebar slides over the thread instead (`PadSplitLayout.sidebarFitsBesidePane`). Half open (the book
/// pose) the card takes the display on the fold's left and the thread the right. In the laptop pose the thread takes the window as an
/// arrangement (DuoLaptop, `PadArrangedThread`).
///
/// The card is ours, not a split view's system sidebar (which left an empty blurred column behind the card when its own Show sidebar
/// was pressed): the detail is one stack, its root offers Show sidebar (`PadSidebarButton`), and `navigator.padColumns` says whether
/// the card shows (`.detailOnly` hides it).
struct PadShell: View {
    @Environment(MobileNavigator.self) private var navigator

    /// The columns the layout calls for: where the sidebar overlays, the thread alone, but with no
    /// thread chosen the sidebar stays out (the overview alone offers no way to one); else both.
    /// A design takes the whole window either way (iPadDesign; DesignPad/).
    private static func columns(_ navigator: MobileNavigator) -> NavigationSplitViewVisibility {
        if navigator.padShowsDesign || navigator.padShowsForgeWide { return .detailOnly }
        return navigator.padSidebarOverlays && (navigator.padSelection != nil || !navigator.padPath.isEmpty) ? .detailOnly : .all
    }

    var body: some View {
        @Bindable var navigator = navigator
        GeometryReader { proxy in
            // The sidebar slides over the thread in portrait, and beside an open pane that leaves
            // the thread too little (iPhone Duo's inner display).
            // A device with a hinge is an iPhone Duo, whose flat display has a narrower column than an iPad's.
            let docked = navigator.hingeClosed == nil ? MobileLayout.sidebarWidth : MobileLayout.duoSidebarWidth
            let crowded = navigator.sidePane.isOpen && navigator.padSelection != nil
                && !PadSplitLayout.sidebarFitsBesidePane(window: proxy.size.width, sidebar: docked)
            let overlays = PadSplitLayout.sidebarOverlays(window: proxy.size) || crowded
            let laptop = proxy.horizontalFold != nil
            let fold = proxy.verticalFold
            // Half open (iPhone Duo): the card fills the display on the fold's left and the thread starts on its right.
            let column = fold?.lowerBound ?? (overlays ? MobileLayout.sidebarOverlayWidth : docked)
            let detailLeading = fold?.upperBound ?? column
            let shown = navigator.padColumns != .detailOnly
            let beside = shown && !overlays
            // The sidebar beside a screen it opened (iPadAutomations, iPadFleet, iPadHooks): no Back; the sidebar is the way out.
            let hidesBack = navigator.hingeClosed == nil && beside && navigator.padSelection == nil && navigator.padPath.count <= 1
            Group {
                if let arranged = navigator.sidePane.arranged, arranged == navigator.padSelection {
                    PadArrangedThread(ref: arranged)
                } else {
                    ZStack(alignment: .leading) {
                        NavigationStack(path: $navigator.padPath) {
                            PadDetailRoot().modifier(DuoTopEdge()).mobileDestinations(hidesBack: hidesBack)
                        }
                        .padding(.leading, beside ? detailLeading : 0)
                        if overlays, shown {
                            Color.sh.scrim
                                .ignoresSafeArea()
                                .onTapGesture { withSHAnimation(.pane) { navigator.padColumns = .detailOnly } }
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                        PadSidebar(overlays: overlays, topInset: proxy.safeAreaInsets.top)
                            .frame(width: column)
                            .offset(x: shown ? 0 : -(column + SHSidebarMetrics.panelInset * 2))
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                    }
                    .background(Color.sh.bgBase)
                    .shAnimation(.pane, value: shown)
                }
            }
            .onChange(of: overlays, initial: true) { _, overlays in
                navigator.padSidebarOverlays = overlays
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
            }
            // Folding into the laptop pose with a thread open, or opening one in it, arranges it
            // (DuoLaptop); laid flat it stays so, its composer a card (DuoLaptopOpen), until Back.
            .onChange(of: laptop ? navigator.padSelection : nil, initial: true) { _, thread in
                guard let thread, navigator.padPath.isEmpty else { return }
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
            .onChange(of: proxy.verticalFold != nil, initial: true) { _, folded in
                navigator.padFolded = folded
                // Laid flat, what half open pushed over the thread is the pane's tab again.
                if !folded { navigator.takePaneScreens() }
            }
            .onChange(of: navigator.padShowsForgeWide) { _, _ in
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
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

/// The detail column's root: the selected thread with its side pane, or the overview.
///
/// Switching threads is a visibility flip, not a remount: the `retainedDetails` threads shown
/// most recently stay mounted, one screen per thread (its own identity, never reused for
/// another), and only the selected one is active (`threadDetailActive`). A hidden one is
/// transparent, untouchable, out of accessibility, contributes no toolbar, and runs no poll,
/// terminal watch or side pane; its turns, scroll and layout wait for it to be shown again.
private struct PadDetailRoot: View {
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileHosts.self) private var hosts
    /// Threads shown here, most recent last.
    @State private var mounted: [AgentRef] = []

    /// How many thread screens stay mounted, the selected one among them.
    static let retainedDetails = 3

    var body: some View {
        let selected = navigator.padSelection
        // A thread its host forgot or no longer has is not kept: it would ask for a store again.
        let pages = (mounted.filter { $0 != selected && hosts.agent($0) != nil } + (selected.map { [$0] } ?? []))
        ZStack {
            // The selected one last, so its title and toolbar are the ones the bar takes.
            ForEach(pages, id: \.self) { ref in
                let active = ref == selected
                ThreadWithSidePane(ref: ref)
                    .environment(\.threadDetailActive, active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .disabled(!active)
            }
            if selected == nil { PadOverview() }
        }
        .onChange(of: selected, initial: true) { _, ref in
            guard let ref else { return }
            MobileSignposts.threadSwitch(retained: mounted.contains(ref))
            mounted.removeAll { $0 == ref }
            mounted.append(ref)
            if mounted.count > Self.retainedDetails { mounted.removeFirst(mounted.count - Self.retainedDetails) }
        }
    }
}
