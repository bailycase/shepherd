import SwiftUI

/// How a design card draws its first board.
public enum NWDesignCardBoard: Equatable, Sendable {
    case desktop, phone
    /// No board drawn yet: the thumbnail is the dots alone.
    case none

    /// A phone board is taller than it is wide.
    public init(size: CGSize?) {
        guard let size, size.width > 0, size.height > 0 else { self = .none; return }
        self = size.height > size.width ? .phone : .desktop
    }
}

/// A design on the Designs page (NWDesignCard; NavDesigns): a radius-10 card with a hairline and
/// the hover fill. Its top is a 172pt thumbnail on `bgBase` with the canvas's dots every 16pt
/// and a hairline under it, the design's first board centered in it in its board frame (256×160
/// for a desktop board, 74×160 for a phone). Under it, 5pt apart: the name in 13.5 semibold; the
/// system in mono `textSecondary` then "· 4 boards" in 11.5 `textTertiary`; "edited 2h ago" in 11
/// `textTertiary`. The selected card wears a 2pt `textPrimary` ring. With a menu
/// (DesignCardMenu), a right-click anywhere on the card opens it, and ••• shows over the
/// thumbnail's top-trailing corner on hover.
public struct NWDesignCard<Thumbnail: View, MenuItems: View>: View {
    public typealias Board = NWDesignCardBoard

    let name: String
    let system: String?
    let detail: String
    let edited: String
    let board: Board
    let selected: Bool
    let action: () -> Void
    let thumbnail: Thumbnail
    let menu: MenuItems?
    @State private var hovering = false

    public init(name: String, system: String?, detail: String, edited: String, board: Board, selected: Bool = false,
                action: @escaping () -> Void, @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder menu: () -> MenuItems) {
        self.name = name
        self.system = system
        self.detail = detail
        self.edited = edited
        self.board = board
        self.selected = selected
        self.action = action
        self.thumbnail = thumbnail()
        self.menu = menu()
    }

    public var body: some View {
        // Hover is the whole card's, the ••• over it included, so reaching for ••• keeps it.
        Group {
            if let menu {
                card
                    .overlay(alignment: .topTrailing) {
                        if hovering {
                            NWDesignMoreButton(label: "More for \(name)") { menu }
                                .padding(NWDesignMetrics.cardMoreInset)
                                .nwTransition(.content)
                        }
                    }
                    .contextMenu { menu }
            } else {
                card
            }
        }
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }

    private var card: some View {
        let _ = NWRenderProbe.tick("design.card")
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.cardRadius)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    NWDotGrid(spacing: NWDesignMetrics.cardGridSpacing)
                    if let size = boardSize {
                        NWBoardSurface(size: size, selected: false) { thumbnail }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: NWDesignMetrics.cardThumbnailHeight)
                .background(Color.nw.bgBase)
                .clipped()
                .overlay(alignment: .bottom) { NWHairline() }
                VStack(alignment: .leading, spacing: NWDesignMetrics.cardLineSpacing) {
                    Text(name)
                        .font(.nwSans(NWDesignMetrics.cardNameSize, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    meta
                    Text(edited)
                        .font(.nwSans(NWDesignMetrics.cardEditedSize))
                        .foregroundStyle(Color.nw.textTertiary)
                        .lineLimit(1)
                }
                .padding(.vertical, NWDesignMetrics.cardPaddingVertical)
                .padding(.horizontal, NWDesignMetrics.cardPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(hovering ? Color.nw.bgHover : .clear, in: shape)
            .clipShape(shape)
            .nwBorder(Color.nw.lineSubtle, radius: NWDesignMetrics.cardRadius)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.nw.textPrimary, lineWidth: NWDesignMetrics.cardRingWidth)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, system, detail, edited].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var boardSize: CGSize? {
        switch board {
        case .desktop: NWDesignMetrics.cardDesktopBoard
        case .phone: NWDesignMetrics.cardPhoneBoard
        case .none: nil
        }
    }

    private var meta: some View {
        let detailText = Text(system == nil ? detail : " · \(detail)")
            .font(.nwSans(NWDesignMetrics.cardMetaSize))
            .foregroundStyle(Color.nw.textTertiary)
        let line: Text = if let system {
            Text("\(Text(system).font(.nwMono(NWDesignMetrics.cardMetaSize)).foregroundStyle(Color.nw.textSecondary))\(detailText)")
        } else {
            detailText
        }
        return line.lineLimit(1).truncationMode(.tail)
    }
}

extension NWDesignCard where MenuItems == EmptyView {
    /// A card without a menu (a host's design, the iPad's grid).
    public init(name: String, system: String?, detail: String, edited: String, board: Board, selected: Bool = false,
                action: @escaping () -> Void, @ViewBuilder thumbnail: () -> Thumbnail) {
        self.name = name
        self.system = system
        self.detail = detail
        self.edited = edited
        self.board = board
        self.selected = selected
        self.action = action
        self.thumbnail = thumbnail()
        self.menu = nil
    }
}

/// A design system on the Designs page (NavDesigns): a radius-10 card with a hairline and the
/// hover fill, 12×14 padding, 12pt between its parts: up to four of the system's colors as 14pt
/// swatches, its name in mono 12.5 semibold (a built-in's "Built-in" tag after it) over its source
/// in 11.5 `textTertiary`, and how many designs use it trailing in 11 `textTertiary` ("3
/// designs"). With a menu (SystemCardMenu), a right-click opens it and ••• takes the count's place
/// on hover. A system coming with an import is dashed until its design's boards are in.
public struct NWDesignSystemCard<MenuItems: View>: View {
    let name: String
    let source: String?
    let count: String
    let colors: [Color]
    let tag: String?
    let dashed: Bool
    let action: (() -> Void)?
    let menu: MenuItems?
    @State private var hovering = false

    public init(name: String, source: String? = nil, count: String, colors: [Color] = [], tag: String? = nil, dashed: Bool = false,
                action: (() -> Void)? = nil, @ViewBuilder menu: () -> MenuItems) {
        self.name = name
        self.source = source
        self.count = count
        self.colors = colors
        self.tag = tag
        self.dashed = dashed
        self.action = action
        self.menu = menu()
    }

    public var body: some View {
        if let menu {
            card.contextMenu { menu }
        } else {
            card
        }
    }

    private var card: some View {
        let _ = NWRenderProbe.tick("design.systemCard")
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.cardRadius)
        return HStack(spacing: NWDesignMetrics.systemCardSpacing) {
            if !colors.isEmpty {
                HStack(spacing: NWDesignMetrics.swatchSpacing) {
                    ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: NW.Radius.xs)
                            .fill(color)
                            .frame(width: NWDesignMetrics.swatchSize, height: NWDesignMetrics.swatchSize)
                            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.xs)
                    }
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                HStack(spacing: NW.Space.s) {
                    Text(name)
                        .font(.nwMono(NWDesignMetrics.systemNameSize, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                        .lineLimit(1)
                    if let tag { NWDesignTagBadge(tag) }
                }
                if let source {
                    Text(source)
                        .font(.nwSans(NWDesignMetrics.systemSourceSize))
                        .foregroundStyle(Color.nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: NW.Space.m)
            ZStack(alignment: .trailing) {
                Text(count)
                    .font(.nwSans(NWDesignMetrics.systemCountSize))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hovering && menu != nil ? 0 : 1)
                if hovering, let menu {
                    NWDesignMoreButton(label: "More for \(name)") { menu }
                        .nwTransition(.content)
                }
            }
            .frame(minHeight: NWDesignMetrics.cardMoreSize)
        }
        .padding(.vertical, NWDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.cardPaddingHorizontal)
        .background(hovering && action != nil ? Color.nw.bgHover : .clear, in: shape)
        .nwBorder(dashed ? .clear : Color.nw.lineSubtle, radius: NWDesignMetrics.cardRadius)
        .overlay { if dashed { shape.strokeBorder(Color.nw.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
        .contentShape(shape)
        .onTapGesture { action?() }
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, tag, source, count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

extension NWDesignSystemCard where MenuItems == EmptyView {
    /// A card without a menu.
    public init(name: String, source: String? = nil, count: String, colors: [Color] = [], tag: String? = nil, dashed: Bool = false,
                action: (() -> Void)? = nil) {
        self.name = name
        self.source = source
        self.count = count
        self.colors = colors
        self.tag = tag
        self.dashed = dashed
        self.action = action
        self.menu = nil
    }
}

/// The design's system in the design header (NWDesignSystemChip; DZCanvas): 24pt, 8pt padding,
/// radius 6, a hairline, up to three of the system's colors as 8pt squares, then its name in
/// mono 11.5 `textSecondary`. With an action it opens the system's page.
public struct NWDesignSystemChip: View {
    let name: String
    let colors: [Color]
    let action: (() -> Void)?

    public init(_ name: String, colors: [Color] = [], action: (() -> Void)? = nil) {
        self.name = name
        self.colors = colors
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .help("Open \(name)")
                .accessibilityAddTraits(.isButton)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: NW.Space.s) {
            if !colors.isEmpty {
                HStack(spacing: NWDesignMetrics.chipSwatchSpacing) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: NWDesignMetrics.chipSwatchRadius)
                            .fill(color)
                            .frame(width: NWDesignMetrics.chipSwatch, height: NWDesignMetrics.chipSwatch)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(name)
                .font(.nwMono(NWDesignMetrics.chipTextSize))
                .foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, NWDesignMetrics.chipPadding)
        .frame(height: NWDesignMetrics.chipHeight)
        .nwBorder(Color.nw.lineSubtle, radius: NWDesignMetrics.chipRadius)
        .contentShape(RoundedRectangle(cornerRadius: NWDesignMetrics.chipRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Design system \(name)")
    }
}

/// A design system or starting point on New design (DZStart): 12×14 padding, radius 8, a
/// hairline, 6pt between its lines, the hover fill. A 13pt glyph and a title in mono 12
/// semibold; a line in 12.5 `textPrimary`; a note in 11 `textTertiary`. The chosen card is
/// `lanternTint` with a `lanternText` border and glyph.
public struct NWDesignStartCard: View {
    let symbol: String
    let title: String
    let line: String
    let note: String
    let chosen: Bool
    @State private var hovering = false

    public init(symbol: String, title: String, line: String, note: String, chosen: Bool) {
        self.symbol = symbol
        self.title = title
        self.line = line
        self.note = note
        self.chosen = chosen
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: symbol)
                    .font(.nwSans(NWDesignMetrics.startGlyph))
                    .foregroundStyle(chosen ? Color.nw.lanternText : Color.nw.textSecondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.nwMono(NWDesignMetrics.startTitleSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
            }
            Text(line)
                .font(.nwSans(NWDesignMetrics.startLineSize))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
            Text(note)
                .font(.nwSans(NWDesignMetrics.startNoteSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, NW.Space.l)
        .padding(.horizontal, NWDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chosen ? Color.nw.lanternTint : hovering ? Color.nw.bgHover : .clear, in: shape)
        .nwBorder(chosen ? Color.nw.lanternText : Color.nw.lineSubtle, radius: NW.Radius.m)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(line), \(note)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
