import SwiftUI

/// The "Edited N files" card that ends a turn on touch (ChangesStates › ChangesCard;
/// MobileThread, iPadReview): a 36pt icon tile, the title over its stat, Undo and Review, then
/// the first files as plain paths (the folder dimmed, "new" before a created file's stat) and "N
/// more". Once undone it is one dashed line, "Undid the agent’s edits to 5 files", with Redo.
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
    let more: String?
    let undone: Bool
    /// Undo or Redo is on its way to the host.
    let busy: Bool
    let onUndo: (() -> Void)?
    let onRedo: (() -> Void)?
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, added: Int, removed: Int, files: [File], more: String? = nil, undone: Bool = false, busy: Bool = false,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil, onReview: (() -> Void)? = nil, onOpen: ((String) -> Void)? = nil) {
        self.title = title
        self.added = added
        self.removed = removed
        self.files = files
        self.more = more
        self.undone = undone
        self.busy = busy
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onReview = onReview
        self.onOpen = onOpen
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.added == rhs.added && lhs.removed == rhs.removed && lhs.files == rhs.files && lhs.more == rhs.more
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
        return VStack(spacing: 0) {
            head
            ForEach(files) { file in
                SHHairline()
                row(file)
            }
            if let more {
                SHHairline()
                moreRow(more)
            }
        }
        .frame(maxWidth: .infinity)
        .background(sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
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
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHTurnChangesCard.tile, height: SHTurnChangesCard.tile)
                .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                SHDiffStat(added: added, removed: removed, font: .sh(.mono))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var actions: some View {
        HStack(spacing: SH.Space.xs) {
            if let onUndo {
                Button(action: onUndo) {
                    HStack(spacing: SH.Space.xs + 1) {
                        Text("Undo")
                        Image(systemName: "arrow.uturn.backward").imageScale(.small)
                    }
                }
                .buttonStyle(.sh(.ghost, size: .l))
                .disabled(busy)
                .accessibilityLabel("Undo the agent\u{2019}s edits")
                .accessibilityHint("Puts back the files this turn changed, in the working tree")
            }
            if let onReview {
                Button("Review", action: onReview)
                    .buttonStyle(.sh(.secondary, size: .m))
                    .shTouchTarget(height: SH.Height.controlM)
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
                SHDiffStat(added: file.added, removed: file.removed, font: .sh(.mono))
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

    @ViewBuilder private func moreRow(_ more: String) -> some View {
        let content = Text(more)
            .font(.shSans(14))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: SHTurnChangesCard.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        if let onReview {
            Button(action: onReview) { content }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityHint("Opens every file in review")
        } else {
            content
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

    /// The icon tile.
    public static let tile: CGFloat = 36
    /// A file row.
    public static let rowHeight: CGFloat = 40
}

#Preview("Turn changes card") {
    let files = [
        SHTurnChangesCard.File(path: "ledger/outbox.go", directory: "ledger/", name: "outbox.go", isNew: false, added: 21, removed: 8),
        SHTurnChangesCard.File(path: "ledger/refund.go", directory: "ledger/", name: "refund.go", isNew: true, added: 64, removed: 0),
        SHTurnChangesCard.File(path: "ledger/refund_test.go", directory: "ledger/", name: "refund_test.go", isNew: true, added: 96, removed: 0),
    ]
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHTurnChangesCard(title: "Edited 5 files", added: 200, removed: 8, files: files, more: "2 more", onUndo: {}, onReview: {}, onOpen: { _ in })
            SHTurnChangesCard(title: "Undid the agent’s edits to 5 files", added: 200, removed: 8, files: [], undone: true, onRedo: {})
        }
        .frame(width: 420)
        .padding()
    }
}
