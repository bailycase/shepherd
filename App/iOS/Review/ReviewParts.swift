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
        let sh = Color.sh
        // At accessibility sizes the branch and Finalize's note get lines of their own.
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: SH.Space.m) {
            // MobileChanges: the count and stat, the branch under them, then how much is viewed.
            HStack(spacing: SH.Space.m) {
                Text(totals.filesText).font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                SHDiffStat(added: totals.added, removed: totals.removed, font: .sh(.micro, weight: .regular))
            }
            if let branch {
                Text(branch)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(large ? 2 : 1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Branch \(branch)")
            }
            Text(totals.viewedText).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                .accessibilityLabel("Viewed")
                .accessibilityValue(totals.viewedText)
            if let onFinalize {
                SHHairline()
                Button(action: onFinalize) {
                    HStack(spacing: SH.Space.m) {
                        Label("Finalize worktree", systemImage: "checkmark.seal")
                            .font(.sh(.ui))
                            .foregroundStyle(sh.textPrimary)
                        Spacer(minLength: SH.Space.s)
                        if !large {
                            Text("commit · push · PR").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                        }
                        Image(systemName: "chevron.right").font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.textTertiary)
                    }
                    .frame(minHeight: SH.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Commits, pushes and opens a pull request on the host, then removes the worktree")
            }
        }
        .padding(SH.Space.l + SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.cardRadius)
    }
}

/// A section's head above a card: "Files" with a note on the right.
struct ReviewSectionHead: View {
    let title: String
    let note: String?

    var body: some View {
        HStack {
            Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: SH.Space.s)
            if let note { Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
        }
        .padding(.horizontal, SH.Space.xs)
        .padding(.top, SH.Space.xs)
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
        if showsFile {
            // MobileChanges: the file and line, the text, then Edit and Delete under it.
            let sh = Color.sh
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text(meta).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1)
                Text(comment.text).font(.sh(.body)).foregroundStyle(sh.textPrimary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SH.Space.m) {
                    if let onEdit { Button("Edit", action: onEdit).buttonStyle(.shLink(color: sh.textSecondary, font: .sh(.body))) }
                    if let onDelete { Button("Delete", action: onDelete).buttonStyle(.shLink(color: sh.failed, font: .sh(.body))) }
                }
            }
            .padding(.horizontal, SH.Space.l + SH.Space.xxs)
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shCard(radius: MobileLayout.cardRadius)
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if let onEdit { Button("Edit", action: onEdit) }
                if let onDelete { Button("Delete", action: onDelete) }
            }
        } else {
        SHInlineComment(initial: ReviewAuthor.initial, author: ReviewAuthor.name, meta: meta, text: comment.text,
                        onEdit: onEdit, onDelete: onDelete)
        }
    }
}

/// Before the files arrive, a failed load, or no changes at all.
struct ReviewLoadState: View {
    let store: ReviewStore
    let retry: () -> Void

    var body: some View {
        if let error = store.loadError, !store.loaded {
            SHEmptyState(Text("Couldn't load the changes"), message: error) {
                Button("Try again", action: retry).buttonStyle(.sh(.secondary))
            }
        } else if !store.loaded {
            ProgressView().progressViewStyle(SHSpinnerStyle())
                .frame(maxWidth: .infinity, minHeight: SH.Height.touch * 2)
                .accessibilityLabel("Loading the changes")
        } else if store.entries.isEmpty {
            SHEmptyState(Text("No changes"), message: reviewEmptyText(store))
        }
    }
}

/// Why a review has no files, in the scope's words.
@MainActor func reviewEmptyText(_ store: ReviewStore) -> String {
    guard store.usesChanges else {
        return store.filesArePR ? "This branch matches its PR base." : "The working tree matches HEAD."
    }
    switch store.scope?.kind {
    case .lastTurn?: return "The agent's last turn changed no files."
    case .uncommitted?: return "The working tree matches HEAD."
    case .unstaged?: return "The working tree matches the index."
    case .staged?: return "Nothing is staged."
    case .commits?: return "These commits change no files."
    case .branch?: return "The branch matches \(store.compare?.base ?? "its base")."
    case .pullRequest?: return "The pull request changes no files."
    case nil: return "Nothing to compare."
    }
}

/// What a file shows instead of its lines: loading, a failed fetch, a binary file, or none.
struct ReviewFileNotice: View {
    let state: ReviewStore.FileState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView().progressViewStyle(SHSpinnerStyle())
                .frame(maxWidth: .infinity, minHeight: SH.Height.touch * 2)
                .accessibilityLabel("Loading the file's changes")
        case .failed(let message):
            SHEmptyState(Text("Couldn't load this file"), message: message) {
                Button("Try again", action: retry).buttonStyle(.sh(.secondary))
            }
        case .binary:
            SHEmptyState(Text("Binary file"), message: "Its changes can't be shown as lines.")
        case .noLines(let renamed):
            SHEmptyState(Text("No line changes"), message: "The file was \(renamed ? "renamed" : "changed") without changing its lines.")
        case .lines:
            EmptyView()
        }
    }
}

/// "Show 18 unchanged lines" before a hunk (iPadReview): a tap asks the host for the whole file.
struct ReviewGapRow: View {
    let count: Int
    let action: (() -> Void)?

    var body: some View {
        let sh = Color.sh
        let label = Text(action == nil ? nativeCount(count, "unchanged line") : "Show \(nativeCount(count, "unchanged line"))")
            .font(.sh(.caption))
            .foregroundStyle(sh.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
            .background(sh.bgSunken)
            .overlay(alignment: .top) { SHHairline() }
            .contentShape(Rectangle())
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityHint("Loads the whole file")
        } else {
            label
        }
    }
}

/// A file's truncation, when the host cut it short.
struct ReviewTruncatedNote: View {
    var body: some View {
        Text("This file is cut short: it has more changed lines than a review shows.")
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One unified row with its comment (or the comment being written) under it: one view per row,
/// for a lazy stack. With `inlineEditor` the selected line opens a comment editor under it
/// (iPad); without, the selection is commented on from the screen's bottom bar (the phone).
struct ReviewUnifiedRowView: View {
    let store: ReviewStore
    let fileID: String
    let row: ReviewUnifiedRow
    let gutters: Int
    let inlineEditor: Bool
    let tintedHunks: Bool
    let changeBars: Bool
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        let leading = SHTouchDiffMetrics.annotationLeading(gutters: gutters)
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .hunk(_, let header, let gap):
                // iPadReview: the unchanged lines before a hunk, then its head.
                if let gap, gap > 0 { ReviewGapRow(count: gap, action: store.opensGaps ? { store.loadWhole(fileID) } : nil) }
                SHTouchHunkHeader(header, leading: tintedHunks ? MobileLayout.gutter : leading, tinted: tintedHunks)
            case .line(let line):
                let selected = store.selection == ReviewStore.LineKey(fileID: fileID, lineID: line.key)
                let comment = store.commentsByFile[fileID]?[line.key]
                SHTouchDiffLine(line, gutters: gutters, selected: selected, commented: comment != nil, changeBar: changeBars) {
                    store.select(fileID: fileID, lineID: line.key)
                }
                .equatable()
                annotation(line, comment: comment, selected: selected, leading: leading)
            case .fold(let id, let count, let kind, let range):
                SHTouchFoldRow(count: count, kind: kind, range: range, leading: leading) {
                    withSHAnimation(.disclosure) { store.expand(id, in: fileID) }
                }
            }
        }
        .background(Color.sh.bgWindow)
    }

    @ViewBuilder
    private func annotation(_ line: SHDiffLineContent, comment: ReviewComment?, selected: Bool, leading: CGFloat) -> some View {
        if inlineEditor && selected {
            SHCommentEditor(text: store.draftBinding, isFocused: editorFocused, onSave: { store.saveDraft() }, onCancel: { store.clearSelection() })
                .padding(EdgeInsets(top: SH.Space.s, leading: leading, bottom: SH.Space.m, trailing: SH.Space.l))
        } else if let comment {
            ReviewCommentCard(comment: comment, showsFile: false,
                              onEdit: { store.select(fileID: fileID, lineID: line.key) },
                              onDelete: { store.deleteComment(fileID: fileID, lineID: line.key) })
                .padding(EdgeInsets(top: SH.Space.s, leading: leading, bottom: SH.Space.m, trailing: SH.Space.l))
        }
    }
}

/// One file's unified diff as a lazy stack's rows (the phone's diff reader).
struct ReviewDiffRows: View {
    let store: ReviewStore
    let fileID: String
    let gutters: Int
    let inlineEditor: Bool
    let tintedHunks: Bool
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        ForEach(store.unifiedRows(fileID, gaps: false)) { row in
            ReviewUnifiedRowView(store: store, fileID: fileID, row: row, gutters: gutters, inlineEditor: inlineEditor,
                                 tintedHunks: tintedHunks, changeBars: false, editorFocused: editorFocused)
        }
    }
}

/// One side-by-side row (iPadReviewSplit): the old file on the left, the new on the right, a
/// hatched side where one has no line, and a comment under the side it was written on.
struct ReviewSplitRowView: View {
    let store: ReviewStore
    let fileID: String
    let row: ReviewSplitDisplayRow
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        let selected = store.selection?.fileID == fileID ? store.selection?.lineID : nil
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .hunk(_, _, let gap):
                if gap > 0 {
                    ReviewGapRow(count: gap, action: store.opensGaps ? { store.loadWhole(fileID) } : nil)
                }
            case .pair(_, let old, let new):
                // A context line is one line on both sides: it is selected and commented on the right.
                let sides = old?.key == new?.key ? [new] : [old, new]
                let selectedID = sides.compactMap { $0 }.first { $0.key == selected }?.id
                let comments = store.commentsByFile[fileID] ?? [:]
                SHSplitDiffRow(old: old, new: new, selected: selectedID, hatched: true) { line in
                    store.select(fileID: fileID, lineID: line.key)
                }
                .equatable()
                ForEach(sides.compactMap { $0 }.filter { $0.key == selected || comments[$0.key] != nil }, id: \.id) { line in
                    splitAnnotation(line, comment: comments[line.key], selected: line.key == selected, onOld: line.id == old?.id && old?.key != new?.key)
                }
            case .fold(_, let key, let count, let kind, let range, let side):
                SHSplitFoldRow(count: count, kind: kind, range: range, side: side) {
                    withSHAnimation(.disclosure) { store.expand(key, in: fileID) }
                }
            }
        }
        .background(Color.sh.bgWindow)
    }

    /// Under its side: the left half for the old file, the right for the new.
    @ViewBuilder
    private func splitAnnotation(_ line: SHDiffLineContent, comment: ReviewComment?, selected: Bool, onOld: Bool) -> some View {
        let leading = SHTouchDiffMetrics.annotationLeading(gutters: 1)
        HStack(spacing: 0) {
            if !onOld { Color.clear.frame(maxWidth: .infinity) }
            Group {
                if selected {
                    SHCommentEditor(text: store.draftBinding, isFocused: editorFocused, onSave: { store.saveDraft() }, onCancel: { store.clearSelection() })
                } else if let comment {
                    ReviewCommentCard(comment: comment, showsFile: false,
                                      onEdit: { store.select(fileID: fileID, lineID: line.key) },
                                      onDelete: { store.deleteComment(fileID: fileID, lineID: line.key) })
                }
            }
            .padding(EdgeInsets(top: SH.Space.s, leading: leading, bottom: SH.Space.m, trailing: SH.Space.l))
            .frame(maxWidth: .infinity)
            if onOld { Color.clear.frame(maxWidth: .infinity) }
        }
    }
}
