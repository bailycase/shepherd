import SwiftUI

// The composer's @ picker (MentionPicker; RefAtDesigns, RefAtElements, RefAtSearch): designs
// first with their pictures, then a design's boards and a board's elements behind a breadcrumb,
// and a search across every level. It sits over the thread above the card, as the slash menu
// does; the field keeps the keyboard and drives the highlight.

/// The picker's own measures.
public enum NWMentionMetrics {
    public static let rowHeight: CGFloat = 48
    public static let rowPaddingHorizontal: CGFloat = 10
    public static let rowSpacing: CGFloat = 10
    public static let rowRadius: CGFloat = 7
    public static let titleSize: CGFloat = 13
    public static let subtitleSize: CGFloat = 11.5
    public static let pickSize: CGFloat = 11
    public static let headerHeight: CGFloat = 24
    public static let backHeaderHeight: CGFloat = 34
    public static let backSize: CGFloat = 22
    public static let emptyPadding: CGFloat = 22
    public static let emptyTitleSize: CGFloat = 13
    public static let emptyLineSize: CGFloat = 12
    public static let noDesignsSize: CGFloat = 12.5
    /// At most this many rows show; a longer list scrolls.
    public static let maxRows = 8
}

/// One row the picker offers: a design, a board ("Whole board" inside one), an element, or a
/// file. Compared by what it draws, so a highlight moving redraws the two rows it moves between.
public struct NWMentionRow: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case design, board, element, file
    }

    public enum Trailing: Sendable {
        /// → drills in (a design's boards, a board's elements): a chevron.
        case drill
        /// ⏎ picks it: the return glyph.
        case pick
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The titles above it, before the title (a search's results): "Checkout funnel dashboard ›".
    public var crumbs: [String]
    public var subtitle: String?
    /// A mono word before the subtitle: a design's system ("acme-web").
    public var lead: String?
    /// The host it is on, as a tag; amber and the row dimmed while the host is offline.
    public var host: String?
    public var hostOffline: Bool
    public var trailing: Trailing
    public var thumbnail: NWReferenceImage?
    /// Words of the search, underlined where the title holds them.
    public var matched: [String]

    public init(id: String, kind: Kind, title: String, crumbs: [String] = [], subtitle: String? = nil, lead: String? = nil,
                host: String? = nil, hostOffline: Bool = false, trailing: Trailing, thumbnail: NWReferenceImage? = nil,
                matched: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.crumbs = crumbs
        self.subtitle = subtitle
        self.lead = lead
        self.host = host
        self.hostOffline = hostOffline
        self.trailing = trailing
        self.thumbnail = thumbnail
        self.matched = matched
    }
}

/// A labelled run of rows: "Designs · 4 on this Mac", "Elements · 14", "Designs, boards and
/// elements · 6 matches", "Files".
public struct NWMentionSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var trailing: String?
    public var rows: [NWMentionRow]

    public init(id: String, title: String, trailing: String? = nil, rows: [NWMentionRow]) {
        self.id = id
        self.title = title
        self.trailing = trailing
        self.rows = rows
    }
}

/// What the picker says with nothing to list.
public enum NWMentionEmpty: Equatable, Sendable {
    /// A search that found nothing: "Nothing matches “pricng”" and what it searched.
    case nothingMatches(query: String, searched: String)
    /// No designs yet: "No designs yet. Start a design and its boards show up here."
    case noDesigns
}

/// The @ picker (MentionPicker): 6pt inside the popover's surface, section labels, and 48pt rows
/// with a 40×26 picture (a file's glyph), the title in 13 medium or the path to it with the piece
/// semibold, a line under it in 11.5 `textTertiary`, a host's tag, and a chevron (drills in) or ⏎
/// (picks). Inside a design or a board, a breadcrumb with Back heads it. At most eight rows show,
/// fewer when `maxHeight` leaves less room.
public struct NWMentionPicker: View {
    let sections: [NWMentionSection]
    let crumbs: [String]?
    let empty: NWMentionEmpty?
    let highlighted: String?
    let maxHeight: CGFloat?
    let choose: (NWMentionRow) -> Void
    let drill: (NWMentionRow) -> Void
    let back: () -> Void
    let hover: (String) -> Void
    let startDesign: (() -> Void)?
    /// The row the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: String?

    public init(sections: [NWMentionSection], crumbs: [String]? = nil, empty: NWMentionEmpty? = nil, highlighted: String?,
                maxHeight: CGFloat? = nil, choose: @escaping (NWMentionRow) -> Void, drill: @escaping (NWMentionRow) -> Void,
                back: @escaping () -> Void = {}, hover: @escaping (String) -> Void = { _ in }, startDesign: (() -> Void)? = nil) {
        self.sections = sections
        self.crumbs = crumbs
        self.empty = empty
        self.highlighted = highlighted
        self.maxHeight = maxHeight
        self.choose = choose
        self.drill = drill
        self.back = back
        self.hover = hover
        self.startDesign = startDesign
    }

    /// The list's height for `sections`: every header and row, at most `maxRows` rows' worth, and
    /// no more than `room` leaves.
    public static func listHeight(_ sections: [NWMentionSection], room: CGFloat?) -> CGFloat {
        let M = NWMentionMetrics.self
        let rows = sections.reduce(0) { $0 + $1.rows.count }
        let headers = CGFloat(sections.filter { !$0.title.isEmpty }.count) * M.headerHeight
        let full = headers + CGFloat(rows) * M.rowHeight
        let cap = headers + CGFloat(M.maxRows) * M.rowHeight
        var height = min(full, cap)
        if let room, room.isFinite { height = min(height, max(M.rowHeight + M.headerHeight, room)) }
        return height
    }

    public var body: some View {
        let M = NWMentionMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            if let crumbs {
                HStack(spacing: NW.Space.m) {
                    Button(action: back) {
                        Image(systemName: "chevron.left").font(.system(size: M.pickSize, weight: .semibold))
                            .frame(width: M.backSize, height: M.backSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.nwIcon(size: M.backSize))
                    .help("Back")
                    .accessibilityLabel("Back")
                    NWReferenceCrumbs(crumbs: crumbs)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, M.rowPaddingHorizontal)
                .frame(height: M.backHeaderHeight)
                .overlay(alignment: .bottom) { NWHairline() }
                .padding(.horizontal, -NW.Space.s)
                .padding(.top, -NW.Space.s)
                .padding(.bottom, NW.Space.xs)
            }
            switch empty {
            case .nothingMatches(let query, let searched):
                VStack(spacing: NW.Space.s) {
                    Image(systemName: "magnifyingglass").font(.system(size: M.emptyTitleSize)).foregroundStyle(Color.nw.textTertiary)
                    Text("Nothing matches “\(query)”").font(.nwSans(M.emptyTitleSize, .medium)).foregroundStyle(Color.nw.textPrimary)
                    Text(searched).font(.nwSans(M.emptyLineSize)).foregroundStyle(Color.nw.textTertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, M.emptyPadding)
                .padding(.horizontal, NW.Space.xl)
            case .noDesigns:
                NWMenuHeader("Designs", inset: M.rowPaddingHorizontal)
                HStack(spacing: M.rowSpacing) {
                    Image(systemName: "pencil.tip").font(.system(size: M.pickSize)).foregroundStyle(Color.nw.textTertiary)
                    noDesignsLine
                }
                .padding(.horizontal, M.rowPaddingHorizontal)
                .padding(.top, NW.Space.m)
                .padding(.bottom, NW.Space.l)
            case nil:
                EmptyView()
            }
            if !sections.isEmpty { list }
        }
        .modifier(NWMenuSurface(width: nil))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention")
    }

    @ViewBuilder private var noDesignsLine: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.xs) {
            Text("No designs yet.").foregroundStyle(nw.textSecondary)
            if let startDesign {
                Button("Start a design", action: startDesign).buttonStyle(.nwLink(color: nw.running, font: .nwSans(NWMentionMetrics.noDesignsSize)))
            }
            Text(startDesign == nil ? "Its boards show up here." : "and its boards show up here.").foregroundStyle(nw.textSecondary)
        }
        .font(.nwSans(NWMentionMetrics.noDesignsSize))
        .lineLimit(1)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One view per header and per row, so a board of hundreds of elements builds
                    // only the rows on screen.
                    ForEach(Self.entries(sections)) { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            switch entry {
                            case .header(let section):
                                NWMenuHeader(section.title, trailing: section.trailing, inset: NWMentionMetrics.rowPaddingHorizontal)
                                    .padding(.top, NW.Space.xs)
                                    .frame(height: NWMentionMetrics.headerHeight)
                            case .row(let row):
                                NWMentionRowView(row: row, highlighted: row.id == highlighted, choose: choose, drill: drill) {
                                    guard row.id != highlighted else { return }
                                    pointed = row.id
                                    hover(row.id)
                                }
                                .equatable()
                            }
                        }
                        .id(entry.id)
                    }
                }
            }
            .frame(height: Self.listHeight(sections, room: maxHeight.map { $0 - 2 * NW.Space.s - (crumbs == nil ? 0 : NWMentionMetrics.backHeaderHeight) }))
            .onChange(of: highlighted) { _, id in
                defer { pointed = nil }
                guard let id, id != pointed else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

/// A place in the picker's list: a section's label, or a row.
enum NWMentionEntry: Identifiable, Equatable {
    case header(NWMentionSection)
    case row(NWMentionRow)

    var id: String {
        switch self {
        case .header(let section): "header:" + section.id
        case .row(let row): row.id
        }
    }
}

extension NWMentionPicker {
    /// The sections as the list lays them out: each labelled section's header, then its rows.
    static func entries(_ sections: [NWMentionSection]) -> [NWMentionEntry] {
        sections.flatMap { section in
            (section.title.isEmpty ? [] : [NWMentionEntry.header(section)]) + section.rows.map(NWMentionEntry.row)
        }
    }
}

/// One row of the picker. Equatable on what it draws, closures aside.
struct NWMentionRowView: View, Equatable {
    let row: NWMentionRow
    let highlighted: Bool
    let choose: (NWMentionRow) -> Void
    let drill: (NWMentionRow) -> Void
    let hover: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.highlighted == b.highlighted }

    var body: some View {
        let _ = NWRenderProbe.tick("mention.row")
        let nw = Color.nw
        let M = NWMentionMetrics.self
        NWMenuRow(highlighted: highlighted, spacing: M.rowSpacing,
                  padding: EdgeInsets(top: 0, leading: M.rowPaddingHorizontal, bottom: 0, trailing: M.rowPaddingHorizontal),
                  height: M.rowHeight, action: { row.trailing == .drill ? drill(row) : choose(row) }, onHover: hover) {
            if row.kind == .file {
                Image(systemName: "doc")
                    .font(.system(size: M.pickSize))
                    .foregroundStyle(nw.textTertiary)
                    .frame(width: NWReferenceMetrics.thumbnail.width, height: NWReferenceMetrics.thumbnail.height)
            } else {
                NWReferenceThumbnail(row.thumbnail)
            }
            VStack(alignment: .leading, spacing: 1) {
                title
                if row.subtitle != nil || row.lead != nil {
                    HStack(spacing: NW.Space.xs) {
                        if let lead = row.lead { Text(lead).font(.nwMono(M.subtitleSize - 0.5)) }
                        if let subtitle = row.subtitle { Text((row.lead == nil ? "" : "· ") + subtitle) }
                    }
                    .font(.nwSans(M.subtitleSize))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let host = row.host { NWReferenceHostTag(host, offline: row.hostOffline) }
            switch row.trailing {
            case .drill:
                Image(systemName: "chevron.right").font(.system(size: M.pickSize - 2, weight: .semibold)).foregroundStyle(nw.textTertiary)
            case .pick:
                Text("⏎").font(.nwMono(M.pickSize)).foregroundStyle(nw.running).accessibilityHidden(true)
            }
        }
        .opacity(row.hostOffline ? 0.5 : 1)
        .accessibilityLabel((row.crumbs + [row.title]).joined(separator: ", ") + (row.subtitle.map { ", \($0)" } ?? ""))
        .accessibilityHint(row.trailing == .drill ? "Shows what is inside" : "Adds it to the message")
    }

    @ViewBuilder private var title: some View {
        let M = NWMentionMetrics.self
        if row.crumbs.isEmpty {
            Text(Self.highlighted(row.title, words: row.matched))
                .font(.nwSans(M.titleSize, .medium))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            NWMentionCrumbs(crumbs: row.crumbs, title: Self.highlighted(row.title, words: row.matched))
        }
    }

    /// `title` with each of `words` it holds (ignoring case and accents) bold and underlined.
    static func highlighted(_ title: String, words: [String]) -> AttributedString {
        var text = AttributedString(title)
        for range in matchRanges(title, words: words) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].underlineStyle = .single
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }

    /// Where each of `words` first appears in `title`, ignoring case and accents.
    static func matchRanges(_ title: String, words: [String]) -> [Range<String.Index>] {
        words.compactMap { word in
            guard !word.isEmpty else { return nil }
            return title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        }
    }
}

/// A search result's path, the piece last and semibold with its matched words underlined.
private struct NWMentionCrumbs: View {
    let crumbs: [String]
    let title: AttributedString

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NWReferenceMetrics.crumbSpacing) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                Text(crumb).foregroundStyle(nw.textSecondary).lineLimit(1).layoutPriority(Double(index))
                Text("›").foregroundStyle(nw.textTertiary)
            }
            Text(title).fontWeight(.semibold).foregroundStyle(nw.textPrimary).lineLimit(1).layoutPriority(Double(crumbs.count + 1))
        }
        .font(.nwSans(NWReferenceMetrics.crumbSize))
    }
}
