import SwiftUI
import ShepherdUI

/// iPad (iPadThread, iPadSidebar, iPadPortrait boards): the sidebar beside the selected thread
/// in landscape; in portrait the thread takes the width and the sidebar slides over it. The
/// sidebar is the home track's `PadSidebar`; with no thread selected the detail shows its
/// `PadOverview`. Other screens are pushed over the detail.
struct PadShell: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        GeometryReader { proxy in
            let portrait = proxy.size.width < proxy.size.height
            NavigationSplitView(columnVisibility: $navigator.padColumns) {
                PadSidebar()
                    .navigationSplitViewColumnWidth(MobileLayout.sidebarWidth)
            } detail: {
                NavigationStack(path: $navigator.padPath) {
                    PadDetailRoot().mobileDestinations()
                }
            }
            // Side by side in landscape; in portrait the thread keeps the width and the sidebar
            // slides over it. One split view either way, so rotating never remounts the thread.
            .navigationSplitViewStyle(PadSplitStyle(portrait: portrait))
            .onChange(of: portrait, initial: true) { _, portrait in
                navigator.padSidebarOverlays = portrait
                // After the split view has taken its new style: while it changes, it writes its
                // own idea of the columns back through the binding. With no thread chosen, the
                // sidebar stays out in portrait too: the overview alone offers no way to one.
                Task { @MainActor in navigator.padColumns = portrait && navigator.padSelection != nil ? .detailOnly : .all }
            }
        }
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
