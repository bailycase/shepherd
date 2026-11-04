import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// One file of a pull request's diff on iPhone: wrapped lines, Mark viewed in the bar.
struct ForgeDiffScreen: View {
    let key: ForgeItemKey
    let path: String
    @Environment(MobileHosts.self) private var hosts
    @State private var rows: [SHDiffRow]?

    var body: some View {
        let store = ForgeStore.of(hosts)
        let model = store.files[key]?.value
        let summary = model?.summaries.first { $0.path == path }
        let parts = reviewPathParts(path)
        ScrollView {
            ForgeDiffRows(rows: rows, truncated: model?.file(path)?.truncated == true)
        }
        .background(Color.sh.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(parts.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: SH.Space.xxs) {
                    Text(parts.name).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                    if let summary {
                        HStack(spacing: SH.Space.s) {
                            if !parts.directory.isEmpty { Text(parts.directory).lineLimit(1).truncationMode(.head) }
                            SHDiffStat(added: summary.added, removed: summary.removed, font: .sh(.micro, weight: .regular))
                        }
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                let viewed = summary?.viewed == true
                Button(viewed ? "Mark unviewed" : "Mark viewed", systemImage: viewed ? "checkmark.circle.fill" : SHGlyph.resolved.symbolName) {
                    store.toggleViewed(key, path: path)
                }
                .tint(viewed ? Color.sh.done : nil)
            }
        }
        .task(id: path) {
            if store.files[key]?.value == nil { await store.loadFiles(key) }
            rows = store.files[key]?.value?.file(path).map { MissionFileScreen.rows($0.file) } ?? []
        }
    }
}

/// iPad: the pull request's diff beside it (iPadPRChanges): "Changes 5" with Close, head → base
/// with the viewed count, a chip per file, then the chosen file's head and lines.
struct ForgeDiffPane: View {
    let key: ForgeItemKey
    let path: String
    let choose: (String) -> Void
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts
    @State private var rows: [SHDiffRow]?

    var body: some View {
        let sh = Color.sh
        let store = ForgeStore.of(hosts)
        let model = store.files[key]?.value
        let detail = store.pullRequests[key]?.value?.detail
        let summary = model?.summaries.first { $0.path == path }
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                (Text("Changes ").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                    + Text("\(model?.summaries.count ?? 0)").font(.sh(.headline, weight: .regular)).foregroundStyle(sh.textTertiary))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                Button(action: close) {
                    Image(systemName: "xmark").font(.sh(.headline, weight: .regular)).foregroundStyle(sh.textSecondary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close changes")
            }
            .padding(.leading, SH.Space.xl)
            .padding(.trailing, SH.Space.s)
            .frame(minHeight: SH.Height.touch + SH.Space.m)
            SHHairline()
            if let detail {
                SHCompareRow(head: detail.summary.headRef, base: detail.summary.baseRef, note: model?.totals.viewedText, pickBase: nil)
            }
            if let model {
                ScrollView(.horizontal) {
                    HStack(spacing: SH.Space.m) {
                        ForEach(model.summaries) { file in
                            Button { choose(file.path) } label: {
                                Text(file.name)
                                    .font(.sh(.mono))
                                    .foregroundStyle(file.path == path ? sh.textPrimary : sh.textSecondary)
                                    .padding(.horizontal, SH.Space.l)
                                    .frame(minHeight: SH.Height.touch)
                                    .background(file.path == path ? sh.bgSelected : sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                                    .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(file.path == path ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.m)
                }
                .scrollIndicators(.hidden)
                SHHairline()
            }
            if let summary {
                HStack(spacing: SH.Space.m) {
                    Text(summary.name).font(.sh(.code, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                    SHDiffStat(added: summary.added, removed: summary.removed, font: .sh(.mono))
                    Spacer(minLength: SH.Space.m)
                    SHViewedCheckbox(isViewed: summary.viewed, name: summary.name) { store.toggleViewed(key, path: path) }
                }
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.touch)
                .background(sh.bgSunken)
            }
            ScrollView {
                ForgeDiffRows(rows: rows, truncated: model?.file(path)?.truncated == true)
            }
        }
        .background(sh.bgWindow)
        .task(id: path) {
            if store.files[key]?.value == nil { await store.loadFiles(key) }
            rows = store.files[key]?.value?.file(path).map { MissionFileScreen.rows($0.file) } ?? []
        }
    }
}

/// A file's lines as touch-diff rows (derived once per file, never in a body).
private struct ForgeDiffRows: View {
    let rows: [SHDiffRow]?
    let truncated: Bool

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let rows {
                if rows.isEmpty {
                    SHEmptyState(Text("No lines to show"), message: "A binary file, a rename, or a file GitHub left out of the diff.")
                        .padding(.top, SH.Space.xxl)
                }
                ForEach(rows) { row in
                    VStack(spacing: 0) {
                        switch row {
                        case .hunk(_, let header): SHTouchHunkHeader(header)
                        case .line(let line): SHTouchDiffLine(line).equatable()
                        case .fold: EmptyView()
                        }
                    }
                }
                if truncated {
                    Text("This file is cut short here.").shText(.caption).foregroundStyle(Color.sh.textTertiary).padding(MobileLayout.gutter)
                }
            } else {
                ProgressView().progressViewStyle(.shSpinner).padding(MobileLayout.gutter)
            }
        }
        .padding(.top, SH.Space.xs)
    }
}
