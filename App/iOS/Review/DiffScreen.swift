import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One file's diff on iPhone (MobileDiff board): wrapped, syntax-colored lines with changed
/// words tinted and long runs folded (tap to show them), comments under their lines, and Next
/// file. The host sends a file's hunks when it is opened. Tapping a line selects
/// it; the bar at the bottom writes its comment. Mark viewed in the toolbar.
struct DiffScreen: View {
    let ref: AgentRef
    let path: String
    @Environment(MobileHosts.self) private var hosts
    /// The file on screen: Next file moves through the review without stacking screens.
    @State private var shown: String?
    @FocusState private var commentFocused: Bool

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        let entry = store.entry(shown) ?? store.entry(matching: path)
        let summary = store.summaries.first { $0.id == entry?.id }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let entry {
                    let state = store.state(of: entry.id)
                    if state == .lines {
                        ReviewDiffRows(store: store, fileID: entry.id, gutters: 1, inlineEditor: false, tintedHunks: true,
                                       editorFocused: $commentFocused)
                        if store.truncated.contains(entry.id) { ReviewTruncatedNote() }
                    } else {
                        ReviewFileNotice(state: state) { store.ensure(entry.id) }
                    }
                } else {
                    ReviewLoadState(store: store) { store.refresh() }
                    if store.loaded, !store.entries.isEmpty {
                        NWEmptyState(Text("Not in this diff"), message: "\(path) has no changes here.")
                    }
                }
            }
            .padding(.top, NW.Space.xs)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nw.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let label = store.selectionLabel, let selection = store.selection, selection.fileID == entry?.id {
                NWLineCommentBar(lineLabel: label, text: store.draftBinding, isFocused: $commentFocused,
                                 canDelete: store.comment(fileID: selection.fileID, lineID: selection.lineID) != nil,
                                 onSend: { store.saveDraft(); commentFocused = false },
                                 onDelete: { store.deleteComment(fileID: selection.fileID, lineID: selection.lineID) },
                                 onDone: { store.clearSelection(); commentFocused = false })
                    .padding(.horizontal, NW.Space.l)
                    .padding(.top, NW.Space.m)
                    .padding(.bottom, NW.Space.s)
                    .background(Color.nw.bgWindow)
                    .overlay(alignment: .top) { NWHairline() }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(summary?.name ?? reviewPathParts(path).name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                DiffTitle(summary: summary, position: entry.flatMap { store.index(of: $0.id) }, count: store.entries.count)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let entry {
                    let viewed = store.viewed.contains(entry.id)
                    Button(viewed ? "Mark unviewed" : "Mark viewed", systemImage: viewed ? "checkmark.circle.fill" : "checkmark.circle") {
                        store.toggleViewed(entry.id)
                    }
                    .tint(viewed ? Color.nw.done : nil)
                    if let next = store.entry(after: entry.id) {
                        Button("Next file", systemImage: "chevron.down") {
                            store.clearSelection()
                            shown = next.id
                        }
                        .accessibilityHint("Shows \(reviewPathParts(next.path).name)")
                    }
                }
            }
        }
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
        // The file's hunks come when it is read, and the next file's are fetched meanwhile.
        .task(id: entry?.id) {
            guard let entry else { return }
            store.ensure(entry.id)
            if let next = store.entry(after: entry.id) { store.ensure(next.id) }
        }
        .onChange(of: store.entries.count) { _, _ in
            if let entry { store.ensure(entry.id) }
        }
        .onDisappear { if store.draft.isEmpty { store.clearSelection() } }
    }
}

/// "FleetView.swift" over "App/iOS · 2 of 3 · +9 −7".
private struct DiffTitle: View {
    let summary: ReviewFileSummary?
    let position: Int?
    let count: Int

    var body: some View {
        VStack(spacing: NW.Space.xxs) {
            Text(summary?.name ?? "Diff").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
            if let summary {
                HStack(spacing: NW.Space.s) {
                    Text(subtitle(summary)).lineLimit(1).truncationMode(.head)
                    NWDiffStat(added: summary.added, removed: summary.removed, font: .nw(.micro, weight: .regular))
                }
                .font(.nw(.micro, weight: .regular))
                .foregroundStyle(Color.nw.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ summary: ReviewFileSummary) -> String {
        let directory = summary.directory.hasSuffix("/") ? String(summary.directory.dropLast()) : summary.directory
        let place = position.map { "\($0 + 1) of \(count)" }
        return [directory.isEmpty ? nil : directory, place].compactMap { $0 }.joined(separator: " · ") + " ·"
    }
}
