import SwiftUI

// The composer's @ picker (MentionPicker; RefAtDesigns, RefAtElements, RefAtSearch): designs
// first with their pictures, then a design's pages and boards, and a board's elements behind a breadcrumb,
// and a search across every level. It sits over the thread above the card, as the slash menu
// does; the field keeps the keyboard and drives the highlight.

/// The picker's own measures.
public enum SHMentionMetrics {
    public static let rowHeight: CGFloat = 48
    /// A thread's row (ThreadLinkA's `.opt`): a dot, the title and its project, no picture.
    public static let threadRowHeight: CGFloat = 34
    /// "Link a thread"'s label row, in the caption's words rather than a menu's section label.
    public static let captionHeaderHeight: CGFloat = 30
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
    /// The spinner of "Loading designs…", as the model picker's "Loading models…" draws its own.
    public static let statusSpinner: CGFloat = 12
    /// At most this many rows show; a longer list scrolls.
    public static let maxRows = 8
}

/// One row the picker offers: a design, a board ("Whole board" inside one), an element, or a
/// file. Compared by what it draws, so a highlight moving redraws the two rows it moves between.
public struct SHMentionRow: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case design, page, board, element, file
        /// Another thread, to link (ThreadLinkA): its status dot, title and project.
        case thread
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
    public var thumbnail: SHReferenceImage?
    /// Words of the search, underlined where the title holds them (a thread's, bold).
    public var matched: [String]
    /// A thread's status: its row's dot.
    public var state: AgentState?

    public init(id: String, kind: Kind, title: String, crumbs: [String] = [], subtitle: String? = nil, lead: String? = nil,
                host: String? = nil, hostOffline: Bool = false, trailing: Trailing, thumbnail: SHReferenceImage? = nil,
                matched: [String] = [], state: AgentState? = nil) {
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
        self.state = state
    }

    /// The row's height in the list.
    var height: CGFloat { kind == .thread ? SHThreadMetrics.touchable(SHMentionMetrics.threadRowHeight) : SHMentionMetrics.rowHeight }
}

/// A labelled run of rows: "Designs · 4 on this Mac", "Elements · 14", "Designs, boards and
/// elements · 6 matches", "Files".
public struct SHMentionSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var trailing: String?
    public var rows: [SHMentionRow]
    /// The label in the caption's words, sentence case ("Link a thread", ThreadLinkA), the typed mention mono at its right.
    public var caption: Bool

    public init(id: String, title: String, trailing: String? = nil, rows: [SHMentionRow], caption: Bool = false) {
        self.id = id
        self.title = title
        self.trailing = trailing
        self.rows = rows
        self.caption = caption
    }

    var headerHeight: CGFloat { caption ? SHMentionMetrics.captionHeaderHeight : SHMentionMetrics.headerHeight }
}

/// What the picker says with nothing to list.
public enum SHMentionEmpty: Equatable, Sendable {
    /// A search that found nothing: "Nothing matches “pricng”" and what it searched.
    case nothingMatches(query: String, searched: String)
    /// No designs yet: "No designs yet. Start a design and its boards show up here."
    case noDesigns
    /// The designs are being read: "Loading designs…" with a spinner, until the rows (or one of
    /// the lines below) replace it. It chooses nothing.
    case loading
    /// The read failed or took too long: "Couldn't load designs." and Retry. `reason` is what
    /// says why, for the tooltip and VoiceOver.
    case failed(reason: String)
    /// Designs can't be attached here, and why ("Design references go to projects on this Mac."):
    /// a quiet note, choosing nothing.
    case unavailable(String)
}

/// The @ picker (MentionPicker): 6pt inside the popover's surface, section labels, and 48pt rows
/// with a 40×26 picture (a file's glyph), the title in 13 medium or the path to it with the piece
/// semibold, a line under it in 11.5 `textTertiary`, a host's tag, and a chevron (drills in) or ⏎
/// (picks). Inside a design or a board, a breadcrumb with Back heads it. At most eight rows show,
/// fewer when `maxHeight` leaves less room.
public struct SHMentionPicker: View {
    let sections: [SHMentionSection]
    let crumbs: [String]?
    let empty: SHMentionEmpty?
    let highlighted: String?
    let maxHeight: CGFloat?
    let choose: (SHMentionRow) -> Void
    let drill: (SHMentionRow) -> Void
    let back: () -> Void
    let hover: (String) -> Void
    let startDesign: (() -> Void)?
    /// Retry in "Couldn't load designs."; nil draws the line without it.
    let retry: (() -> Void)?
    /// A row came on screen (the list builds only those): its picture can be made now.
    let appear: (String) -> Void
    let disappear: (String) -> Void
    /// The row the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: String?

    public init(sections: [SHMentionSection], crumbs: [String]? = nil, empty: SHMentionEmpty? = nil, highlighted: String?,
                maxHeight: CGFloat? = nil, choose: @escaping (SHMentionRow) -> Void, drill: @escaping (SHMentionRow) -> Void,
                back: @escaping () -> Void = {}, hover: @escaping (String) -> Void = { _ in }, startDesign: (() -> Void)? = nil,
                retry: (() -> Void)? = nil, appear: @escaping (String) -> Void = { _ in },
                disappear: @escaping (String) -> Void = { _ in }) {
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
        self.retry = retry
        self.appear = appear
        self.disappear = disappear
    }

    /// The list's height for `sections`: every header and row, at most `maxRows` rows' worth, and
    /// no more than `room` leaves.
    public static func listHeight(_ sections: [SHMentionSection], room: CGFloat?) -> CGFloat {
        let M = SHMentionMetrics.self
        let rows = sections.flatMap(\.rows)
        let headers = sections.filter { !$0.title.isEmpty }.reduce(0) { $0 + $1.headerHeight }
        let full = headers + rows.reduce(0) { $0 + $1.height }
        let cap = headers + rows.prefix(M.maxRows).reduce(0) { $0 + $1.height }
        var height = min(full, cap)
        if let room, room.isFinite { height = min(height, max(M.rowHeight + M.headerHeight, room)) }
        return height
    }

    public var body: some View {
        let M = SHMentionMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            if let crumbs {
                HStack(spacing: SH.Space.m) {
                    Button(action: back) {
                        Image(systemName: "chevron.left").font(.system(size: M.pickSize, weight: .semibold))
                            .frame(width: M.backSize, height: M.backSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.shIcon(size: M.backSize))
                    .help("Back")
                    .accessibilityLabel("Back")
                    SHReferenceCrumbs(crumbs: crumbs)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, M.rowPaddingHorizontal)
                .frame(height: M.backHeaderHeight)
                .overlay(alignment: .bottom) { SHHairline() }
                .padding(.horizontal, -SH.Space.s)
                .padding(.top, -SH.Space.s)
                .padding(.bottom, SH.Space.xs)
            }
            switch empty {
            case .nothingMatches(let query, let searched):
                VStack(spacing: SH.Space.s) {
                    Image(systemName: "magnifyingglass").font(.system(size: M.emptyTitleSize)).foregroundStyle(Color.sh.textTertiary)
                    Text("Nothing matches “\(query)”").font(.shSans(M.emptyTitleSize, .medium)).foregroundStyle(Color.sh.textPrimary)
                    Text(searched).font(.shSans(M.emptyLineSize)).foregroundStyle(Color.sh.textTertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, M.emptyPadding)
                .padding(.horizontal, SH.Space.xl)
            case .noDesigns:
                SHMenuHeader("Designs", inset: M.rowPaddingHorizontal)
                statusLine {
                    Image(systemName: "pencil.tip").font(.system(size: M.pickSize)).foregroundStyle(Color.sh.textTertiary)
                    noDesignsLine
                }
            case .loading:
                // One quiet line that chooses nothing: ↩ over it leaves the message alone.
                SHMenuHeader("Designs", inset: M.rowPaddingHorizontal)
                statusLine {
                    ProgressView().progressViewStyle(.shSpinner(size: M.statusSpinner, color: Color.sh.textTertiary))
                    Text("Loading designs…").font(.shSans(M.noDesignsSize)).foregroundStyle(Color.sh.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading designs")
            case .failed(let reason):
                SHMenuHeader("Designs", inset: M.rowPaddingHorizontal)
                statusLine {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: M.pickSize)).foregroundStyle(AgentState.failed.color)
                        .accessibilityHidden(true)
                    Text("Couldn’t load designs.").font(.shSans(M.noDesignsSize)).foregroundStyle(Color.sh.textSecondary)
                    Spacer(minLength: 0)
                    if let retry {
                        Button("Retry", action: retry)
                            .buttonStyle(.sh(.ghost, size: .s))
                            .help("Read this Mac’s designs again")
                    }
                }
                .help(reason)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Couldn’t load designs")
                .accessibilityHint(reason)
            case .unavailable(let note):
                statusLine {
                    Image(systemName: "info.circle").font(.system(size: M.pickSize)).foregroundStyle(Color.sh.textTertiary)
                        .accessibilityHidden(true)
                    Text(note).font(.shSans(M.noDesignsSize)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(note)
            case nil:
                EmptyView()
            }
            if !sections.isEmpty { list }
        }
        .modifier(SHMenuSurface(width: nil))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention")
    }

    /// One line under a header, with its glyph (or spinner) first: the stages that list no rows.
    private func statusLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: SHMentionMetrics.rowSpacing) { content() }
            .padding(.horizontal, SHMentionMetrics.rowPaddingHorizontal)
            .padding(.top, SH.Space.m)
            .padding(.bottom, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var noDesignsLine: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xs) {
            Text("No designs yet.").foregroundStyle(sh.textSecondary)
            if let startDesign {
                Button("Start a design", action: startDesign).buttonStyle(.shLink(color: sh.running, font: .shSans(SHMentionMetrics.noDesignsSize)))
            }
            Text(startDesign == nil ? "Its boards show up here." : "and its boards show up here.").foregroundStyle(sh.textSecondary)
        }
        .font(.shSans(SHMentionMetrics.noDesignsSize))
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
                            case .header(let section) where section.caption:
                                SHMentionCaptionHeader(title: section.title, trailing: section.trailing)
                                    .frame(height: section.headerHeight)
                            case .header(let section):
                                SHMenuHeader(section.title, trailing: section.trailing, inset: SHMentionMetrics.rowPaddingHorizontal)
                                    .padding(.top, SH.Space.xs)
                                    .frame(height: SHMentionMetrics.headerHeight)
                            case .row(let row):
                                SHMentionRowView(row: row, highlighted: row.id == highlighted, choose: choose, drill: drill) {
                                    guard row.id != highlighted else { return }
                                    pointed = row.id
                                    hover(row.id)
                                }
                                .equatable()
                                .onAppear { appear(row.id) }
                                .onDisappear { disappear(row.id) }
                            }
                        }
                        .id(entry.id)
                    }
                }
            }
            .frame(height: Self.listHeight(sections, room: maxHeight.map { $0 - 2 * SH.Space.s - (crumbs == nil ? 0 : SHMentionMetrics.backHeaderHeight) }))
            .onChange(of: highlighted) { _, id in
                defer { pointed = nil }
                guard let id, id != pointed else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

/// A place in the picker's list: a section's label, or a row.
enum SHMentionEntry: Identifiable, Equatable {
    case header(SHMentionSection)
    case row(SHMentionRow)

    var id: String {
        switch self {
        case .header(let section): "header:" + section.id
        case .row(let row): row.id
        }
    }
}

extension SHMentionPicker {
    /// The sections as the list lays them out: each labelled section's header, then its rows.
    static func entries(_ sections: [SHMentionSection]) -> [SHMentionEntry] {
        sections.flatMap { section in
            (section.title.isEmpty ? [] : [SHMentionEntry.header(section)]) + section.rows.map(SHMentionEntry.row)
        }
    }
}

/// One row of the picker. Equatable on what it draws, closures aside.
struct SHMentionRowView: View, Equatable {
    let row: SHMentionRow
    let highlighted: Bool
    let choose: (SHMentionRow) -> Void
    let drill: (SHMentionRow) -> Void
    let hover: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.highlighted == b.highlighted }

    var body: some View {
        let _ = SHRenderProbe.tick("mention.row")
        if row.kind == .thread { thread } else { piece }
    }

    /// A thread (ThreadLinkA's `.opt`): its dot, the title with the typed words bold, its project (and Mac) at the right.
    private var thread: some View {
        let sh = Color.sh
        return SHMenuRow(highlighted: highlighted, spacing: SH.Space.m,
                         padding: EdgeInsets(top: 0, leading: SH.Space.l, bottom: 0, trailing: SH.Space.l),
                         height: SHThreadMetrics.touchable(SHMentionMetrics.threadRowHeight), action: { choose(row) }, onHover: hover) {
            SHStatusDot(row.state ?? .idle)
            Text(Self.bolded(row.title, words: row.matched))
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle = row.subtitle {
                Text(subtitle).font(.sh(.caption)).foregroundStyle(sh.textSecondary).lineLimit(1).layoutPriority(1)
            }
        }
        .accessibilityLabel([row.title, row.state?.label.lowercased(), row.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Links this thread in the message")
    }

    private var piece: some View {
        let sh = Color.sh
        let M = SHMentionMetrics.self
        return SHMenuRow(highlighted: highlighted, spacing: M.rowSpacing,
                  padding: EdgeInsets(top: 0, leading: M.rowPaddingHorizontal, bottom: 0, trailing: M.rowPaddingHorizontal),
                  height: M.rowHeight, action: { row.trailing == .drill ? drill(row) : choose(row) }, onHover: hover) {
            if row.kind == .page {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: M.titleSize))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: SHReferenceMetrics.thumbnail.width, height: SHReferenceMetrics.thumbnail.height)
                    .accessibilityHidden(true)
            } else if row.kind == .file {
                Image(systemName: "doc")
                    .font(.system(size: M.pickSize))
                    .foregroundStyle(sh.textTertiary)
                    .frame(width: SHReferenceMetrics.thumbnail.width, height: SHReferenceMetrics.thumbnail.height)
            } else {
                SHReferenceThumbnail(row.thumbnail)
            }
            VStack(alignment: .leading, spacing: 1) {
                title
                if row.subtitle != nil || row.lead != nil {
                    HStack(spacing: SH.Space.xs) {
                        if let lead = row.lead { Text(lead).font(.shMono(M.subtitleSize - 0.5)) }
                        if let subtitle = row.subtitle { Text((row.lead == nil ? "" : "· ") + subtitle) }
                    }
                    .font(.shSans(M.subtitleSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let host = row.host { SHReferenceHostTag(host, offline: row.hostOffline) }
            switch row.trailing {
            case .drill:
                Image(systemName: "chevron.right").font(.system(size: M.pickSize - 2, weight: .semibold)).foregroundStyle(sh.textTertiary)
            case .pick:
                Text("⏎").font(.shMono(M.pickSize)).foregroundStyle(sh.running).accessibilityHidden(true)
            }
        }
        .opacity(row.hostOffline ? 0.5 : 1)
        .accessibilityLabel((row.crumbs + [row.title]).joined(separator: ", ") + (row.subtitle.map { ", \($0)" } ?? ""))
        .accessibilityHint(row.trailing == .drill ? "Shows what is inside" : "Adds it to the message")
    }

    @ViewBuilder private var title: some View {
        let M = SHMentionMetrics.self
        if row.crumbs.isEmpty {
            Text(Self.highlighted(row.title, words: row.matched))
                .font(.shSans(M.titleSize, .medium))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            SHMentionCrumbs(crumbs: row.crumbs, title: Self.highlighted(row.title, words: row.matched))
        }
    }

    /// `title` with each of `words` it holds (ignoring case and accents) semibold: a thread's row.
    static func bolded(_ title: String, words: [String]) -> AttributedString {
        var text = AttributedString(title)
        for range in matchRanges(title, words: words) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = Font.sh(.ui, weight: .semibold)
        }
        return text
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

/// "Link a thread" in the caption's words, and the typed mention (`@post`) mono at its right (ThreadLinkA).
private struct SHMentionCaptionHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Text(title).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.top, SH.Space.s)
        .padding(.bottom, SH.Space.m)
    }
}

/// A search result's path, the piece last and semibold with its matched words underlined.
private struct SHMentionCrumbs: View {
    let crumbs: [String]
    let title: AttributedString

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SHReferenceMetrics.crumbSpacing) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                Text(crumb).foregroundStyle(sh.textSecondary).lineLimit(1).layoutPriority(Double(index))
                Text("›").foregroundStyle(sh.textTertiary)
            }
            Text(title).fontWeight(.semibold).foregroundStyle(sh.textPrimary).lineLimit(1).layoutPriority(Double(crumbs.count + 1))
        }
        .font(.shSans(SHReferenceMetrics.crumbSize))
    }
}
