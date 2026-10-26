import SwiftUI

private let started = Date().addingTimeInterval(-41 * 60)

#Preview("Sidebar") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            ForEach([SHDensity.standard, .compact]) { density in
                SHSidebar(topBar: SHSidebarTopBar(searchShortcut: "⌘K", hideShortcut: "⇧⌘S", search: {}, hide: {})) {
                    VStack(alignment: .leading, spacing: SHSidebarMetrics.rowSpacing) {
                        SHSidebarDestination("New thread", icon: .newThread, trailing: .keycaps("⌘N")) {}
                        SHSidebarDestination("Automations", icon: .symbol("bolt")) {}
                        SHSidebarDestination("More", icon: .disclosure(open: true)) {}
                        SHSidebarDestination("Hosts", icon: .symbol("display"), selected: true, child: true,
                                             trailing: .alert("1 offline")) {}
                        SHSidebarDestination("Extensions", icon: .symbol("puzzlepiece.extension"), child: true) {}
                        SHSidebarSection(.needsYou(count: 2))
                        SHSidebarRow("Checkout funnel events", state: .attention, accessory: .reason("retention?"))
                        SHSidebarRow("Nightly triage", leading: .glyph("bolt", attention: true), accessory: .reason("approve plan"))
                        SHSidebarSection(.pinned)
                        SHSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true,
                                     accessory: .elapsed(since: started))
                        SHSidebarRow("Fix remote subagent deletion", state: .idle, accessory: .tag("horizon"))
                        SHSidebarSection(.recents)
                        SHSidebarRow("Merge PR #24 after CI", leading: .glyph("bolt", attention: false), accessory: .text("done"))
                        SHSidebarRow("Fix terminal output buffer", state: .done)
                        SHSidebarRow("Fix remote nightly", state: .failed, accessory: .tag("horizon"))
                    }
                    .padding(.horizontal, SHSidebarMetrics.listInset)
                } footer: {
                    SHSidebarFooter(name: "Alex", detail: "This Mac · demo-mac") {}
                }
                .frame(width: 232, height: 600)
                .shBorder(.sh.lineSubtle, radius: SH.Radius.m)
                .shDensity(density)
            }
        }
    }
}

#Preview("Sidebar — Spaces") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            ForEach([SHDensity.standard, .compact]) { density in
                VStack(alignment: .leading, spacing: SHSidebarMetrics.rowSpacing) {
                    SHProjectsHeader("Spaces") { Button("Show shepherd") {} }
                    SHProjectRow("shepherd", count: 3, expanded: true, toggle: {}, newThread: {}) { Button("Hide from Sidebar") {} }
                    SHSidebarRow("Dock review pane", state: .attention, accessory: .reason("approve plan"), nested: true)
                    SHSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true,
                                 accessory: .elapsed(since: started), nested: true)
                    SHSidebarRow("Fix remote subagent deletion", state: .idle, accessory: .tag("horizon"), nested: true)
                    SHProjectRow("dashboard-web", count: 2, expanded: false, rollup: .waiting, toggle: {}, newThread: {}) { EmptyView() }
                    SHProjectRow("shepherd-daemon", count: 3, expanded: false, rollup: .running, toggle: {}, newThread: {}) { EmptyView() }
                    SHProjectRow("dotfiles", count: 1, expanded: false, toggle: {}, newThread: {}) { EmptyView() }
                    SHSidebarSection(.host("horizon", unreachable: true))
                    SHProjectRow("shepherd", count: 2, expanded: false, dimmed: true, toggle: {}, newThread: nil) { EmptyView() }
                }
                .padding(.horizontal, SHSidebarMetrics.listInset)
                .frame(width: 232, alignment: .top)
                .background(Color.sh.bgBase)
                .shDensity(density)
            }
        }
    }
}

#Preview("Organize by") {
    @Previewable @State var style = SHSidebarStyle.projects
    SHPreviewBoth {
        SHSidebarStylePicker(selection: $style).frame(width: 560)
    }
}

#Preview("Toolbar and pane header") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHThreadToolbar("Investigate SwiftUI live preview", project: "Shepherd") {
                SHBranchChip(kind: .worktree, branch: "pi/swiftui-previews", changedFiles: 3)
            } trailing: {
                SHSidePaneButton(isOn: false, shortcut: "⇧⌘B") {}
                SHOptionsMenu("Thread options") { Button("Rename…") {} }
            }
            SHThreadToolbar("Deploy media stack", project: "homelab", sidebar: {}) {
                SHBranchChip(kind: .checkout, branch: "chore/remove-homarr", changedFiles: 11, host: "horizon")
            } trailing: {
                SHSidePaneButton(isOn: true, shortcut: "⇧⌘B") {}
                SHOptionsMenu("Thread options") { Button("Rename…") {} }
            }
            SHPaneHeader("Review", close: {}) {
                HStack(spacing: SH.Space.xs) {
                    Text("4 files ·")
                    SHDiffStat(added: 67, removed: 58, font: .sh(.micro, weight: .regular))
                }
            } controls: {
                SHSegmentedPicker(selection: .constant(0), options: [(0, "Local"), (1, "PR #24")], size: .s)
            }
        }
        .frame(width: 720)
    }
}

#Preview("Side pane tabs and button") {
    SHPreviewBoth {
        VStack(alignment: .trailing, spacing: SH.Space.l) {
            SHSidePaneTabs([SHSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 4, shortcut: "⌃1")],
                           selection: "changes", select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                Button("Reset Width") {}
            }
            .frame(width: 600)
            SHSidePaneTabs([SHSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2, news: true)],
                           selection: "changes", select: { _ in }, close: {}) {
                Button("Reset Width") {}
            }
            .frame(width: 400)
            SHSidePaneButton(isOn: false, news: "Agent opened a review in Changes", shortcut: "⇧⌘B") {}
                .padding(.bottom, 48)
        }
        .frame(width: 720, alignment: .trailing)
    }
}

#Preview("Command palette") {
    @Previewable @State var query = "rev"
    @Previewable @FocusState var focused: Bool
    SHPreviewBoth {
        SHPaletteCard {
            SHPaletteSearchRow("Search commands, agents, subagents…", text: $query, focus: $focused, submit: {}) {
                SHSegmentedPicker(selection: .constant(0), options: [(0, "All"), (1, "Commands"), (2, "Agents")], size: .s)
            }
        } results: {
            VStack(alignment: .leading, spacing: 0) {
                SHPaletteSectionHeader("Commands")
                SHPaletteRow("New agent", systemImage: "plus", context: "in Shepherd/", shortcut: "⌘N", highlighted: true) {}
                SHPaletteRow("Review diff", systemImage: "plus.forwardslash.minus", context: "working tree · 4 files", shortcut: "⇧⌘B") {}
                SHPaletteSectionHeader("Agents")
                SHPaletteRow("Dock review pane", systemImage: "bubble.left", context: "running · 8m") {}
            }
        }
        .frame(width: SHPaletteMetrics.width)
    }
}

#Preview("Artifacts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHArtifactCard(SHArtifactRow(id: "a", name: "Load test report", detail: "HTML · 6m ago", symbol: "chevron.left.forwardslash.chevron.right"), open: {})
            SHArtifactList([SHArtifactRow(id: "a", name: "Load test report", detail: "HTML · 6m ago", symbol: "chevron.left.forwardslash.chevron.right"),
                            SHArtifactRow(id: "b", name: "retry-plan.md", detail: "Markdown · just now", symbol: "doc.text")], selection: "a", open: { _ in })
                .frame(height: 200)
        }
        .frame(width: 420)
    }
}
