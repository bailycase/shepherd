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
            NavigationStack {
                presented.route.destination.mobileDestinations()
            }
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
