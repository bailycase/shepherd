import SwiftUI

/// The ChangesSplit board's outbox.go.
private enum ReviewSample {
    static func line(_ id: Int, _ kind: NWDiffLineKind, old: Int?, new: Int?, _ code: String) -> NWDiffLineContent {
        NWDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(code), source: code)
    }

    static let unified: [NWChangesRow] = [
        .line(line(1, .context, old: 37, new: 40, "type Outbox struct {")),
        .line(line(2, .context, old: 38, new: 41, "    db    *sql.DB")),
        .line(line(3, .removed, old: 39, new: nil, "    now func() time.Time")),
        .line(line(4, .added, old: nil, new: 42, "    now   func() time.Time")),
        .line(line(5, .added, old: nil, new: 43, "    codec events.Codec")),
        .fold(NWDiffFold(id: "f1", count: 55)),
        .line(line(6, .context, old: 96, new: 100, "func (o *Outbox) Append(ctx context.Context, tx *sql.Tx, e Event) error {")),
    ]

    static let split: [NWChangesRow] = [
        .pair(id: "p1", old: line(1, .context, old: 37, new: 40, "type Outbox struct {"), new: line(1, .context, old: 37, new: 40, "type Outbox struct {")),
        .pair(id: "p2", old: line(3, .removed, old: 39, new: nil, "    now func() time.Time"), new: line(4, .added, old: nil, new: 42, "    now   func() time.Time")),
        .pair(id: "p3", old: nil, new: line(5, .added, old: nil, new: 43, "    codec events.Codec")),
        .fold(NWDiffFold(id: "f1", count: 55)),
    ]

    static let files: [NWFileStrip.Item] = [
        .init(id: "a", path: "ledger/outbox.go", status: .modified, added: 21, removed: 8),
        .init(id: "b", path: "ledger/refund.go", status: .added, added: 64, removed: 0, isViewed: true),
        .init(id: "c", path: "ledger/refund_test.go", status: .added, added: 96, removed: 0, isTouched: true),
        .init(id: "d", path: "go.mod", status: .modified, added: 1, removed: 0),
    ]
}

#Preview("Diff") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWFileHeader(path: "ledger/outbox.go", status: .modified, added: 21, removed: 8, isExpanded: true, isViewed: false,
                         toggle: {}, toggleViewed: {}, comment: {}, open: {})
            NWDiffView(ReviewSample.split, notes: [4: "Wrap the error with the refund id too — the on-call runbook greps for it."],
                       onComment: { _ in }, onReveal: { _, _ in }) { _, text in
                NWInlineComment(initial: "B", author: "You", meta: "line 103 · just now", text: text, onEdit: {}, onDelete: {})
            }
            NWDiffView(ReviewSample.unified, onComment: { _ in }, onReveal: { _, _ in })
        }
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(.nw.lineSubtle, radius: NW.Radius.m)
        .frame(width: 720)
    }
}

#Preview("Toolbar") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                NWScopeButton(title: "Branch", glyph: .branch, isOpen: false) {}
                NWDiffStat(added: 200, removed: 8, font: .nw(.code))
                Spacer()
                NWViewedPill(viewed: 2, total: 5)
            }
            .padding(.horizontal, 12)
            .frame(height: NWChangesMetrics.toolbarHeight)
            NWCompareRow(head: "agent/refund-events", base: "origin/main", note: "merge base 3f2a91c") {}
            NWFileStrip(ReviewSample.files, selection: "a") { _ in }
            NWReviewSendBar(count: "2 comments", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
        }
        .frame(width: 620)
    }
}

#Preview("Comment editor") {
    @Previewable @State var draft = "Wrap the error with the refund id too"
    @Previewable @FocusState var focused: Bool
    NWPreviewBoth {
        NWCommentEditor(text: $draft, isFocused: $focused, context: "on line 103", onSave: {}, onCancel: {})
            .frame(width: 440)
    }
}

#Preview("Menus") {
    @Previewable @State var words = true
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.l) {
            NWChangesMenu(width: NWChangesMenuMetrics.scopeWidth) {
                NWChangesMenuRow("Last turn", subtitle: "What the agent changed since your last message", systemImage: "clock.arrow.circlepath",
                                 trailing: .stat(added: 12, removed: 3)) {}
                NWChangesMenuDivider()
                NWChangesMenuRow("Uncommitted", systemImage: "pencil", trailing: .stat(added: 33, removed: 11)) {}
                NWChangesMenuRow("Branch", subtitle: "agent/refund-events vs origin/main", systemImage: "arrow.triangle.branch",
                                 trailing: .stat(added: 200, removed: 8), checked: true) {}
            }
            NWChangesMenu(width: NWChangesMenuMetrics.optionsWidth) {
                NWChangesMenuTitle("Diff")
                NWChangesMenuToggle("Word diffs", systemImage: "text.word.spacing", isOn: $words)
            }
        }
    }
}
