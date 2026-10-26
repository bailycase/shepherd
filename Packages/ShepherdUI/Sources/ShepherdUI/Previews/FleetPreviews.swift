import SwiftUI

#Preview("List rows") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHListCard {
                SHListRow("Automations", leading: .symbol("bolt"), trailing: .value("3"))
                SHListRow("More", leading: .symbol("ellipsis"), trailing: .alert("1 host offline"))
            }
            SHListHeader("Needs you", attention: true, count: 2)
            SHListCard {
                SHListRow("Dock review pane", subtitle: "Where should review dock?", subtitleTone: .attention,
                          leading: .state(.attention), trailing: .host("Studio"))
            }
            SHListHeader("Recents")
            SHListCard {
                SHListRow("Plan shepherd extensions", subtitle: "running · swift build",
                          clock: .elapsed(since: Date().addingTimeInterval(-130)), leading: .state(.running),
                          trailing: .host("build-01"))
                SHListRow("Fix remote subagent deletion", subtitle: "idle",
                          clock: .ago(Date().addingTimeInterval(-3_700)), leading: .state(.idle), trailing: .host("horizon"))
                SHListRow("Investigate SwiftUI live preview", subtitle: "done · Shepherd", leading: .state(.done),
                          selected: true)
                SHListRow("Fix terminal output buffer", subtitle: "idle · Shepherd", leading: .state(.idle), dimmed: true)
            }
        }
        .frame(width: 360)
    }
}

#Preview("Needs you card") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHAttentionCard(symbol: nil, origin: "Thread", title: "Dock review pane",
                            question: "Where should review dock?", since: Date().addingTimeInterval(-840), host: "Studio") {
                Button("Beside the thread") {}.buttonStyle(.sh(.primary))
                Button("Over the thread") {}.buttonStyle(.sh(.secondary))
                Button("Open") {}.buttonStyle(.sh(.ghost))
            }
            SHAttentionCard(symbol: SHGlyph.gitBranch.symbolName, origin: "Subagent · Restyle native UI", title: "reviewer asks",
                            question: "Two token names collide. Rename the new ones, or replace the old ones everywhere?",
                            message: "Tokens.textSecondary", selected: true) {
                Button("Open") {}.buttonStyle(.sh(.secondary))
            }
        }
        .frame(width: 360)
    }
}

#Preview("Host cards") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHHostCard(name: "Studio", address: "studio.local:7433", state: .done, status: "Connected",
                       summary: "2 threads running · Shepherd, horizon", openLabel: "Edit Studio", open: {}) { EmptyView() }
            SHHostCard(name: "MacBook Air", address: "10.0.0.24:7433", state: .failed, status: "Offline",
                       summary: "Connection refused", summaryTone: .failed, detail: "Last seen today 07:12") {
                Button("Retry", systemImage: "arrow.clockwise") {}.buttonStyle(.sh(.secondary))
            }
        }
        .frame(width: 360)
    }
}

#Preview("iPad sidebar rows") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: 0) {
            SHListRow("New thread", leading: .badge("plus"), chevron: false, compact: true)
            SHListRow("Automations", leading: .symbol("bolt"), trailing: .value("4"), chevron: false, compact: true)
            SHListRow("More", leading: .symbol("chevron.down"), chevron: false, compact: true)
            SHListRow("Hosts", leading: .symbol("desktopcomputer"), trailing: .alert("1 offline"), chevron: false,
                      selected: true, compact: true)
                .padding(.leading, SH.Space.l)
            SHListHeader("Needs you", attention: true, count: 2, style: .sidebar)
            SHListRow("Dock review pane", leading: .state(.attention), trailing: .reason("asked you"), chevron: false, compact: true)
            SHListHeader("Recents", style: .sidebar)
            SHListRow("Plan shepherd extensions", leading: .state(.running), trailing: .host("build-01"), chevron: false, compact: true)
        }
        .frame(width: 300)
    }
}

#Preview("Overview cards") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHListCard {
                SHCaptionBand("Threads · 2")
                SHOverviewRow("Investigate SwiftUI live preview", detail: "swift test --filter toolPreview", leading: .state(.running),
                              time: .elapsed(since: Date().addingTimeInterval(-252)))
                SHOverviewRow("Restyle native UI", detail: "3 subagents · 1 needs you", leading: .state(.running),
                              time: .elapsed(since: Date().addingTimeInterval(-2_220)))
            }
            SHListCard {
                SHCaptionBand("Today")
                SHOverviewRow("Ship native UI v2", detail: "done · Shepherd", detailMono: false, leading: .symbol("checkmark", .done),
                              time: .text("11:02"))
            }
        }
        .frame(width: 280)
    }
}

#Preview("Needs you items") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xxs) {
            SHAttentionCard(symbol: SHGlyph.gitBranch.symbolName, origin: "Subagent · Restyle native UI", title: "reviewer asks",
                            question: "Rename the new ones, or replace the old ones?", since: Date().addingTimeInterval(-120),
                            selected: true, style: .item) { EmptyView() }
            SHAttentionCard(symbol: nil, origin: "Thread", title: "Dock review pane", question: "Plan ready to approve",
                            since: Date().addingTimeInterval(-840), style: .item) { EmptyView() }
        }
        .frame(width: 360)
    }
}

#Preview("Host rows") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xxs) {
            SHHostRow(name: "Studio", detail: "3 threads · 2 running", state: .done, selected: true)
            SHHostRow(name: "build-01", detail: "1 thread", state: .done)
            SHHostRow(name: "horizon", detail: "Offline · last seen 7:12 AM", state: .failed)
        }
        .frame(width: 320)
    }
}
