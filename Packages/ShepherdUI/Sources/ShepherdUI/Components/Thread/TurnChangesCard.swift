import SwiftUI

/// The "Edited N files" card that ends a turn on touch (ChangesStates › ChangesCard;
/// MobileThread, iPadReview): the title over its stat, Undo (in `textSecondary`) and Review (in `textPrimary`) as words, then
/// the first files as plain paths (the folder dimmed, "new" before a created file's stat) and "Show
/// N more", which lists the next files (`SHChangesMore`). Once undone it is one dashed line, "Undid the agent’s edits to 5 files", with Redo.
/// At the accessibility sizes the head stacks and paths take two lines, so nothing clips.
public struct SHTurnChangesCard: View, Equatable {
    public struct File: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var path: String
        public var directory: String
        public var name: String
        public var isNew: Bool
        public var added: Int
        public var removed: Int

        public init(path: String, directory: String, name: String, isNew: Bool, added: Int, removed: Int) {
            self.path = path
            self.directory = directory
            self.name = name
            self.isNew = isNew
            self.added = added
            self.removed = removed
        }
    }

    let title: String
    let added: Int
    let removed: Int
    let files: [File]
    /// Every file the turn changed; `files` may be only the first of them.
    let total: Int
    let undone: Bool
    /// Undo or Redo is on its way to the host.
    let busy: Bool
    let onUndo: (() -> Void)?
    let onRedo: (() -> Void)?
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shownCount = SHThreadMetrics.changesShownFiles

    public init(title: String, added: Int, removed: Int, files: [File], total: Int? = nil, undone: Bool = false, busy: Bool = false,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil, onReview: (() -> Void)? = nil, onOpen: ((String) -> Void)? = nil) {
        self.title = title
        self.added = added
        self.removed = removed
        self.files = files
        self.total = max(total ?? files.count, files.count)
        self.undone = undone
        self.busy = busy
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onReview = onReview
        self.onOpen = onOpen
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.added == rhs.added && lhs.removed == rhs.removed && lhs.files == rhs.files && lhs.total == rhs.total
            && lhs.undone == rhs.undone && lhs.busy == rhs.busy && (lhs.onUndo == nil) == (rhs.onUndo == nil)
            && (lhs.onRedo == nil) == (rhs.onRedo == nil) && (lhs.onReview == nil) == (rhs.onReview == nil)
            && (lhs.onOpen == nil) == (rhs.onOpen == nil)
    }

    public var body: some View {
        if undone { undoneLine } else { card }
    }

    // MARK: Card

    private var card: some View {
        let sh = Color.sh
        let more = SHChangesMore(shown: min(shownCount, files.count), listed: files.count, total: total)
        return VStack(spacing: 0) {
            head
            ForEach(files.prefix(shownCount)) { file in
                SHHairline()
                row(file)
            }
            if more != .none {
                SHHairline()
                moreRow(more)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.xxl))
        .shBorder(sh.lineSubtle, radius: SH.Radius.xxl)
        .shLift(RoundedRectangle(cornerRadius: SH.Radius.xxl))
        .accessibilityElement(children: .contain)
    }

    /// The head on one line while it fits, else the title over the actions (a narrow column,
    /// the accessibility sizes), so neither the title nor Undo truncates.
    private var head: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stackedHead
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SH.Space.m + SH.Space.xxs) {
                        summary.fixedSize()
                        Spacer(minLength: 0)
                        actions
                    }
                    stackedHead
                }
            }
        }
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.m + SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stackedHead: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            summary
            actions
        }
    }

    private var summary: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text(title).font(.sh(.title)).foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            SHDiffStat(added: added, removed: removed, font: .sh(.caption))
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.xs) {
            if let onUndo {
                Button(action: onUndo) {
                    Text("Undo").font(.sh(.title, weight: .regular)).foregroundStyle(sh.textSecondary)
                        .padding(.horizontal, SH.Space.m)
                        .shTouchTarget(height: SH.Height.controlM)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Undo the agent\u{2019}s edits")
                .accessibilityHint("Puts back the files this turn changed, in the working tree")
            }
            if let onReview {
                Button(action: onReview) {
                    Text("Review").font(.sh(.title, weight: .medium)).foregroundStyle(sh.textPrimary)
                        .padding(.horizontal, SH.Space.m)
                        .shTouchTarget(height: SH.Height.controlM)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review \(title)")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func row(_ file: File) -> some View {
        let sh = Color.sh
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs)) : AnyLayout(HStackLayout(spacing: SH.Space.m))
        let content = layout {
            Text("\(Text(file.directory).foregroundStyle(sh.textTertiary))\(Text(file.name).foregroundStyle(sh.textPrimary))")
                .font(.shSans(14))
                .lineLimit(stacked ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SH.Space.m) {
                if file.isNew { Text("new").font(.sh(.caption)).foregroundStyle(sh.textTertiary) }
                SHDiffStat(added: file.added, removed: file.removed, font: .sh(.caption))
            }
            .fixedSize()
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, stacked ? SH.Space.m : 0)
        .frame(minHeight: SHTurnChangesCard.rowHeight)
        .contentShape(Rectangle())
        let label = "\(file.path), \(file.isNew ? "new, " : "")\(file.added) added, \(file.removed) removed"
        if let onOpen {
            Button { onOpen(file.path) } label: { content }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityLabel(label)
                .accessibilityHint("Opens the file in review")
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        }
    }

    @ViewBuilder private func moreRow(_ more: SHChangesMore) -> some View {
        let text = if case .review(let count) = more, onReview == nil { "\(count) more" } else { more.text ?? "" }
        let content = Text(text)
            .font(.shSans(14))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: SHTurnChangesCard.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        switch more {
        case .show(let count):
            Button { shownCount += count } label: { content }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityLabel("Show \(count) more files")
        case .review:
            if let onReview {
                Button(action: onReview) { content }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityHint("Opens every file in review")
            } else {
                content
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Undone

    private var undoneLine: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: "arrow.uturn.backward")
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.shSans(14))
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRedo {
                Button("Redo", action: onRedo)
                    .buttonStyle(.sh(.ghost, size: .l))
                    .disabled(busy)
                    .accessibilityHint("Puts the agent’s edits back")
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(minHeight: SH.Height.touch)
        .shBorder(sh.lineStrong, in: RoundedRectangle(cornerRadius: SH.Radius.l), dash: [4, 3])
        .accessibilityElement(children: .combine)
    }

    /// A file row.
    public static let rowHeight: CGFloat = 42
}

#Preview("Turn changes card") {
    let files = [
        SHTurnChangesCard.File(path: "ledger/outbox.go", directory: "ledger/", name: "outbox.go", isNew: false, added: 21, removed: 8),
        SHTurnChangesCard.File(path: "ledger/refund.go", directory: "ledger/", name: "refund.go", isNew: true, added: 64, removed: 0),
        SHTurnChangesCard.File(path: "ledger/refund_test.go", directory: "ledger/", name: "refund_test.go", isNew: true, added: 96, removed: 0),
    ]
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHTurnChangesCard(title: "Edited 5 files", added: 200, removed: 8, files: files, total: 5, onUndo: {}, onReview: {}, onOpen: { _ in })
            SHTurnChangesCard(title: "Undid the agent’s edits to 5 files", added: 200, removed: 8, files: [], undone: true, onRedo: {})
        }
        .frame(width: 420)
        .padding()
    }
}
