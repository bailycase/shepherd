import SwiftUI

private let started = Date().addingTimeInterval(-41 * 60)

#Preview("Sidebar") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            ForEach(NWDensity.allCases) { density in
                NWSidebar {
                    VStack(alignment: .leading, spacing: 1) {
                        NWSidebarSection("This Mac", detail: .count(19), toggle: {})
                        NWSidebarDisclosureRow("Shepherd", expanded: true) { _ in
                            Text("8").font(.nw(.micro, weight: .regular)).foregroundStyle(.nw.textTertiary)
                        }
                        NWSidebarRow("Plan shepherd extensions", state: .running, depth: 1,
                                     accessory: .elapsed(since: started, tone: .running))
                        NWSidebarRow("Dock review pane", state: .attention, depth: 1, accessory: .ask)
                        NWSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true, depth: 1)
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
            NWThreadToolbar("Investigate SwiftUI live preview", project: "Shepherd") {
                NWBranchChip(kind: .worktree, branch: "pi/swiftui-previews", changedFiles: 3)
            } trailing: {
                NWSidePaneButton(isOn: false, shortcut: "⇧⌘B") {}
                NWOptionsMenu("Thread options") { Button("Rename…") {} }
            }
            NWThreadToolbar("Deploy media stack", project: "homelab", sidebar: {}) {
                NWBranchChip(kind: .checkout, branch: "chore/remove-homarr", changedFiles: 11, host: "horizon")
            } trailing: {
                NWSidePaneButton(isOn: true, shortcut: "⇧⌘B") {}
                NWOptionsMenu("Thread options") { Button("Rename…") {} }
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

#Preview("Side pane tabs and button") {
    NWPreviewBoth {
        VStack(alignment: .trailing, spacing: NW.Space.l) {
            NWSidePaneTabs([NWSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 4, shortcut: "⌃1")],
                           selection: "changes", select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                Button("Reset Width") {}
            }
            .frame(width: 600)
            NWSidePaneTabs([NWSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2, news: true)],
                           selection: "changes", select: { _ in }, close: {}) {
                Button("Reset Width") {}
            }
            .frame(width: 400)
            NWSidePaneButton(isOn: false, news: "Agent opened a review in Changes", shortcut: "⇧⌘B") {}
                .padding(.bottom, 48)
        }
        .frame(width: 720, alignment: .trailing)
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
