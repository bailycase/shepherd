import SwiftUI

/// The Changes pane's measures (ChangesStates › Toolbar): a 44pt toolbar row, a 32pt compare row,
/// a 48pt send bar, and the maximized pane's 260pt file list.
public enum NWChangesMetrics {
    public static let toolbarHeight: CGFloat = 44
    public static let compareHeight: CGFloat = 32
    public static let sendBarHeight: CGFloat = 48
    public static let fileListWidth: CGFloat = 260
    public static let fileListRowHeight: CGFloat = 46
    public static let scopeButtonRadius: CGFloat = 7
    public static let toolbarIcon: CGFloat = 28
}

/// What the toolbar's scope button names (ScopeMenu): its glyph by scope.
public enum NWChangesScopeGlyph: Sendable {
    case lastTurn, uncommitted, staged, commits, branch, pullRequest, reference

    public var systemImage: String {
        switch self {
        case .lastTurn: "clock.arrow.circlepath"
        case .uncommitted: "pencil"
        case .staged: "tray"
        case .commits: "smallcircle.filled.circle"
        case .branch: "arrow.triangle.branch"
        case .pullRequest: "arrow.triangle.pull"
        case .reference: "number"
        }
    }
}

/// The scope button (ChangesToolbar): 28pt, radius 7, a strong line on `bgRaised`, its glyph,
/// the scope in 12.5 semibold, and a chevron. It opens the scope menu (⌘E).
public struct NWScopeButton: View {
    let title: String
    let glyph: NWChangesScopeGlyph
    let isOpen: Bool
    let action: () -> Void

    public init(title: String, glyph: NWChangesScopeGlyph, isOpen: Bool, action: @escaping () -> Void) {
        self.title = title
        self.glyph = glyph
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: glyph.systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textSecondary)
                Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(nw.textTertiary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: NW.Height.controlM)
            .background(isOpen ? nw.bgSelected : nw.bgRaised, in: RoundedRectangle(cornerRadius: NWChangesMetrics.scopeButtonRadius))
            .nwBorder(nw.lineStrong, radius: NWChangesMetrics.scopeButtonRadius)
            .contentShape(RoundedRectangle(cornerRadius: NWChangesMetrics.scopeButtonRadius))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("What to compare (⌘E)")
        .accessibilityLabel("Compare: \(title)")
        .accessibilityHint("Chooses what the pane compares")
    }
}

/// "2/5 viewed" (ChangesToolbar): a 24pt pill on `bgSunken`, an eye, the count in mono.
public struct NWViewedPill: View {
    let viewed: Int
    let total: Int

    public init(viewed: Int, total: Int) {
        self.viewed = viewed
        self.total = total
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Image(systemName: "eye").font(.system(size: 10, weight: .medium))
            Text("\(Text("\(viewed)/\(total)").font(.nwMono(11.5))) viewed")
                .font(.nw(.caption))
                .contentTransition(.numericText())
        }
        .foregroundStyle(nw.textSecondary)
        .padding(.horizontal, NW.Space.m)
        .frame(height: NW.Height.controlS)
        .background(nw.bgSunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(viewed) of \(total) files viewed")
    }
}

/// The compare row (CompareRow): 32pt on `bgBase`. Head → base in mono 11.5, the base as a picker
/// when the scope has one (Branch), or for a turn "The agent’s last turn" with its times and the
/// message that started it (ChangesLastTurn); then a trailing note in mono 10.5 ("merge base
/// 3f2a91c").
public struct NWCompareRow: View {
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
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            switch lead {
            case .compare(let head, let base):
                Text(head).font(.nw(.mono)).foregroundStyle(nw.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(nw.textTertiary)
                    .accessibilityLabel("against")
                if let pickBase {
                    Button(action: pickBase) {
                        HStack(spacing: 5) {
                            Text(base).font(.nw(.mono)).foregroundStyle(nw.textPrimary).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(nw.textTertiary)
                        }
                        .padding(.horizontal, NW.Space.s)
                        .frame(height: 22)
                        .background(pickerOpen ? nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.nwRow(radius: 5))
                    .fixedSize()
                    .help("Compare against another branch")
                    .accessibilityLabel("Base: \(base)")
                    .accessibilityHint("Chooses what to compare against")
                } else {
                    Text(base).font(.nw(.mono)).foregroundStyle(nw.textPrimary).lineLimit(1).truncationMode(.middle)
                }
            case .turn(let title, let detail):
                Image(systemName: NWChangesScopeGlyph.lastTurn.systemImage).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                Text(title).font(.nwSans(12)).foregroundStyle(nw.textSecondary).lineLimit(1).fixedSize()
                Text(detail).font(.nwMono(11)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: NW.Space.m)
            if let note {
                Text(note).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, NW.Space.l)
        .frame(height: NWChangesMetrics.compareHeight)
        .background(nw.bgBase)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// Unsent comments (ReviewSendBar): a 48pt `bgRaised` bar under a strong line, "1 comment on
/// outbox.go, not sent yet", then Discard and Send to agent. Only there while there are unsent
/// comments.
public struct NWReviewSendBar: View {
    let count: String
    let detail: String
    let sending: Bool
    let onDiscard: () -> Void
    let onSend: () -> Void

    public init(count: String, detail: String, sending: Bool = false, onDiscard: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.count = count
        self.detail = detail
        self.sending = sending
        self.onDiscard = onDiscard
        self.onSend = onSend
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 12, weight: .medium)).foregroundStyle(nw.running)
            Text("\(Text(count).fontWeight(.semibold)) \(detail)")
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.m)
            Button("Discard", action: onDiscard)
                .buttonStyle(.nw(.ghost, size: .s))
                .disabled(sending)
            Button(action: onSend) {
                HStack(spacing: NW.Space.s) {
                    if sending { ProgressView().progressViewStyle(.nwSpinner(size: 10)) }
                    Text("Send to agent")
                }
            }
            .buttonStyle(.nw(.primary, size: .s))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(sending)
            .help("Send your comments as the agent's next message (⌘↩)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: NWChangesMetrics.sendBarHeight)
        .background(nw.bgRaised)
        .overlay(alignment: .top) { NWHairline(color: nw.lineStrong) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: File list

/// The maximized pane's file list (ChangesWide): "5 FILES" with the scope's diff stat over a row
/// per file: its status letter, the filename in semibold mono over its directory, and its stat
/// over its comment count or a viewed check. The current file has the selected fill.
public struct NWChangesFileList: View {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let path: String
        public let status: NWFileStatus
        public let added: Int
        public let removed: Int
        public let comments: Int
        public let isViewed: Bool

        public init(id: String, path: String, status: NWFileStatus, added: Int, removed: Int, comments: Int = 0, isViewed: Bool = false) {
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
        let nw = Color.nw
        VStack(spacing: 0) {
            HStack {
                Text("\(items.count) file\(items.count == 1 ? "" : "s")")
                    .font(.nwMono(10.5, .medium))
                    .textCase(.uppercase)
                    .tracking(0.63)
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NW.Space.m)
                NWDiffStat(added: added, removed: removed, font: .nwMono(10.5))
            }
            .padding(.horizontal, NW.Space.l)
            .frame(height: NWChangesMetrics.compareHeight)
            ScrollView {
                LazyVStack(spacing: NW.Space.xxs) {
                    ForEach(items) { item in
                        NWChangesFileRow(item: item, selected: item.id == selection) { onSelect(item.id) }
                            .equatable()
                    }
                }
                .padding(.horizontal, NW.Space.s)
                .padding(.bottom, NW.Space.s)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: NWChangesMetrics.fileListWidth)
        .background(nw.bgWindow)
        .overlay(alignment: .trailing) { NWHairline(.vertical) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

private struct NWChangesFileRow: View, Equatable {
    let item: NWChangesFileList.Item
    let selected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let _ = NWRenderProbe.tick("review.fileRow")
        let nw = Color.nw
        let (directory, name) = NWFileHeader.split(item.path)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(item.status.letter).font(.nwMono(10.5, .bold)).foregroundStyle(item.status.color)
                    .frame(height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.nw(.code, weight: .semibold)).foregroundStyle(item.isViewed ? nw.textSecondary : nw.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(directory.isEmpty ? "/" : directory).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    NWDiffStat(added: item.added, removed: item.removed, font: .nwMono(10.5))
                    if item.comments > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "text.bubble").font(.system(size: 8, weight: .medium))
                            Text("\(item.comments)").font(.nwMono(10.5))
                        }
                        .foregroundStyle(nw.running)
                    } else if item.isViewed {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(nw.done)
                    }
                }
            }
            .padding(.horizontal, NW.Space.s)
            .padding(.vertical, NW.Space.m)
            .frame(minHeight: NWChangesMetrics.fileListRowHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(selected: selected))
        .help(item.path)
        .accessibilityLabel("\(name), \(item.status.label), \(item.added) added, \(item.removed) removed"
                            + (item.comments > 0 ? ", \(item.comments) comments" : "") + (item.isViewed ? ", viewed" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
