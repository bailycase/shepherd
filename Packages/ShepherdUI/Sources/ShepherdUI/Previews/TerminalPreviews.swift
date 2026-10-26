import SwiftUI

private enum TerminalSamples {
    static let tabs = [
        SHTerminalTab(id: "zsh", title: "zsh", host: "build-01"),
        SHTerminalTab(id: "psql", title: "psql payments", host: "build-01"),
        SHTerminalTab(id: "make", title: "make dev", activity: .running),
        SHTerminalTab(id: "logs", title: "tail -f logs", activity: .unseen),
        SHTerminalTab(id: "test", title: "go test", activity: .exited(failed: true)),
    ]

    static let keys = [
        SHTerminalKeycap(id: "esc", label: "esc", spokenLabel: "Escape"),
        SHTerminalKeycap(id: "tab", label: "tab", spokenLabel: "Tab"),
        SHTerminalKeycap(id: "ctrl", label: "ctrl", spokenLabel: "Control", isLatched: true),
        SHTerminalKeycap(id: "opt", label: "⌥", spokenLabel: "Option"),
        SHTerminalKeycap(id: "pipe", label: "|", spokenLabel: "Vertical bar"),
        SHTerminalKeycap(id: "tilde", label: "~", spokenLabel: "Tilde"),
        SHTerminalKeycap(id: "slash", label: "/", spokenLabel: "Slash"),
        SHTerminalKeycap(id: "dash", label: "-", spokenLabel: "Hyphen"),
        SHTerminalKeycap(id: "up", label: "↑", spokenLabel: "Up arrow"),
        SHTerminalKeycap(id: "down", label: "↓", spokenLabel: "Down arrow"),
        SHTerminalKeycap(id: "left", label: "←", spokenLabel: "Left arrow"),
        SHTerminalKeycap(id: "right", label: "→", spokenLabel: "Right arrow"),
    ]
}

#Preview("Terminal tab bar") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHTerminalTabBar(TerminalSamples.tabs, selection: "zsh", select: { _ in }, close: { _ in }, newTab: {}) {
                Button {} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Maximize")
                Button {} label: { Image(systemName: "xmark") }.accessibilityLabel("Hide terminal")
            }
            ForEach(TerminalSamples.tabs) { tab in
                SHTerminalTabView(tab: tab, isSelected: tab.id == "psql", select: {}, close: {})
            }
        }
        .frame(width: 720)
    }
}

#Preview("Terminal key row") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHTerminalNotice("attaching…").frame(height: 60)
            SHTerminalKeyRow(TerminalSamples.keys) { _ in }
            // A phone in portrait: two rows.
            SHTerminalKeyRow(TerminalSamples.keys) { _ in }.frame(width: 375)
        }
        .frame(width: 720)
    }
}


#Preview("Terminal panel parts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHTerminalFoldedThread(title: "Add refund events", state: .idle, restoreShortcut: "⇧⌘↩") {}
            SHTerminalSelectionBar(add: {}, copy: {})
            SHTerminalMenu {
                SHChangesMenuRow("New terminal in the worktree", subtitle: "payments on build-01", systemImage: "terminal",
                                 trailing: .chord("⌘D"), tallHeight: SHTerminalMetrics.menuTallRowHeight) {}
                SHChangesMenuRow("Rename tab", systemImage: "pencil") {}
                SHChangesMenuRow("Kill process", systemImage: "xmark", enabled: false) {}
            }
        }
        .frame(width: 720)
    }
}
