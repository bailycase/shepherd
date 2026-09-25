import SwiftUI
import ShepherdUI

/// iPhone (MobileAgents board): two tabs, Home and Settings, each its own stack. Home's root is
/// the home track's `HomeScreen`, Settings' root is `SettingsScreen`; everything else is pushed
/// through `MobileNavigator.open`.
struct PhoneShell: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.tab) {
            Tab("Home", systemImage: "house", value: MobileNavigator.Tab.home) {
                NavigationStack(path: $navigator.homePath) {
                    HomeScreen().mobileDestinations()
                }
            }
            Tab("Settings", systemImage: "gearshape", value: MobileNavigator.Tab.settings) {
                NavigationStack(path: $navigator.settingsPath) {
                    SettingsScreen().mobileDestinations()
                }
            }
        }
    }
}
