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

/// A design on the Designs page (SHDesignCard; NavDesigns): a radius-14 card on the `lift` shadow.
/// Its top is a 156pt thumbnail on `bgHover` with a hairline under it, the design's first board
/// centered in it in a radius-5 frame on the `lift` (200×125 for a desktop board, 60×128 for a
/// phone). Under it: the name in `body` semibold; the system, boards and comments in `caption`
/// `textSecondary`; "edited 2h ago" in `caption` `textTertiary`. The selected card wears a 1.5pt
/// `textPrimary` ring. With a menu (DesignCardMenu), a right-click anywhere on the card opens it,
/// and ••• shows at the card's bottom-trailing corner on hover.
public struct SHDesignCard<Thumbnail: View, MenuItems: View>: View {
    public typealias Board = SHDesignCardBoard

    let name: String
    let meta: String
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
        self.meta = [system, detail].compactMap { $0 }.joined(separator: " · ")
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
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            SHDesignMoreButton(label: "More for \(name)") { menu }
                                .padding(.trailing, SHDesignsHomeMetrics.moreInsetTrailing)
                                .padding(.bottom, SHDesignsHomeMetrics.moreInsetBottom)
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
        let M = SHDesignsHomeMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xl)
        let top = UnevenRoundedRectangle(topLeadingRadius: SH.Radius.xl, topTrailingRadius: SH.Radius.xl)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let size = boardSize {
                        let frame = RoundedRectangle(cornerRadius: M.boardRadius)
                        thumbnail
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .clipShape(frame)
                            .background { Color.clear.shLift(frame) }
                            .shBorder(Color.sh.lineSubtle, in: frame)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: M.thumbnailHeight)
                .background(Color.sh.bgHover, in: top)
                .overlay(alignment: .bottom) { SHHairline() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.sh(.body, weight: .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(meta)
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, M.cardMetaTop)
                    Text(edited)
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                        .padding(.top, M.cardEditedTop)
                }
                .padding(.top, M.cardPaddingTop)
                .padding(.bottom, M.cardPaddingBottom)
                .padding(.horizontal, M.cardPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { Color.clear.shLift(shape) }
            .shBorder(Color.sh.lineSubtle, in: shape)
            .overlay {
                if selected {
                    shape.inset(by: -M.startRing / 2).stroke(Color.sh.textPrimary, lineWidth: M.startRing)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, meta, edited].joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var boardSize: CGSize? {
        switch board {
        case .desktop: SHDesignsHomeMetrics.desktopBoard
        case .phone: SHDesignsHomeMetrics.phoneBoard
        case .none: nil
        }
    }
}

extension SHDesignCard where MenuItems == EmptyView {
    /// A card without a menu (a host's design, the iPad's grid).
    public init(name: String, system: String?, detail: String, edited: String, board: Board, selected: Bool = false,
                action: @escaping () -> Void, @ViewBuilder thumbnail: () -> Thumbnail) {
        self.name = name
        self.meta = [system, detail].compactMap { $0 }.joined(separator: " · ")
        self.edited = edited
        self.board = board
        self.selected = selected
        self.action = action
        self.thumbnail = thumbnail()
        self.menu = nil
    }
}

/// A design system on the Designs page (NavDesigns): a 62pt radius-14 card on the `lift` shadow,
/// 14pt in at the front and 12 at the back, 12pt between its parts: up to four of the system's
/// colors as 14pt swatches, its name in `body` semibold over its
/// source in `caption` `textTertiary`, and how many designs use it trailing in `caption`
/// `textTertiary` ("3 designs"). With a menu (SystemCardMenu), a right-click opens it and ••• joins
/// the count on hover. A system coming with an import is a dashed outline until its design's
/// boards are in.
public struct SHDesignSystemCard<MenuItems: View>: View {
    let name: String
    let source: String?
    let count: String
    let colors: [Color]
    let dashed: Bool
    let action: (() -> Void)?
    let menu: MenuItems?
    @State private var hovering = false

    public init(name: String, source: String? = nil, count: String, colors: [Color] = [], dashed: Bool = false,
                action: (() -> Void)? = nil, @ViewBuilder menu: () -> MenuItems) {
        self.name = name
        self.source = source
        self.count = count
        self.colors = colors
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
        let M = SHDesignsHomeMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xl)
        return HStack(spacing: M.systemSpacing) {
            if !colors.isEmpty {
                HStack(spacing: M.swatchSpacing) {
                    ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: SH.Radius.xs)
                            .fill(color)
                            .frame(width: M.swatch, height: M.swatch)
                            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
                    }
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.sh(.body, weight: .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                if let source {
                    Text(source)
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: SH.Space.m)
            Text(count)
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .fixedSize()
            if hovering, let menu {
                SHDesignMoreButton(label: "More for \(name)") { menu }
                    .shTransition(.content)
            }
        }
        .padding(.leading, M.systemPaddingLeading)
        .padding(.trailing, M.systemPaddingTrailing)
        .frame(height: M.systemHeight)
        .background { Color.clear.shLift(shape, fill: dashed ? .clear : nil) }
        .shBorder(dashed ? Color.sh.textTertiary : Color.sh.lineSubtle, in: shape, dash: dashed ? [4, 3] : [])
        .contentShape(shape)
        .onTapGesture { action?() }
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, source, count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

extension SHDesignSystemCard where MenuItems == EmptyView {
    /// A card without a menu.
    public init(name: String, source: String? = nil, count: String, colors: [Color] = [], dashed: Bool = false,
                action: (() -> Void)? = nil) {
        self.name = name
        self.source = source
        self.count = count
        self.colors = colors
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

/// A design system or starting point on New design (DZStart): 12×14 padding, radius 12, a
/// hairline on the `lift`, 12pt between its glyph and its lines. A 14pt glyph in `textSecondary`;
/// a title in `headline` and a line in `ui`, both `textSecondary`; a note in `caption` `textTertiary`.
/// The chosen card wears a 1.5pt `textPrimary` ring; a card that opens a menu ends in up and down
/// chevrons. Hover tints it.
public struct SHDesignStartCard: View {
    let symbol: String
    let title: String
    let line: String
    let note: String
    let chosen: Bool
    let menu: Bool
    @State private var hovering = false

    public init(symbol: String, title: String, line: String, note: String, chosen: Bool, menu: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.line = line
        self.note = note
        self.chosen = chosen
        self.menu = menu
    }

    public var body: some View {
        let M = SHDesignsHomeMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        HStack(alignment: .top, spacing: M.startSpacing) {
            Image(systemName: symbol)
                .font(.shSans(M.startGlyph))
                .foregroundStyle(Color.sh.textSecondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                // Each line in its board line box (13 on 18, 12 on 17): the card is 83pt, not what the glyphs alone take.
                Text(title)
                    .font(.sh(.headline))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
                    .frame(minHeight: SHTextStyle.headline.size * SHTextStyle.headline.lineHeight)
                Text(line)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
                    .frame(minHeight: SHTextStyle.ui.size * SHTextStyle.ui.lineHeight)
                    .padding(.top, 1)
                Text(note)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minHeight: SHTextStyle.caption.size * SHTextStyle.caption.lineHeight)
                    .padding(.top, SH.Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            if menu {
                SHGlyph.popupChevrons.image
                    .font(.shSans(M.startChevron, .medium))
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, M.startPaddingTop)
        .padding(.bottom, M.startPaddingBottom)
        .padding(.horizontal, M.startPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.sh.bgHover : .clear, in: shape)
        .background { Color.clear.shLift(shape) }
        .shBorder(Color.sh.lineSubtle, in: shape)
        .overlay {
            if chosen {
                shape.inset(by: -M.startRing / 2).stroke(Color.sh.textPrimary, lineWidth: M.startRing)
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(line), \(note)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
