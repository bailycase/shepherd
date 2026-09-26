import SwiftUI
import ShepherdUI

/// A design in the iPad sidebar's Recents (iPadSidebar): the nib, its name, and "4 boards" in
/// mono, with its host when designs from several hosts mix.
struct PadDesignRecentRow: View, Equatable {
    let row: PadDesigns.Row
    var selected = false

    var body: some View {
        NWListRow(row.name, leading: .symbol("pencil.tip"), trailing: .meta(row.boards), chevron: false,
                  selected: selected, compact: true)
            .accessibilityValue("Design, \(row.boards)")
    }
}

/// "Open in new window" for a design (a Recents row's menu): the design in a window of its own,
/// as Split View puts it beside a thread (iPadSplitView). iPhone draws nothing.
struct PadDesignWindowButton: View {
    let design: PadDesignRef
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if supportsMultipleWindows {
            Button("Open in new window", systemImage: "macwindow.badge.plus") {
                openWindow(value: MobileWindowSeed(opening: .padDesign(.design(design))))
            }
        }
    }
}

extension MobileNavigator {
    /// A design is on screen on iPad: it takes the whole window, the sidebar out (iPadDesign).
    var padShowsDesign: Bool {
        guard layout == .pad, case .padDesign(.design)? = padPath.last else { return false }
        return true
    }
}

extension MobileRoute {
    /// The Design tool's screens, for the sidebar's Designs row.
    var isPadDesign: Bool {
        if case .padDesign = self { return true }
        return false
    }
}
