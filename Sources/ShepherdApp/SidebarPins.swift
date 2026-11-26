import Foundation
import ShepherdCore
import ShepherdSidebar
import ShepherdUI
import ShepherdRemote

// Pins' words beside this Mac's own: see ShepherdSidebar/SidebarPins.swift for the thread pins.

/// Mute Notifications in the thread options menu (the brief for the notification follow-ups; no board).
enum MuteWords {
    static func menuTitle(muted: Bool) -> String { muted ? "Unmute Notifications" : "Mute Notifications" }
    static func symbol(muted: Bool) -> String { muted ? "bell" : SHGlyph.mute.symbolName }
}

/// This Mac's spaces pinned to the top of the Spaces tree, oldest pin first. View state of this
/// Mac beside the thread pins: not in state.json, never sent to another device.
struct SpacePins: Equatable {
    private(set) var spaces: [SpaceID] = []
    static let defaultsKey = "shepherd.sidebar.pinnedSpaces"

    init(_ spaces: [SpaceID] = []) {
        var seen = Set<SpaceID>()
        self.spaces = spaces.filter { seen.insert($0).inserted }
    }

    init(defaults: UserDefaults) {
        self.init((defaults.stringArray(forKey: Self.defaultsKey) ?? []).map { SpaceID(rawValue: $0) })
    }

    func save(to defaults: UserDefaults) {
        defaults.set(spaces.map(\.rawValue), forKey: Self.defaultsKey)
    }

    func contains(_ space: SpaceID) -> Bool { spaces.contains(space) }

    /// Pins one that isn't (after the others), unpins one that is.
    mutating func toggle(_ space: SpaceID) {
        if let index = spaces.firstIndex(of: space) { spaces.remove(at: index) } else { spaces.append(space) }
    }

    /// Drops pins of spaces that are gone; true when any went.
    @discardableResult mutating func prune(keeping live: Set<SpaceID>) -> Bool {
        let before = spaces.count
        spaces.removeAll { !live.contains($0) }
        return spaces.count != before
    }
}
