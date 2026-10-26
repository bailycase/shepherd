import SwiftUI

/// The ChangesSplit board's outbox.go.
private enum ReviewSample {
    static func line(_ id: Int, _ kind: SHDiffLineKind, old: Int?, new: Int?, _ code: String) -> SHDiffLineContent {
        SHDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(code), source: code)
    }

    static let unified: [SHChangesRow] = [
        .line(line(1, .context, old: 37, new: 40, "type Outbox struct {")),
        .line(line(2, .context, old: 38, new: 41, "    db    *sql.DB")),
        .line(line(3, .removed, old: 39, new: nil, "    now func() time.Time")),
        .line(line(4, .added, old: nil, new: 42, "    now   func() time.Time")),
        .line(line(5, .added, old: nil, new: 43, "    codec events.Codec")),
        .fold(SHDiffFold(id: "f1", count: 55)),
        .line(line(6, .context, old: 96, new: 100, "func (o *Outbox) Append(ctx context.Context, tx *sql.Tx, e Event) error {")),
    ]

    static let split: [SHChangesRow] = [
        .pair(id: "p1", old: line(1, .context, old: 37, new: 40, "type Outbox struct {"), new: line(1, .context, old: 37, new: 40, "type Outbox struct {")),
        .pair(id: "p2", old: line(3, .removed, old: 39, new: nil, "    now func() time.Time"), new: line(4, .added, old: nil, new: 42, "    now   func() time.Time")),
        .pair(id: "p3", old: nil, new: line(5, .added, old: nil, new: 43, "    codec events.Codec")),
        .fold(SHDiffFold(id: "f1", count: 55)),
    ]

    static let files: [SHFileStrip.Item] = [
        .init(id: "a", path: "ledger/outbox.go", status: .modified, added: 21, removed: 8),
        .init(id: "b", path: "ledger/refund.go", status: .added, added: 64, removed: 0, isViewed: true),
        .init(id: "c", path: "ledger/refund_test.go", status: .added, added: 96, removed: 0, isTouched: true),
        .init(id: "d", path: "go.mod", status: .modified, added: 1, removed: 0),
    ]
}

#Preview("Diff") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHFileHeader(path: "ledger/outbox.go", status: .modified, added: 21, removed: 8, isExpanded: true, isViewed: false,
                         toggle: {}, toggleViewed: {}, comment: {}, open: {})
            SHDiffView(ReviewSample.split, notes: [4: "Wrap the error with the refund id too — the on-call runbook greps for it."],
                       onComment: { _ in }, onReveal: { _, _ in }) { _, text in
                SHInlineComment(initial: "B", author: "You", meta: "line 103 · just now", text: text, onEdit: {}, onDelete: {})
            }
            SHDiffView(ReviewSample.unified, onComment: { _ in }, onReveal: { _, _ in })
        }
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(.sh.lineSubtle, radius: SH.Radius.m)
        .frame(width: 720)
    }
}

#Preview("Toolbar") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SHScopeButton(title: "Branch", glyph: .branch, isOpen: false) {}
                SHDiffStat(added: 200, removed: 8, font: .sh(.code))
                Spacer()
                SHViewedPill(viewed: 2, total: 5)
            }
            .padding(.horizontal, 12)
            .frame(height: SHChangesMetrics.toolbarHeight)
            SHCompareRow(head: "agent/refund-events", base: "origin/main", note: "merge base 3f2a91c") {}
            SHFileStrip(ReviewSample.files, selection: "a") { _ in }
            SHReviewSendBar(count: "2 comments", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
        }
        .frame(width: 620)
    }
}

#Preview("Comment editor") {
    @Previewable @State var draft = "Wrap the error with the refund id too"
    @Previewable @FocusState var focused: Bool
    SHPreviewBoth {
        SHCommentEditor(text: $draft, isFocused: $focused, context: "on line 103", onSave: {}, onCancel: {})
            .frame(width: 440)
    }
}

#Preview("Menus") {
    @Previewable @State var words = true
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.l) {
            SHChangesMenu(width: SHChangesMenuMetrics.scopeWidth) {
                SHChangesMenuRow("Last turn", subtitle: "What the agent changed since your last message", systemImage: "clock.arrow.circlepath",
                                 trailing: .stat(added: 12, removed: 3)) {}
                SHChangesMenuDivider()
                SHChangesMenuRow("Uncommitted", systemImage: "pencil", trailing: .stat(added: 33, removed: 11)) {}
                SHChangesMenuRow("Branch", subtitle: "agent/refund-events vs origin/main", systemImage: SHGlyph.gitBranch.symbolName,
                                 trailing: .stat(added: 200, removed: 8), checked: true) {}
            }
            SHChangesMenu(width: SHChangesMenuMetrics.optionsWidth) {
                SHChangesMenuTitle("Diff")
                SHChangesMenuToggle("Word diffs", systemImage: "text.word.spacing", isOn: $words)
            }
        }
    }
}
