import Foundation
import ShepherdRemote

/// What a window of the app is opened with (iPadSplitView board): its own identity, and the
/// route it shows first. `ShepherdIOSApp`'s `WindowGroup(for:)` presents one per window; the
/// system keeps it with the window's scene, so a restored window gets its seed back.
///
/// The id is what tells windows apart: opening a window with the seed of one already open
/// brings that window forward instead of opening another (`MobileWindows.activate`).
struct MobileWindowSeed: Hashable, Codable, Identifiable {
    var id = UUID()
    /// The route a new window opens on; nil opens it where a fresh launch would.
    var opening: MobileRoute?

    /// The window of a root made without a seed (the fixture harness's single window).
    static let lone = MobileWindowSeed(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
}

extension MobileNavigator {
    /// Where a window is, as its scene storage keeps it: the stacks and the selected thread, not
    /// what is presented over them (a sheet is closed on relaunch).
    struct Restoration: Codable, Equatable {
        var pad: Bool
        var tab: Tab
        var homePath: [MobileRoute]
        var designsPath: [MobileRoute] = []
        var projectsPath: [MobileRoute] = []
        var automationsPath: [MobileRoute] = []
        var settingsPath: [MobileRoute]
        var padSelection: AgentRef?
        var padPath: [MobileRoute]
        /// The side pane's tab while it is open; nil closed (and in what older builds saved).
        var sidePane: PadSidePaneTab?

        init(pad: Bool, tab: Tab, homePath: [MobileRoute], designsPath: [MobileRoute] = [], projectsPath: [MobileRoute] = [],
             automationsPath: [MobileRoute] = [], settingsPath: [MobileRoute], padSelection: AgentRef?, padPath: [MobileRoute],
             sidePane: PadSidePaneTab? = nil) {
            self.pad = pad
            self.tab = tab
            self.homePath = homePath
            self.designsPath = designsPath
            self.projectsPath = projectsPath
            self.automationsPath = automationsPath
            self.settingsPath = settingsPath
            self.padSelection = padSelection
            self.padPath = padPath
            self.sidePane = sidePane
        }

        /// A window saved before the phone had five tabs has no stacks for the new ones.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pad = try c.decode(Bool.self, forKey: .pad)
            tab = try c.decode(Tab.self, forKey: .tab)
            homePath = try c.decode([MobileRoute].self, forKey: .homePath)
            designsPath = try c.decodeIfPresent([MobileRoute].self, forKey: .designsPath) ?? []
            projectsPath = try c.decodeIfPresent([MobileRoute].self, forKey: .projectsPath) ?? []
            automationsPath = try c.decodeIfPresent([MobileRoute].self, forKey: .automationsPath) ?? []
            settingsPath = try c.decode([MobileRoute].self, forKey: .settingsPath)
            padSelection = try c.decodeIfPresent(AgentRef.self, forKey: .padSelection)
            padPath = try c.decode([MobileRoute].self, forKey: .padPath)
            // A tab a later version removed (Artifacts) restores as no tab rather than failing the window.
            sidePane = (try? c.decodeIfPresent(PadSidePaneTab.self, forKey: .sidePane)) ?? nil
        }
    }

    var restoration: Restoration {
        Restoration(pad: layout == .pad, tab: tab, homePath: homePath, designsPath: designsPath, projectsPath: projectsPath,
                    automationsPath: automationsPath, settingsPath: settingsPath, padSelection: padSelection, padPath: padPath,
                    sidePane: sidePane.isOpen ? sidePane.tab : nil)
    }

    /// Puts a window back where it was, leaving out the screens of hosts no longer saved. The
    /// root then adopts the layout the window has now, as it does on any resize.
    func restore(_ saved: Restoration, hosts: Set<UUID>) {
        func known(_ route: MobileRoute) -> Bool { route.host.map(hosts.contains) ?? true }
        layout = saved.pad ? .pad : .phone
        tab = saved.tab
        // A tab's root is never on its stack; a window saved with More or Automations pushed on
        // Home comes back on Home's root.
        func kept(_ route: MobileRoute) -> Bool { known(route) && !route.isTabRoot }
        homePath = saved.homePath.filter(kept)
        designsPath = saved.designsPath.filter(kept)
        projectsPath = saved.projectsPath.filter(kept)
        automationsPath = saved.automationsPath.filter(kept)
        settingsPath = saved.settingsPath.filter(kept)
        padSelection = saved.padSelection.flatMap { hosts.contains($0.host) ? $0 : nil }
        padPath = saved.padPath.filter(known)
        if let tab = saved.sidePane { sidePane.show(tab) }
        if layout == .pad { takePaneScreens() }
    }
}
