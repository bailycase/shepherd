import SwiftUI

private let started = Date().addingTimeInterval(-41 * 60)

#Preview("Sidebar") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            ForEach(NWDensity.allCases) { density in
                NWSidebar(compose: {}, jump: {}, jumpShortcut: "⌘K") {
                    VStack(alignment: .leading, spacing: 1) {
                        NWSidebarSection("This Mac", detail: .count(19), toggle: {})
                        NWSidebarDisclosureRow("Shepherd", expanded: true) { _ in
                            Text("8").font(.nw(.micro, weight: .regular)).foregroundStyle(.nw.textTertiary)
                        }
                        NWSidebarRow("Plan shepherd extensions", state: .running, depth: 1,
                                     accessory: .elapsed(since: started, tone: .running))
                        NWSidebarRow("Dock review pane", state: .attention, depth: 1, accessory: .ask)
                        NWSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true, depth: 1)
                        NWSidebarRow("worker", state: .done, depth: 2, accessory: .text("41m"))
                        NWSidebarRow("Fix remote subagent deletion", state: .idle, depth: 1, worktree: true)
                        NWSidebarRow("nightly-fix", state: .stuck, depth: 1, accessory: .text("14m", tone: .stuck))
                        NWSidebarSection("horizon", detail: .text("Unreachable", tone: .failed))
                        NWSidebarNoticeRow(.failed, text: "Unreachable · 3h", actionTitle: "Retry") {}
                    }
                    .padding(.horizontal, NWSidebarMetrics.treeInset)
                } footer: {
                    NWSidebarFooter("Automations", systemImage: "bolt", count: 1, expanded: false) {}
                }
                .frame(width: 232, height: 520)
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
                NWStatusPill(.running, label: "Running · 0:31")
            } options: {
                NWOptionsMenu { Button("Rename…") {} }
            }
            NWThreadToolbar("Dock review pane", sidebar: {},
                            toggles: [(NWPaneToggle(systemImage: "plus.forwardslash.minus", label: "Review", isOn: true), {})]) {
                NWStatusPill(.attention)
            } options: {
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
