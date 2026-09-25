import SwiftUI
import ShepherdUI

/// A window's content: the phone shell or the iPad split view by width, the app's state and the
/// window's own navigator in the environment, the chosen appearance, and hosts connected while
/// any window is in front (`MobileWindows`).
struct MobileRoot: View {
    let app: MobileApp
    let navigator: MobileNavigator
    let window: MobileWindowSeed
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// A window with its own navigator (`MobileWindowRoot`), or, without one, the app's
    /// `navigator` (a single-window root, as the fixture harness makes).
    init(app: MobileApp, navigator: MobileNavigator? = nil, window: MobileWindowSeed = .lone) {
        self.app = app
        self.navigator = navigator ?? app.navigator
        self.window = window
    }

    var body: some View {
        @Bindable var navigator = navigator
        let layout: MobileNavigator.Layout = sizeClass == .regular ? .pad : .phone
        Group {
            switch layout {
            case .phone: PhoneShell()
            case .pad: PadShell()
            }
        }
        .sheet(item: $navigator.presented) { presented in
            PresentedSheet(route: presented.route, fitted: layout == .pad && !presented.route.sizesItself)
            .mobileEnvironment(app, navigator: navigator, window: window)
            .preferredColorScheme(app.appearance.mode.colorScheme)
        }
        .mobileEnvironment(app, navigator: navigator, window: window)
        .focusedSceneValue(\.mobileNavigator, navigator)
        .tint(Color.nw.lantern)
        .preferredColorScheme(app.appearance.mode.colorScheme)
        .onChange(of: layout, initial: true) { _, layout in navigator.adopt(layout) }
        .onAppear { app.windows.register(window, navigator: navigator) }
        .onDisappear { app.windows.unregister(window.id, hosts: app.hosts) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The first phase can arrive before onAppear: the window counts only once registered.
            app.windows.register(window, navigator: navigator)
            app.windows.setPhase(window.id, phase, hosts: app.hosts)
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
