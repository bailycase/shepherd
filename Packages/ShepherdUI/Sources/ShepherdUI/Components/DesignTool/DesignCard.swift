import SwiftUI

/// How a design card draws its first board.
public enum SHDesignCardBoard: Equatable, Sendable {
    case desktop, phone
    /// No board drawn yet: the thumbnail is the dots alone.
    case none

    /// A phone board is taller than it is wide.
    public init(size: CGSize?) {
        guard let size, size.width > 0, size.height > 0 else { self = .none; return }
        self = size.height > size.width ? .phone : .desktop
    }
}

/// A design on the Designs page (SHDesignCard; NavDesigns): a radius-10 card with a hairline and
/// the hover fill. Its top is a 172pt thumbnail on `bgBase` with the canvas's dots every 16pt
/// and a hairline under it, the design's first board centered in it in its board frame (256×160
/// for a desktop board, 74×160 for a phone). Under it, 5pt apart: the name in 13.5 semibold; the
/// system in mono `textSecondary` then "· 4 boards" in 11.5 `textTertiary`; "edited 2h ago" in 11
/// `textTertiary`. The selected card wears a 2pt `textPrimary` ring. With a menu
/// (DesignCardMenu), a right-click anywhere on the card opens it, and ••• shows over the
/// thumbnail's top-trailing corner on hover.
public struct SHDesignCard<Thumbnail: View, MenuItems: View>: View {
    public typealias Board = SHDesignCardBoard

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
                            SHDesignMoreButton(label: "More for \(name)") { menu }
                                .padding(SHDesignMetrics.cardMoreInset)
                                .shTransition(.content)
                        }
                    }
                    .contextMenu { menu }
            } else {
                card
            }
        }
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
    }

    private var card: some View {
        let _ = SHRenderProbe.tick("design.card")
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.cardRadius)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    SHDotGrid(spacing: SHDesignMetrics.cardGridSpacing)
                    if let size = boardSize {
                        SHBoardSurface(size: size, selected: false) { thumbnail }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: SHDesignMetrics.cardThumbnailHeight)
                .background(Color.sh.bgBase)
                .clipped()
                .overlay(alignment: .bottom) { SHHairline() }
                VStack(alignment: .leading, spacing: SHDesignMetrics.cardLineSpacing) {
                    Text(name)
                        .font(.shSans(SHDesignMetrics.cardNameSize, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    meta
                    Text(edited)
                        .font(.shSans(SHDesignMetrics.cardEditedSize))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                }
                .padding(.vertical, SHDesignMetrics.cardPaddingVertical)
                .padding(.horizontal, SHDesignMetrics.cardPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(hovering ? Color.sh.bgHover : .clear, in: shape)
            .clipShape(shape)
            .shBorder(Color.sh.lineSubtle, radius: SHDesignMetrics.cardRadius)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.sh.textPrimary, lineWidth: SHDesignMetrics.cardRingWidth)
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
        case .desktop: SHDesignMetrics.cardDesktopBoard
        case .phone: SHDesignMetrics.cardPhoneBoard
        case .none: nil
        }
    }

    private var meta: some View {
        let detailText = Text(system == nil ? detail : " · \(detail)")
            .font(.shSans(SHDesignMetrics.cardMetaSize))
            .foregroundStyle(Color.sh.textTertiary)
        let line: Text = if let system {
            Text("\(Text(system).font(.shMono(SHDesignMetrics.cardMetaSize)).foregroundStyle(Color.sh.textSecondary))\(detailText)")
        } else {
            detailText
        }
        return line.lineLimit(1).truncationMode(.tail)
    }
}

extension SHDesignCard where MenuItems == EmptyView {
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
public struct SHDesignSystemCard<MenuItems: View>: View {
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
        let _ = SHRenderProbe.tick("design.systemCard")
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.cardRadius)
        return HStack(spacing: SHDesignMetrics.systemCardSpacing) {
            if !colors.isEmpty {
                HStack(spacing: SHDesignMetrics.swatchSpacing) {
                    ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: SH.Radius.xs)
                            .fill(color)
                            .frame(width: SHDesignMetrics.swatchSize, height: SHDesignMetrics.swatchSize)
                            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
                    }
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: SH.Space.s) {
                    Text(name)
                        .font(.shMono(SHDesignMetrics.systemNameSize, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1)
                    if let tag { SHDesignTagBadge(tag) }
                }
                if let source {
                    Text(source)
                        .font(.shSans(SHDesignMetrics.systemSourceSize))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: SH.Space.m)
            ZStack(alignment: .trailing) {
                Text(count)
                    .font(.shSans(SHDesignMetrics.systemCountSize))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hovering && menu != nil ? 0 : 1)
                if hovering, let menu {
                    SHDesignMoreButton(label: "More for \(name)") { menu }
                        .shTransition(.content)
                }
            }
            .frame(minHeight: SHDesignMetrics.cardMoreSize)
        }
        .padding(.vertical, SHDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.cardPaddingHorizontal)
        .background(hovering && action != nil ? Color.sh.bgHover : .clear, in: shape)
        .shBorder(dashed ? .clear : Color.sh.lineSubtle, radius: SHDesignMetrics.cardRadius)
        .overlay { if dashed { shape.strokeBorder(Color.sh.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
        .contentShape(shape)
        .onTapGesture { action?() }
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, tag, source, count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

extension SHDesignSystemCard where MenuItems == EmptyView {
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

/// The design's system in the design header (SHDesignSystemChip; DZCanvas): 24pt, 8pt padding,
/// radius 6, a hairline, up to three of the system's colors as 8pt squares, then its name in
/// mono 11.5 `textSecondary`. With an action it opens the system's page.
public struct SHDesignSystemChip: View {
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
        HStack(spacing: SH.Space.s) {
            if !colors.isEmpty {
                HStack(spacing: SHDesignMetrics.chipSwatchSpacing) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: SHDesignMetrics.chipSwatchRadius)
                            .fill(color)
                            .frame(width: SHDesignMetrics.chipSwatch, height: SHDesignMetrics.chipSwatch)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(name)
                .font(.shMono(SHDesignMetrics.chipTextSize))
                .foregroundStyle(Color.sh.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, SHDesignMetrics.chipPadding)
        .frame(height: SHDesignMetrics.chipHeight)
        .shBorder(Color.sh.lineSubtle, radius: SHDesignMetrics.chipRadius)
        .contentShape(RoundedRectangle(cornerRadius: SHDesignMetrics.chipRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Design system \(name)")
    }
}

/// A design system or starting point on New design (DZStart): 12×14 padding, radius 8, a
/// hairline, 6pt between its lines, the hover fill. A 13pt glyph and a title in mono 12
/// semibold; a line in 12.5 `textPrimary`; a note in 11 `textTertiary`. The chosen card is
/// `lanternTint` with a `lanternText` border and glyph.
public struct SHDesignStartCard: View {
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
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                Image(systemName: symbol)
                    .font(.shSans(SHDesignMetrics.startGlyph))
                    .foregroundStyle(chosen ? Color.sh.lanternText : Color.sh.textSecondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.shMono(SHDesignMetrics.startTitleSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
            }
            Text(line)
                .font(.shSans(SHDesignMetrics.startLineSize))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            Text(note)
                .font(.shSans(SHDesignMetrics.startNoteSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SHDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chosen ? Color.sh.lanternTint : hovering ? Color.sh.bgHover : .clear, in: shape)
        .shBorder(chosen ? Color.sh.lanternText : Color.sh.lineSubtle, radius: SH.Radius.m)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(line), \(note)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
