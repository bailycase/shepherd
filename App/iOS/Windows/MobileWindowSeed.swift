import Foundation

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
        var settingsPath: [MobileRoute]
        var padSelection: AgentRef?
        var padPath: [MobileRoute]
    }

    var restoration: Restoration {
        Restoration(pad: layout == .pad, tab: tab, homePath: homePath, settingsPath: settingsPath,
                    padSelection: padSelection, padPath: padPath)
    }

    /// Puts a window back where it was, leaving out the screens of hosts no longer saved. The
    /// root then adopts the layout the window has now, as it does on any resize.
    func restore(_ saved: Restoration, hosts: Set<UUID>) {
        func known(_ route: MobileRoute) -> Bool { route.host.map(hosts.contains) ?? true }
        layout = saved.pad ? .pad : .phone
        tab = saved.tab
        homePath = saved.homePath.filter(known)
        settingsPath = saved.settingsPath.filter(known)
        padSelection = saved.padSelection.flatMap { hosts.contains($0.host) ? $0 : nil }
        padPath = saved.padPath.filter(known)
    }
}
