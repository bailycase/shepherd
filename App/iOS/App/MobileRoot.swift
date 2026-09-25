import SwiftUI
import ShepherdUI

/// The window's content: the phone shell or the iPad split view by width, the app's state in
/// the environment, the chosen appearance, and hosts connected while the app is in front.
struct MobileRoot: View {
    let app: MobileApp
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var navigator = app.navigator
        let layout: MobileNavigator.Layout = sizeClass == .regular ? .pad : .phone
        Group {
            switch layout {
            case .phone: PhoneShell()
            case .pad: PadShell()
            }
        }
        .sheet(item: $navigator.presented) { presented in
            PresentedSheet(route: presented.route, fitted: layout == .pad && !presented.route.sizesItself)
            .mobileEnvironment(app)
            .preferredColorScheme(app.appearance.mode.colorScheme)
        }
        .mobileEnvironment(app)
        .tint(Color.nw.lantern)
        .preferredColorScheme(app.appearance.mode.colorScheme)
        .onChange(of: layout, initial: true) { _, layout in app.navigator.adopt(layout) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Inactive includes system alerts and the app switcher; only the background drops sockets.
            if phase == .active { app.hosts.setForeground(true) }
            if phase == .background { app.hosts.setForeground(false) }
        }
    }
}

private extension MobileRoute {
    /// The palette sizes its own sheet.
    var sizesItself: Bool {
        if case .search(.palette) = self { return true }
        return false
    }
}

/// A presented route in its own stack. On iPad it is a form over the window as tall as what it
/// holds (iPadNewThread board), not the form's full height: a scroll view offers no height of
/// its own, so the sheet takes its content's.
private struct PresentedSheet: View {
    let route: MobileRoute
    let fitted: Bool
    @State private var height: CGFloat = 0

    var body: some View {
        NavigationStack {
            route.destination.mobileDestinations()
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top } action: { _, new in
                    if fitted { height = new }
                }
        }
        .frame(idealHeight: fitted && height > 0 ? height : nil)
        .fittedSheet(fitted)
    }
}

private extension View {
    @ViewBuilder
    func fittedSheet(_ fitted: Bool) -> some View {
        if fitted { presentationSizing(.form.fitted(horizontal: false, vertical: true)) } else { self }
    }
}
