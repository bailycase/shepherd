import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One file's diff on iPhone (MobileDiff board): wrapped, syntax-colored lines with long runs
/// folded (tap to show them), comments under their lines, and Next file. Tapping a line selects
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
        let file = store.file(shown) ?? store.file(matching: path)
        let summary = store.summaries.first { $0.id == file?.id }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let file {
                    if file.isBinary {
                        NWEmptyState(Text("Binary file"), message: "Its changes can't be shown as lines.")
                    } else if file.hunks.isEmpty {
                        NWEmptyState(Text("No line changes"), message: "The file was \(ReviewFileStatus(file) == .renamed ? "renamed" : "changed") without changing its lines.")
                    } else {
                        ReviewDiffRows(store: store, fileID: file.id, gutters: 1, inlineEditor: false, tintedHunks: true,
                                       editorFocused: $commentFocused)
                    }
                } else {
                    ReviewLoadState(store: store) { Task { await store.load(hosts: hosts) } }
                    if store.loaded, !store.files.isEmpty {
                        NWEmptyState(Text("Not in this diff"), message: "\(path) has no changes here.")
                    }
                }
            }
            .padding(.top, NW.Space.xs)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nw.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let label = store.selectionLabel, let selection = store.selection, selection.fileID == file?.id {
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
                DiffTitle(summary: summary, position: file.flatMap { store.index(of: $0.id) }, count: store.files.count)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let file {
                    let viewed = store.viewed.contains(file.id)
                    Button(viewed ? "Mark unviewed" : "Mark viewed", systemImage: viewed ? "checkmark.circle.fill" : "checkmark.circle") {
                        store.toggleViewed(file.id)
                    }
                    .tint(viewed ? Color.nw.done : nil)
                    if let next = store.file(after: file.id) {
                        Button("Next file", systemImage: "chevron.down") {
                            store.clearSelection()
                            shown = next.id
                        }
                        .accessibilityHint("Shows \(reviewPathParts(next.displayPath).name)")
                    }
                }
            }
        }
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
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
