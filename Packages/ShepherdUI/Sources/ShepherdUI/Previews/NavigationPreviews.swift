import SwiftUI

private let started = Date().addingTimeInterval(-41 * 60)

#Preview("Sidebar") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            ForEach([NWDensity.standard, .compact]) { density in
                NWSidebar(topBar: NWSidebarTopBar(searchShortcut: "⌘K", hideShortcut: "⇧⌘S", search: {}, hide: {})) {
                    VStack(alignment: .leading, spacing: NWSidebarMetrics.rowSpacing) {
                        NWSidebarDestination("New thread", icon: .newThread, trailing: .keycaps("⌘N")) {}
                        NWSidebarDestination("Automations", icon: .symbol("bolt")) {}
                        NWSidebarDestination("More", icon: .disclosure(open: true)) {}
                        NWSidebarDestination("Hosts", icon: .symbol("display"), selected: true, child: true,
                                             trailing: .alert("1 offline")) {}
                        NWSidebarDestination("Extensions", icon: .symbol("puzzlepiece.extension"), child: true) {}
                        NWSidebarSection(.needsYou(count: 2))
                        NWSidebarRow("Checkout funnel events", state: .attention, accessory: .reason("retention?"))
                        NWSidebarRow("Nightly triage", leading: .glyph("bolt", attention: true), accessory: .reason("approve plan"))
                        NWSidebarSection(.recents)
                        NWSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true,
                                     accessory: .elapsed(since: started))
                        NWSidebarRow("Fix remote subagent deletion", state: .idle, accessory: .tag("horizon"))
                        NWSidebarRow("Merge PR #24 after CI", leading: .glyph("bolt", attention: false), accessory: .text("done"))
                        NWSidebarRow("Fix terminal output buffer", state: .done)
                        NWSidebarRow("Fix remote nightly", state: .failed, accessory: .tag("horizon"))
                    }
                    .padding(.horizontal, NWSidebarMetrics.listInset)
                } footer: {
                    NWSidebarFooter(name: "Baily", detail: "This Mac · build-01") {}
                }
                .frame(width: 232, height: 560)
                .nwBorder(.nw.lineSubtle, radius: NW.Radius.m)
                .nwDensity(density)
            }
        }
    }
}

#Preview("Toolbar and pane header") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWThreadToolbar("Investigate SwiftUI live preview", counters: "17 turns · 42k ctx",
                            toggles: [(NWPaneToggle(systemImage: "arrow.triangle.branch", label: "Subagents", isOn: false), {}),
                                      (NWPaneToggle(systemImage: "plus.forwardslash.minus", label: "Review", shortcut: "⇧⌘B", isOn: false), {})]) {
                NWOptionsMenu { Button("Rename…") {} }
            }
            NWThreadToolbar("Dock review pane", sidebar: {},
                            toggles: [(NWPaneToggle(systemImage: "plus.forwardslash.minus", label: "Review", isOn: true), {})]) {
                NWOptionsMenu { Button("Rename…") {} }
            }
            NWPaneHeader("Review", close: {}) {
                HStack(spacing: NW.Space.xs) {
                    Text("4 files ·")
                    NWDiffStat(added: 67, removed: 58, font: .nw(.micro, weight: .regular))
                }
            } controls: {
                NWSegmentedPicker(selection: .constant(0), options: [(0, "Local"), (1, "PR #24")], size: .s)
            }
        }
        .frame(width: 720)
    }
}

#Preview("Command palette") {
    @Previewable @State var query = "rev"
    @Previewable @FocusState var focused: Bool
    NWPreviewBoth {
        NWPaletteCard {
            NWPaletteSearchRow("Search commands, agents, subagents…", text: $query, focus: $focused, submit: {}) {
                NWSegmentedPicker(selection: .constant(0), options: [(0, "All"), (1, "Commands"), (2, "Agents")], size: .s)
            }
        } results: {
            VStack(alignment: .leading, spacing: 0) {
                NWPaletteSectionHeader("Commands")
                NWPaletteRow("New agent", systemImage: "plus", context: "in Shepherd/", shortcut: "⌘N", highlighted: true) {}
                NWPaletteRow("Review diff", systemImage: "plus.forwardslash.minus", context: "working tree · 4 files", shortcut: "⇧⌘B") {}
                NWPaletteSectionHeader("Agents")
                NWPaletteRow("Dock review pane", systemImage: "bubble.left", context: "running · 8m") {}
            }
        }
        .frame(width: NWPaletteMetrics.width)
    }
}
