import SwiftUI

/// The Changes pane's measures (ChangesStates › Toolbar): a 44pt toolbar row, a 32pt compare row,
/// a 48pt send bar (58pt on iPad), and the maximized pane's 260pt file list.
public enum SHChangesMetrics {
    public static let toolbarHeight: CGFloat = 44
    public static let compareHeight: CGFloat = 32
    public static let sendBarHeight: CGFloat = 48
    /// The send bar on iPad (iPadReview, iPadReviewSplit).
    public static let touchSendBarHeight: CGFloat = 58
    public static let fileListWidth: CGFloat = 260
    public static let fileListRowHeight: CGFloat = 46
    public static let scopeButtonRadius: CGFloat = 7
    public static let toolbarIcon: CGFloat = 28
}

/// What the toolbar's scope button names (ScopeMenu): its glyph by scope.
public enum SHChangesScopeGlyph: Sendable {
    case lastTurn, uncommitted, staged, commits, branch, pullRequest, reference

    public var systemImage: String {
        switch self {
        case .lastTurn: "clock.arrow.circlepath"
        case .uncommitted: "pencil"
        case .staged: "tray"
        case .commits: "smallcircle.filled.circle"
        case .branch: SHGlyph.gitBranch.symbolName
        case .pullRequest: "arrow.triangle.pull"
        case .reference: "number"
        }
    }
}

/// The scope button (ChangesToolbar): 28pt, radius 7, a strong line on `bgRaised`, its glyph,
/// the scope in 12.5 semibold, and a chevron. It opens the scope menu (⌘E).
public struct SHScopeButton: View {
    let title: String
    let glyph: SHChangesScopeGlyph
    let isOpen: Bool
    let action: () -> Void

    public init(title: String, glyph: SHChangesScopeGlyph, isOpen: Bool, action: @escaping () -> Void) {
        self.title = title
        self.glyph = glyph
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: glyph.systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textSecondary)
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: SH.Height.controlM)
            .background(isOpen ? sh.bgSelected : sh.bgRaised, in: RoundedRectangle(cornerRadius: SHChangesMetrics.scopeButtonRadius))
            .shBorder(sh.lineStrong, radius: SHChangesMetrics.scopeButtonRadius)
            .contentShape(RoundedRectangle(cornerRadius: SHChangesMetrics.scopeButtonRadius))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("What to compare (⌘E)")
        .accessibilityLabel("Compare: \(title)")
        .accessibilityHint("Chooses what the pane compares")
    }
}

/// "2/5 viewed" (ChangesToolbar): a 24pt pill on `bgSunken`, an eye, the count in mono.
public struct SHViewedPill: View {
    let viewed: Int
    let total: Int

    public init(viewed: Int, total: Int) {
        self.viewed = viewed
        self.total = total
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.s) {
            Image(systemName: "eye").font(.system(size: 10, weight: .medium))
            Text("\(Text("\(viewed)/\(total)").font(.shMono(11.5))) viewed")
                .font(.sh(.caption))
                .contentTransition(.numericText())
        }
        .foregroundStyle(sh.textSecondary)
        .padding(.horizontal, SH.Space.m)
        .frame(height: SH.Height.controlS)
        .background(sh.bgSunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(viewed) of \(total) files viewed")
    }
}

/// The compare row (CompareRow): 32pt on `bgBase`. Head → base in mono 11.5, the base as a picker
/// when the scope has one (Branch), or for a turn "The agent’s last turn" with its times and the
/// message that started it (ChangesLastTurn); then a trailing note in mono 10.5 ("merge base
/// 3f2a91c").
public struct SHCompareRow: View {
    public enum Lead: Equatable, Sendable {
        case compare(head: String, base: String)
        /// "The agent’s last turn", "3:07–3:11 PM · after “Wrap errors with context”".
        case turn(title: String, detail: String)
    }

    let lead: Lead
    let note: String?
    let pickBase: (() -> Void)?
    let pickerOpen: Bool

    public init(_ lead: Lead, note: String?, pickerOpen: Bool = false, pickBase: (() -> Void)? = nil) {
        self.lead = lead
        self.note = note
        self.pickerOpen = pickerOpen
        self.pickBase = pickBase
    }

    public init(head: String, base: String, note: String?, pickerOpen: Bool = false, pickBase: (() -> Void)?) {
        self.init(.compare(head: head, base: base), note: note, pickerOpen: pickerOpen, pickBase: pickBase)
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            switch lead {
            case .compare(let head, let base):
                Text(head).font(.sh(.mono)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(sh.textTertiary)
                    .accessibilityLabel("against")
                if let pickBase {
                    Button(action: pickBase) {
                        HStack(spacing: 5) {
                            Text(base).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(sh.textTertiary)
                        }
                        .padding(.horizontal, SH.Space.s)
                        .frame(height: 22)
                        .background(pickerOpen ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.shRow(radius: 5))
                    .fixedSize()
                    .help("Compare against another branch")
                    .accessibilityLabel("Base: \(base)")
                    .accessibilityHint("Chooses what to compare against")
                } else {
                    Text(base).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                }
            case .turn(let title, let detail):
                Image(systemName: SHChangesScopeGlyph.lastTurn.systemImage).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(sh.textSecondary)
                Text(title).font(.shSans(12)).foregroundStyle(sh.textSecondary).lineLimit(1).fixedSize()
                Text(detail).font(.shMono(11)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: SH.Space.m)
            if let note {
                Text(note).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: SHChangesMetrics.compareHeight)
        .background(sh.bgBase)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

// MARK: File list

/// The maximized pane's file list (ChangesWide): "5 FILES" with the scope's diff stat over a row
/// per file: its status letter, the filename in semibold mono over its directory, and its stat
/// over its comment count or a viewed check. The current file has the selected fill.
public struct SHChangesFileList: View {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let path: String
        public let status: SHFileStatus
        public let added: Int
        public let removed: Int
        public let comments: Int
        public let isViewed: Bool

        public init(id: String, path: String, status: SHFileStatus, added: Int, removed: Int, comments: Int = 0, isViewed: Bool = false) {
            self.id = id
            self.path = path
            self.status = status
            self.added = added
            self.removed = removed
            self.comments = comments
            self.isViewed = isViewed
        }
    }

    let items: [Item]
    let added: Int
    let removed: Int
    let selection: Item.ID?
    let onSelect: (Item.ID) -> Void

    public init(_ items: [Item], added: Int, removed: Int, selection: Item.ID?, onSelect: @escaping (Item.ID) -> Void) {
        self.items = items
        self.added = added
        self.removed = removed
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            HStack {
                Text("\(items.count) file\(items.count == 1 ? "" : "s")")
                    .font(.shMono(10.5, .medium))
                    .textCase(.uppercase)
                    .tracking(0.63)
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                SHDiffStat(added: added, removed: removed, font: .shMono(10.5))
            }
            .padding(.horizontal, SH.Space.l)
            .frame(height: SHChangesMetrics.compareHeight)
            ScrollView {
                LazyVStack(spacing: SH.Space.xxs) {
                    ForEach(items) { item in
                        SHChangesFileRow(item: item, selected: item.id == selection) { onSelect(item.id) }
                            .equatable()
                    }
                }
                .padding(.horizontal, SH.Space.s)
                .padding(.bottom, SH.Space.s)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: SHChangesMetrics.fileListWidth)
        .background(sh.bgWindow)
        .overlay(alignment: .trailing) { SHHairline(.vertical) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

private struct SHChangesFileRow: View, Equatable {
    let item: SHChangesFileList.Item
    let selected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let _ = SHRenderProbe.tick("review.fileRow")
        let sh = Color.sh
        let (directory, name) = SHFileHeader.split(item.path)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(item.status.letter).font(.shMono(10.5, .bold)).foregroundStyle(item.status.color)
                    .frame(height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.sh(.code, weight: .semibold)).foregroundStyle(item.isViewed ? sh.textSecondary : sh.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(directory.isEmpty ? "/" : directory).font(.shMono(10.5)).foregroundStyle(sh.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    SHDiffStat(added: item.added, removed: item.removed, font: .shMono(10.5))
                    if item.comments > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "text.bubble").font(.system(size: 8, weight: .medium))
                            Text("\(item.comments)").font(.shMono(10.5))
                        }
                        .foregroundStyle(sh.running)
                    } else if item.isViewed {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(sh.done)
                    }
                }
            }
            .padding(.horizontal, SH.Space.s)
            .padding(.vertical, SH.Space.m)
            .frame(minHeight: SHChangesMetrics.fileListRowHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected))
        .help(item.path)
        .accessibilityLabel("\(name), \(item.status.label), \(item.added) added, \(item.removed) removed"
                            + (item.comments > 0 ? ", \(item.comments) comments" : "") + (item.isViewed ? ", viewed" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
