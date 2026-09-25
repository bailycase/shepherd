import SwiftUI

private enum TerminalSamples {
    static let tabs = [
        NWTerminalTab(id: "zsh", title: "zsh", host: "build-01"),
        NWTerminalTab(id: "psql", title: "psql payments", host: "build-01"),
        NWTerminalTab(id: "make", title: "make dev", activity: .running),
        NWTerminalTab(id: "logs", title: "tail -f logs", activity: .unseen, panes: 2),
        NWTerminalTab(id: "test", title: "go test", activity: .exited(failed: true)),
    ]

    static let keys = [
        NWTerminalKeycap(id: "esc", label: "esc", spokenLabel: "Escape"),
        NWTerminalKeycap(id: "tab", label: "tab", spokenLabel: "Tab"),
        NWTerminalKeycap(id: "ctrl", label: "ctrl", spokenLabel: "Control", isLatched: true),
        NWTerminalKeycap(id: "opt", label: "⌥", spokenLabel: "Option"),
        NWTerminalKeycap(id: "up", label: "↑", spokenLabel: "Up arrow"),
        NWTerminalKeycap(id: "down", label: "↓", spokenLabel: "Down arrow"),
        NWTerminalKeycap(id: "left", label: "←", spokenLabel: "Left arrow"),
        NWTerminalKeycap(id: "right", label: "→", spokenLabel: "Right arrow"),
        NWTerminalKeycap(id: "pipe", label: "|", spokenLabel: "Vertical bar"),
        NWTerminalKeycap(id: "tilde", label: "~", spokenLabel: "Tilde"),
        NWTerminalKeycap(id: "slash", label: "/", spokenLabel: "Slash"),
        NWTerminalKeycap(id: "dash", label: "-", spokenLabel: "Hyphen"),
    ]
}

#Preview("Terminal tab bar") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWTerminalTabBar(TerminalSamples.tabs, selection: "zsh", select: { _ in }, close: { _ in }, newTab: {}) {
                Button {} label: { Image(systemName: "rectangle.split.2x1") }.accessibilityLabel("Split right")
                Button {} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Maximize")
                Button {} label: { Image(systemName: "xmark") }.accessibilityLabel("Hide terminal")
            }
            ForEach(TerminalSamples.tabs) { tab in
                NWTerminalTabView(tab: tab, isSelected: tab.id == "psql", select: {}, close: {})
            }
        }
        .frame(width: 720)
    }
}

#Preview("Terminal key row") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWTerminalNotice("attaching…").frame(height: 60)
            NWTerminalKeyRow(TerminalSamples.keys) { _ in }
        }
        .frame(width: 720)
    }
}
