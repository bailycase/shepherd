import SwiftUI

#Preview("List rows") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWListCard {
                NWListRow("Automations", leading: .symbol("bolt"), trailing: .value("3"))
                NWListRow("More", leading: .symbol("ellipsis"), trailing: .alert("1 host offline"))
            }
            NWListHeader("Needs you", attention: true, count: 2)
            NWListCard {
                NWListRow("Dock review pane", subtitle: "Where should review dock?", subtitleTone: .attention,
                          leading: .state(.attention), trailing: .host("Studio"))
            }
            NWListHeader("Recents")
            NWListCard {
                NWListRow("Plan shepherd extensions", subtitle: "running · swift build",
                          clock: .elapsed(since: Date().addingTimeInterval(-130)), leading: .state(.running),
                          trailing: .host("build-01"))
                NWListRow("Fix remote subagent deletion", subtitle: "idle",
                          clock: .ago(Date().addingTimeInterval(-3_700)), leading: .state(.idle), trailing: .host("horizon"))
                NWListRow("Investigate SwiftUI live preview", subtitle: "done · Shepherd", leading: .state(.done),
                          selected: true)
                NWListRow("Fix terminal output buffer", subtitle: "idle · Shepherd", leading: .state(.idle), dimmed: true)
            }
        }
        .frame(width: 360)
    }
}

#Preview("Needs you card") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWAttentionCard(symbol: nil, origin: "Thread", title: "Dock review pane",
                            question: "Where should review dock?", since: Date().addingTimeInterval(-840), host: "Studio") {
                Button("Beside the thread") {}.buttonStyle(.nw(.primary))
                Button("Over the thread") {}.buttonStyle(.nw(.secondary))
                Button("Open") {}.buttonStyle(.nw(.ghost))
            }
            NWAttentionCard(symbol: "arrow.triangle.branch", origin: "Subagent · Restyle native UI", title: "reviewer asks",
                            question: "Two token names collide. Rename the new ones, or replace the old ones everywhere?",
                            message: "Tokens.textSecondary", selected: true) {
                Button("Open") {}.buttonStyle(.nw(.secondary))
            }
        }
        .frame(width: 360)
    }
}

#Preview("Host cards") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWHostCard(name: "Studio", address: "studio.local:7433", state: .done, status: "Connected",
                       summary: "2 threads running · Shepherd, horizon", openLabel: "Edit Studio", open: {}) { EmptyView() }
            NWHostCard(name: "MacBook Air", address: "10.0.0.24:7433", state: .failed, status: "Offline",
                       summary: "Connection refused", summaryTone: .failed, detail: "Last seen today 07:12") {
                Button("Retry", systemImage: "arrow.clockwise") {}.buttonStyle(.nw(.secondary))
            }
        }
        .frame(width: 360)
    }
}

#Preview("iPad sidebar rows") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: 0) {
            NWListRow("New thread", leading: .badge("plus"), chevron: false, compact: true)
            NWListRow("Automations", leading: .symbol("bolt"), trailing: .value("4"), chevron: false, compact: true)
            NWListRow("More", leading: .symbol("chevron.down"), chevron: false, compact: true)
            NWListRow("Hosts", leading: .symbol("desktopcomputer"), trailing: .alert("1 offline"), chevron: false,
                      selected: true, compact: true)
                .padding(.leading, NW.Space.l)
            NWListHeader("Needs you", attention: true, count: 2, style: .sidebar)
            NWListRow("Dock review pane", leading: .state(.attention), trailing: .reason("asked you"), chevron: false, compact: true)
            NWListHeader("Recents", style: .sidebar)
            NWListRow("Plan shepherd extensions", leading: .state(.running), trailing: .host("build-01"), chevron: false, compact: true)
        }
        .frame(width: 300)
    }
}
