import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The parts the phone's and the iPad's review share: the summary card, a comment card, the
// section heads, a file's diff with its comments, and the states before a diff arrives.

/// The review's summary (MobileChanges board): "3 files", the diff stat, the worktree branch,
/// the viewed progress, and Finalize for a worktree agent.
struct ReviewSummaryCard: View {
    let totals: ReviewTotals
    let branch: String?
    let onFinalize: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let nw = Color.nw
        // At accessibility sizes the branch and Finalize's note get lines of their own.
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: NW.Space.m) {
            let header = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: NW.Space.xs)) : AnyLayout(HStackLayout(spacing: NW.Space.m))
            header {
                HStack(spacing: NW.Space.m) {
                    Text(totals.filesText).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                    NWDiffStat(added: totals.added, removed: totals.removed, font: .nw(.micro, weight: .regular))
                }
                if !large { Spacer(minLength: NW.Space.s) }
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.nw(.mono))
                        .foregroundStyle(nw.textSecondary)
                        .lineLimit(large ? 2 : 1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Branch \(branch)")
                }
            }
            HStack(spacing: NW.Space.m) {
                ProgressView(value: totals.progress)
                    .progressViewStyle(.nwBar(tint: nw.done))
                    .accessibilityLabel("Viewed")
                    .accessibilityValue(totals.viewedText)
                if !large {
                    Text(totals.viewedText).font(.nw(.caption)).foregroundStyle(nw.textTertiary).fixedSize()
                }
            }
            if large {
                Text(totals.viewedText).font(.nw(.caption)).foregroundStyle(nw.textTertiary)
            }
            if let onFinalize {
                NWHairline()
                Button(action: onFinalize) {
                    HStack(spacing: NW.Space.m) {
                        Label("Finalize worktree", systemImage: "checkmark.seal")
                            .font(.nw(.ui))
                            .foregroundStyle(nw.textPrimary)
                        Spacer(minLength: NW.Space.s)
                        if !large {
                            Text("commit · push · PR").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                        }
                        Image(systemName: "chevron.right").font(.nw(.caption, weight: .semibold)).foregroundStyle(nw.textTertiary)
                    }
                    .frame(minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Commits, pushes and opens a pull request on the host, then removes the worktree")
            }
        }
        .padding(NW.Space.l + NW.Space.xxs)
        .nwCard(radius: MobileLayout.cardRadius)
    }
}

/// A section's head above a card: "Files" with a note on the right.
struct ReviewSectionHead: View {
    let title: String
    let note: String?

    var body: some View {
        HStack {
            Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textSecondary)
            Spacer(minLength: NW.Space.s)
            if let note { Text(note).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary) }
        }
        .padding(.horizontal, NW.Space.xs)
        .padding(.top, NW.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The reviewer as a comment's author: the phone has no account name, so "You".
enum ReviewAuthor {
    static let name = "You"
    static let initial = "Y"
}

/// "just now", "12m ago", then the clock time: when a comment was written.
func reviewCommentAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    return nativeClockText(date.timeIntervalSince1970 * 1000)
}

/// A line comment as a card: in the changes list with its file, under its line without.
struct ReviewCommentCard: View {
    let comment: ReviewComment
    let showsFile: Bool
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        // In the changes list the file names the line; under its line, when it was written does.
        let meta = showsFile ? "\(reviewPathParts(comment.filePath).name) · line \(comment.lineNumber)"
            : "line \(comment.lineNumber) · \(reviewCommentAge(comment.createdAt))"
        NWInlineComment(initial: ReviewAuthor.initial, author: ReviewAuthor.name, meta: meta, text: comment.text,
                        onEdit: onEdit, onDelete: onDelete)
    }
}

/// Before the files arrive, a failed load, or no changes at all.
struct ReviewLoadState: View {
    let store: ReviewStore
    let retry: () -> Void

    var body: some View {
        if let error = store.loadError, !store.loaded {
            NWEmptyState(Text("Couldn't load the changes"), message: error) {
                Button("Try again", action: retry).buttonStyle(.nw(.secondary))
            }
        } else if !store.loaded {
            ProgressView().progressViewStyle(NWSpinnerStyle())
                .frame(maxWidth: .infinity, minHeight: NW.Height.touch * 2)
                .accessibilityLabel("Loading the changes")
        } else if store.files.isEmpty {
            NWEmptyState(Text("No changes"), message: store.filesArePR ? "This branch matches its PR base." : "The working tree matches HEAD.")
        }
    }
}

/// What a shown file's colors are for: the file, in one version of the review's files.
struct ReviewColorsKey: Hashable {
    let file: String?
    let version: Int
}

/// One file's diff as a lazy stack's rows: hunk headers, lines, folds, and each line's comment
/// under it. With `inlineEditor` the selected line opens a comment editor under it (iPad);
/// without, the selection is commented on from the screen's bottom bar (the phone).
struct ReviewDiffRows: View {
    let store: ReviewStore
    let fileID: String
    let gutters: Int
    let inlineEditor: Bool
    let tintedHunks: Bool
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        let rows = store.unifiedRows(fileID)
        let selected = store.selection?.fileID == fileID ? store.selection?.lineID : nil
        let comments = store.commentsByFile[fileID] ?? [:]
        let leading = NWTouchDiffMetrics.annotationLeading(gutters: gutters)
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 0) {
                switch row {
                case .hunk(_, let header):
                    NWTouchHunkHeader(header, leading: tintedHunks ? MobileLayout.gutter : leading, tinted: tintedHunks)
                case .line(let line):
                    NWTouchDiffLine(line, gutters: gutters, selected: selected == line.key, commented: comments[line.key] != nil) {
                        store.select(fileID: fileID, lineID: line.key)
                    }
                    .equatable()
                    annotation(line, comment: comments[line.key], selected: selected == line.key, leading: leading)
                case .fold(let id, let count, let kind, let range):
                    NWTouchFoldRow(count: count, kind: kind, range: range, leading: leading) {
                        withNWAnimation(.disclosure) { store.expand(id, in: fileID) }
                    }
                }
            }
            .background(Color.nw.bgWindow)
        }
    }

    @ViewBuilder
    private func annotation(_ line: NWDiffLineContent, comment: ReviewComment?, selected: Bool, leading: CGFloat) -> some View {
        if inlineEditor && selected {
            NWCommentEditor(text: store.draftBinding, isFocused: editorFocused, onSave: { store.saveDraft() }, onCancel: { store.clearSelection() })
                .padding(EdgeInsets(top: NW.Space.s, leading: leading, bottom: NW.Space.m, trailing: NW.Space.l))
        } else if let comment {
            ReviewCommentCard(comment: comment, showsFile: false,
                              onEdit: { store.select(fileID: fileID, lineID: line.key) },
                              onDelete: { store.deleteComment(fileID: fileID, lineID: line.key) })
                .padding(EdgeInsets(top: NW.Space.s, leading: leading, bottom: NW.Space.m, trailing: NW.Space.l))
        }
    }
}

/// One file's diff side by side (iPadReviewSplit board): the old file on the left, the working
/// tree on the right, and a comment under the side it was written on.
struct ReviewSplitRows: View {
    let store: ReviewStore
    let fileID: String
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        let rows = store.splitRows(fileID)
        let selected = store.selection?.fileID == fileID ? store.selection?.lineID : nil
        let comments = store.commentsByFile[fileID] ?? [:]
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 0) {
                switch row {
                case .hunk(_, let header):
                    NWTouchHunkHeader(header, leading: MobileLayout.gutter, tinted: false)
                case .pair(_, let old, let new):
                    // A context line is one line on both sides: it is selected and commented on the right.
                    let sides = old?.key == new?.key ? [new] : [old, new]
                    let selectedID = sides.compactMap { $0 }.first { $0.key == selected }?.id
                    NWSplitDiffRow(old: old, new: new, selected: selectedID) { line in
                        store.select(fileID: fileID, lineID: line.key)
                    }
                    .equatable()
                    ForEach(sides.compactMap { $0 }.filter { $0.key == selected || comments[$0.key] != nil }, id: \.id) { line in
                        splitAnnotation(line, comment: comments[line.key], selected: line.key == selected, onOld: line.id == old?.id && old?.key != new?.key)
                    }
                case .fold(_, let key, let count, let kind, let range, let side):
                    NWSplitFoldRow(count: count, kind: kind, range: range, side: side) {
                        withNWAnimation(.disclosure) { store.expand(key, in: fileID) }
                    }
                }
            }
            .background(Color.nw.bgWindow)
        }
    }

    /// Under its side: the left half for the old file, the right for the new.
    @ViewBuilder
    private func splitAnnotation(_ line: NWDiffLineContent, comment: ReviewComment?, selected: Bool, onOld: Bool) -> some View {
        let leading = NWTouchDiffMetrics.annotationLeading(gutters: 1)
        HStack(spacing: 0) {
            if !onOld { Color.clear.frame(maxWidth: .infinity) }
            Group {
                if selected {
                    NWCommentEditor(text: store.draftBinding, isFocused: editorFocused, onSave: { store.saveDraft() }, onCancel: { store.clearSelection() })
                } else if let comment {
                    ReviewCommentCard(comment: comment, showsFile: false,
                                      onEdit: { store.select(fileID: fileID, lineID: line.key) },
                                      onDelete: { store.deleteComment(fileID: fileID, lineID: line.key) })
                }
            }
            .padding(EdgeInsets(top: NW.Space.s, leading: leading, bottom: NW.Space.m, trailing: NW.Space.l))
            .frame(maxWidth: .infinity)
            if onOld { Color.clear.frame(maxWidth: .infinity) }
        }
    }
}
