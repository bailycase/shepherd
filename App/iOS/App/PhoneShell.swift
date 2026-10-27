import SwiftUI
import ShepherdUI

/// iPhone, and iPhone Duo closed (DuoClosedHome board): five tabs, each its own stack. Home is
/// the inbox; Designs, Projects and Automations are their lists; Settings holds what More did
/// (hosts, design systems, extensions). Everything else is pushed through
/// `MobileNavigator.open`, which selects the route's tab first.
struct PhoneShell: View {
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        @Bindable var navigator = navigator
        // Home's badge is the Needs you count. SwiftUI draws tab badges in the system's red and
        // offers no tint, so it isn't lantern as the board draws it.
        let needsYou = SidebarThreads.of(hosts).groups(HomeFeed.of(hosts).model).needsYou.count
        TabView(selection: $navigator.tab) {
            Tab("Home", systemImage: "house", value: MobileNavigator.Tab.home) {
                NavigationStack(path: $navigator.homePath) {
                    HomeScreen().mobileDestinations()
                }
            }
            .badge(needsYou)
            Tab("Designs", systemImage: "pencil.tip", value: MobileNavigator.Tab.designs) {
                NavigationStack(path: $navigator.designsPath) {
                    DesignsScreen().mobileDestinations()
                }
            }
            Tab("Projects", systemImage: "square.stack.3d.up", value: MobileNavigator.Tab.projects) {
                NavigationStack(path: $navigator.projectsPath) {
                    ProjectsScreen().mobileDestinations()
                }
            }
            Tab("Automations", systemImage: SHGlyph.automation.symbolName, value: MobileNavigator.Tab.automations) {
                NavigationStack(path: $navigator.automationsPath) {
                    AutomationsScreen().mobileDestinations()
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
