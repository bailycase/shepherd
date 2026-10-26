import SwiftUI
import ShepherdUI
import ShepherdRemote

/// iPad (iPadThread, iPadSidebar, iPadPortrait boards): the sidebar beside the selected thread
/// in landscape; in portrait the thread takes the width and the sidebar slides over it. The
/// sidebar is the home track's `PadSidebar`; with no thread selected the detail shows its
/// `PadOverview`. Other screens are pushed over the detail.
struct PadShell: View {
    @Environment(MobileNavigator.self) private var navigator
    /// Until when the columns the layout calls for are held against the split view's own.
    @State private var settling: ContinuousClock.Instant?

    /// How long the split view may still write its own idea of the columns after a change of
    /// style or its first layout (a new window opened on a thread).
    private static let settleTime: Duration = .milliseconds(600)

    /// The columns the layout calls for: in portrait the thread alone, but with no thread chosen
    /// the sidebar stays out (the overview alone offers no way to one); in landscape both. A
    /// design takes the whole window either way (iPadDesign; DesignPad/), and so does a review
    /// on iPhone Duo's inner display.
    private static func columns(_ navigator: MobileNavigator) -> NavigationSplitViewVisibility {
        if navigator.padTakesWindow { return .detailOnly }
        return navigator.padSidebarOverlays && (navigator.padSelection != nil || !navigator.padPath.isEmpty) ? .detailOnly : .all
    }

    /// Whether the thread, beside the sidebar and the docked Changes pane, would be narrower
    /// than it reads (iPhone Duo's inner display, open or half open).
    static func reviewCrowded(window: CGFloat) -> Bool {
        let detail = window - MobileLayout.sidebarWidth
        return detail - min(MobileLayout.reviewDockWidth, detail * MobileLayout.reviewDockShare) < MobileLayout.reviewThreadMinWidth
    }

    var body: some View {
        @Bindable var navigator = navigator
        GeometryReader { proxy in
            let portrait = PadSplitLayout.sidebarOverlays(window: proxy.size)
            NavigationSplitView(columnVisibility: $navigator.padColumns) {
                // Half open (iPhone Duo), no width: the split view meets the fold itself, a column
                // on each side. Any width of ours, even a range, would hold it off the fold.
                PadSidebar()
                    .columnWidth(proxy.verticalFold == nil ? (portrait ? MobileLayout.sidebarOverlayWidth : MobileLayout.sidebarWidth) : nil)
            } detail: {
                NavigationStack(path: $navigator.padPath) {
                    PadDetailRoot().mobileDestinations()
                }
            }
            // Side by side in landscape; in portrait the thread keeps the width and the sidebar
            // slides over it. One split view either way, so rotating keeps the selection and the
            // pushed screens, but a change of style builds the columns anew (hence the composer's
            // refocus below).
            .navigationSplitViewStyle(PadSplitStyle(portrait: portrait))
            .onChange(of: portrait, initial: true) { _, portrait in
                navigator.padSidebarOverlays = portrait
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
            .onChange(of: Self.reviewCrowded(window: proxy.size.width), initial: true) { _, crowded in
                navigator.padReviewCrowded = crowded
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
            }
            .onChange(of: navigator.padPath.isEmpty) { _, _ in
                let columns = Self.columns(navigator)
                if navigator.padColumns != columns { navigator.padColumns = columns }
            }
            .onChange(of: navigator.padTakesWindow) { _, _ in
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

private extension MobileNavigator {
    /// A design takes the whole window, the sidebar out, and so does a review where the thread
    /// would be too narrow beside both (`padReviewCrowded`; iPhone Duo's inner display, whose
    /// 951pt leave it 274pt, and half open the thread and its pane each take a side of the fold).
    /// By width, not the hinge: the hinge may not report (an older SDK, the simulator).
    var padTakesWindow: Bool {
        if padShowsDesign { return true }
        guard padReviewCrowded, case .review(let route)? = padPath.last else { return false }
        switch route {
        case .changes, .diff: return true
        default: return false
        }
    }
}

private extension View {
    @ViewBuilder func columnWidth(_ width: CGFloat?) -> some View {
        if let width { navigationSplitViewColumnWidth(width) } else { self }
    }
}

/// The detail column's root: the selected thread, or the overview.
private struct PadDetailRoot: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let ref = navigator.padSelection {
            // One screen per thread: switching agents is a new identity, not a reused view.
            ThreadScreen(ref: ref).id(ref)
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
