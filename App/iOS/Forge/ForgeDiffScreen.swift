import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A file's hunks as touch-diff rows, plain text (derived once per read, never in `body`).
func forgeDiffRows(_ file: DiffFile) -> [SHDiffRow] {
    file.hunks.flatMap { hunk -> [SHDiffRow] in
        [.hunk(id: hunk.id, header: hunk.header)] + hunk.lines.map { line in
            let kind: SHDiffLineKind = switch line.kind { case .added: .added; case .removed: .removed; case .context: .context }
            return .line(SHDiffLineContent(id: "\(hunk.id)#\(line.id)", key: line.id, kind: kind, oldNumber: line.oldLine,
                                           newNumber: line.newLine, text: AttributedString(line.text), source: line.text))
        }
    }
}

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
            ForgeDiffRows(rows: rows, truncated: model?.file(path)?.truncated == true, key: key, path: path, store: store)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) { ForgeLineCommentBars(store: store, key: key, path: path) }
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
            rows = store.files[key]?.value?.file(path).map { forgeDiffRows($0.file) } ?? []
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
                ForgeDiffRows(rows: rows, truncated: model?.file(path)?.truncated == true, key: key, path: path, store: store)
            }
            .scrollDismissesKeyboard(.interactively)
            ForgeLineCommentBars(store: store, key: key, path: path)
        }
        .background(sh.bgWindow)
        .task(id: path) {
            if store.files[key]?.value == nil { await store.loadFiles(key) }
            rows = store.files[key]?.value?.file(path).map { forgeDiffRows($0.file) } ?? []
        }
    }
}

/// A file's lines as touch-diff rows (derived once per file, never in a body). Tapping a line
/// picks it for a comment; a line with a draft comment is marked.
private struct ForgeDiffRows: View {
    let rows: [SHDiffRow]?
    let truncated: Bool
    let key: ForgeItemKey
    let path: String
    let store: ForgeStore

    var body: some View {
        let selected = store.lineSelection.flatMap { $0.key == key && $0.path == path ? $0.lineKey : nil }
        let notes = Dictionary((store.drafts[key] ?? []).filter { $0.path == path }.map { ($0.lineKey, $0.comment.body) },
                               uniquingKeysWith: { a, _ in a })
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
                        case .line(let line):
                            SHTouchDiffLine(line, selected: line.key == selected, commented: notes[line.key] != nil) { tap(line) }
                                .equatable()
                            if let note = notes[line.key], line.key != selected {
                                // A comment waiting to be posted, under its line; tapping it edits it.
                                Button { tap(line) } label: {
                                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                        Text("You · not posted").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                        Text(note).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, SH.Space.l)
                                    .padding(.vertical, SH.Space.m)
                                    .shCard(radius: MobileLayout.cardRadius)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, MobileLayout.gutter + SH.Space.m)
                                .padding(.trailing, MobileLayout.gutter)
                                .padding(.vertical, SH.Space.s)
                                .accessibilityLabel("Your comment: \(note)")
                                .accessibilityHint("Edits it")
                            }
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

    private func tap(_ line: SHDiffLineContent) {
        let removed = line.kind == .removed
        guard let number = removed ? line.oldNumber : line.newNumber ?? line.oldNumber else { return }
        store.selectLine(key, path: path, lineKey: line.key, line: number, right: !removed)
    }
}

/// Under a pull request's diff: the selected line's comment field, else (with drafts waiting)
/// "2 comments, not posted" with Discard and Post on GitHub.
struct ForgeLineCommentBars: View {
    @Bindable var store: ForgeStore
    let key: ForgeItemKey
    let path: String
    @FocusState private var focused: Bool

    var body: some View {
        let drafts = store.drafts[key] ?? []
        VStack(spacing: 0) {
            if let failure = store.failure, !drafts.isEmpty {
                SHBanner(.failed, title: failure) {
                    Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
                }
                .padding(.horizontal, SH.Space.l)
                .padding(.top, SH.Space.m)
            }
            if let selection = store.lineSelection, selection.key == key, selection.path == path {
                SHLineCommentBar(lineLabel: "line \(selection.line)", text: $store.lineDraft, isFocused: $focused,
                                 canDelete: store.draft(selection) != nil,
                                 onSend: { store.saveLineDraft(); focused = false },
                                 onDelete: { store.deleteLineDraft(); focused = false },
                                 onDone: { store.clearLineSelection(); focused = false })
                    .padding(.horizontal, SH.Space.l)
                    .padding(.top, SH.Space.m)
                    .padding(.bottom, SH.Space.s)
                    .onAppear { focused = true }
            } else if !drafts.isEmpty {
                let files = Set(drafts.map(\.path)).count
                SHReviewSendBar(count: "\(drafts.count) comment\(drafts.count == 1 ? "" : "s")",
                                detail: files == 1 ? "" : "on \(files) files",
                                sending: store.posting.contains(key), size: .touch, sendTitle: "Post on GitHub",
                                onDiscard: { store.discardDrafts(key) }, onSend: { Task { await store.postDrafts(key) } })
            }
        }
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { if store.lineSelection?.key == key || !drafts.isEmpty { SHHairline() } }
    }
}
