import SwiftUI

// The Design tool on iPhone (MobileDesigns, MobileDesignBoard): a design's tile, a design
// system's row, a board's page dots, the comment card that rises over a board, and the board's
// toolbar. The boards draw in their own system; everything here is Night Watch.

/// The phone's own measures, as MobileDesigns and MobileDesignBoard draw them.
public enum NWPhoneDesignMetrics {
    // A design's tile (MobileDesigns)
    /// The thumbnail: 110pt tall, radius 10, a 1px `lineSubtle` line.
    public static let tileHeight: CGFloat = 110
    public static let tileRadius: CGFloat = 10
    /// Between the thumbnail, the name and the line under it.
    public static let tileSpacing: CGFloat = NW.Space.s
    public static let tileNameSize: CGFloat = 14
    public static let tileDetailSize: CGFloat = 12
    /// The grid: 14pt between rows, 12pt between columns.
    public static let gridRowSpacing: CGFloat = 14
    public static let gridColumnSpacing: CGFloat = NW.Space.l

    // A design system's row
    /// At least 52pt, 8×14 padding, 12pt between its parts.
    public static let systemRowHeight: CGFloat = 52
    public static let systemRowPaddingVertical: CGFloat = NW.Space.m
    public static let systemRowPaddingHorizontal: CGFloat = 14
    public static let systemRowSpacing: CGFloat = NW.Space.l
    /// Three 7×14 swatches (radius 2), 2pt apart, in a 20pt column.
    public static let swatchWidth: CGFloat = 7
    public static let swatchHeight: CGFloat = 14
    public static let swatchRadius: CGFloat = 2
    public static let swatchSpacing: CGFloat = NW.Space.xxs
    public static let swatchColumn: CGFloat = 20
    public static let systemNameSize: CGFloat = 15
    public static let systemSourceSize: CGFloat = 12.5

    // A board (MobileDesignBoard)
    /// The page dots under the board's name: 6pt, 5pt apart.
    public static let dotSize: CGFloat = 6
    public static let dotSpacing: CGFloat = 5
    public static let boardTitleSize: CGFloat = 16
    /// The comment card over the board: 12×14 padding, 8pt between its parts, radius 14, a
    /// header in 12, the comment in 14/1.45, the agent's progress in 12.5 with an 11pt spinner.
    public static let cardPaddingVertical: CGFloat = NW.Space.l
    public static let cardPaddingHorizontal: CGFloat = 14
    public static let cardSpacing: CGFloat = NW.Space.m
    public static let cardRadius: CGFloat = 14
    public static let cardMetaSize: CGFloat = 12
    public static let cardTextSize: CGFloat = 14
    public static let cardLineHeight: CGFloat = 1.45
    public static let cardStatusSize: CGFloat = 12.5
    public static let cardSpinner: CGFloat = 11
    /// The toolbar: a 20pt glyph over an 11pt label, 4pt apart, 10×14 padding.
    public static let toolGlyph: CGFloat = 20
    /// The symbol drawn in that 20pt box.
    public static let toolSymbolSize: CGFloat = 17
    public static let toolLabelSize: CGFloat = 11
    public static let toolSpacing: CGFloat = NW.Space.xs
    public static let toolbarPaddingVertical: CGFloat = 10
    public static let toolbarPaddingHorizontal: CGFloat = 14
}

/// A design on the phone's Designs screen (MobileDesigns): its first board in a 110pt thumbnail
/// (radius 10, a 1px `lineSubtle` line, on the board's own background), its name in 14
/// semibold, and "acme-web · 4 boards · 2m" in 12 `textTertiary`.
public struct NWDesignTile<Thumbnail: View>: View {
    let name: String
    let detail: String
    let host: String?
    let action: () -> Void
    let thumbnail: Thumbnail

    public init(name: String, detail: String, host: String? = nil, action: @escaping () -> Void,
                @ViewBuilder thumbnail: () -> Thumbnail) {
        self.name = name
        self.detail = detail
        self.host = host
        self.action = action
        self.thumbnail = thumbnail()
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("design.tile")
        let shape = RoundedRectangle(cornerRadius: NWPhoneDesignMetrics.tileRadius)
        Button(action: action) {
            VStack(alignment: .leading, spacing: NWPhoneDesignMetrics.tileSpacing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: NWPhoneDesignMetrics.tileHeight)
                    .background(Color.nw.bgBase)
                    .clipShape(shape)
                    .nwBorder(Color.nw.lineSubtle, radius: NWPhoneDesignMetrics.tileRadius)
                Text(name)
                    .font(.nwSans(NWPhoneDesignMetrics.tileNameSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([detail, host].compactMap { $0 }.joined(separator: " · "))
                    .font(.nwSans(NWPhoneDesignMetrics.tileDetailSize))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, detail, host].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// A design system as the phone lists it (MobileDesigns): three of its colors as 7×14 swatches,
/// its name in mono 15 medium over its source in 12.5 `textTertiary`, and a chevron. At least
/// 52pt, in a list card.
public struct NWDesignSystemRow: View, Equatable {
    let name: String
    let source: String?
    let colors: [Color]
    let chevron: Bool

    public init(name: String, source: String? = nil, colors: [Color] = [], chevron: Bool = true) {
        self.name = name
        self.source = source
        self.colors = colors
        self.chevron = chevron
    }

    public nonisolated static func == (a: NWDesignSystemRow, b: NWDesignSystemRow) -> Bool {
        a.name == b.name && a.source == b.source && a.colors == b.colors && a.chevron == b.chevron
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWPhoneDesignMetrics.systemRowSpacing) {
            HStack(spacing: NWPhoneDesignMetrics.swatchSpacing) {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: NWPhoneDesignMetrics.swatchRadius)
                        .fill(color)
                        .frame(width: NWPhoneDesignMetrics.swatchWidth, height: NWPhoneDesignMetrics.swatchHeight)
                }
            }
            .frame(width: NWPhoneDesignMetrics.swatchColumn)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(name)
                    .font(.nwMono(NWPhoneDesignMetrics.systemNameSize, .medium))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                if let source {
                    Text(source)
                        .font(.nwSans(NWPhoneDesignMetrics.systemSourceSize))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.nw(.caption, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, NWPhoneDesignMetrics.systemRowPaddingVertical)
        .padding(.horizontal, NWPhoneDesignMetrics.systemRowPaddingHorizontal)
        .frame(maxWidth: .infinity, minHeight: NWPhoneDesignMetrics.systemRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One dot per board under the board's name (MobileDesignBoard): the one shown in
/// `textPrimary`, the rest `lineStrong`.
public struct NWBoardDots: View, Equatable {
    let count: Int
    let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public var body: some View {
        HStack(spacing: NWPhoneDesignMetrics.dotSpacing) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.nw.textPrimary : Color.nw.lineStrong)
                    .frame(width: NWPhoneDesignMetrics.dotSize, height: NWPhoneDesignMetrics.dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Board \(current + 1) of \(count)")
    }
}

/// A comment as it rises over a board on the phone (MobileDesignBoard): the small pin, "on" and
/// the element in `textPrimary` semibold, the author and age trailing, the comment in 14/1.45;
/// while the design agent works on it, a running spinner and "Design agent is updating A ·
/// phone"; once it answered, its answer under a hairline.
public struct NWPhoneCommentCard: View, Equatable {
    let number: Int
    let target: String
    let meta: String
    let text: String
    let status: String?
    let answer: NWCommentEntry?

    public init(number: Int, target: String, meta: String, text: String, status: String? = nil, answer: NWCommentEntry? = nil) {
        self.number = number
        self.target = target
        self.meta = meta
        self.text = text
        self.status = status
        self.answer = answer
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NWPhoneDesignMetrics.cardSpacing) {
            HStack(spacing: NW.Space.m) {
                NWCommentPin(number, size: .card)
                (Text("on ") + Text(target).fontWeight(.semibold).foregroundStyle(nw.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NW.Space.m)
                Text(meta).lineLimit(1)
            }
            .font(.nwSans(NWPhoneDesignMetrics.cardMetaSize))
            .foregroundStyle(nw.textTertiary)
            phoneText(text)
            if let status {
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(NWSpinnerStyle(size: NWPhoneDesignMetrics.cardSpinner, color: nw.running))
                    Text(status).lineLimit(2)
                }
                .font(.nwSans(NWPhoneDesignMetrics.cardStatusSize))
                .foregroundStyle(nw.textSecondary)
                .accessibilityElement(children: .combine)
            }
            if let answer {
                VStack(alignment: .leading, spacing: NWDesignMetrics.entrySpacing) {
                    (Text(answer.author).fontWeight(.semibold).foregroundStyle(nw.textPrimary)
                        + Text(" · \(answer.age)").foregroundStyle(nw.textTertiary))
                        .font(.nwSans(NWPhoneDesignMetrics.cardMetaSize))
                    phoneText(answer.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, NWDesignMetrics.entryGap)
                .overlay(alignment: .top) { NWHairline() }
            }
        }
        .padding(.vertical, NWPhoneDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, NWPhoneDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwPopover(radius: NWPhoneDesignMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }

    private func phoneText(_ text: String) -> some View {
        Text(text)
            .nwText(size: NWPhoneDesignMetrics.cardTextSize, lineHeight: NWPhoneDesignMetrics.cardLineHeight)
            .foregroundStyle(Color.nw.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The board's toolbar on the phone (MobileDesignBoard): its tools spread evenly on `bgWindow`
/// under a hairline, each a 20pt glyph over an 11pt label; the active one `running`.
public struct NWBoardToolbar: View {
    public struct Tool: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var symbol: String

        public init(id: String, title: String, symbol: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    let tools: [Tool]
    let active: String?
    let disabled: Set<String>
    let action: (String) -> Void

    public init(tools: [Tool], active: String?, disabled: Set<String> = [], action: @escaping (String) -> Void) {
        self.tools = tools
        self.active = active
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(tools) { tool in
                let on = tool.id == active
                Button { action(tool.id) } label: {
                    VStack(spacing: NWPhoneDesignMetrics.toolSpacing) {
                        Image(systemName: tool.symbol)
                            .font(.nwSans(NWPhoneDesignMetrics.toolSymbolSize))
                            .frame(width: NWPhoneDesignMetrics.toolGlyph, height: NWPhoneDesignMetrics.toolGlyph)
                        Text(tool.title)
                            .font(.nwSans(NWPhoneDesignMetrics.toolLabelSize))
                            .lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.nw.running : Color.nw.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(tool.id))
                .opacity(disabled.contains(tool.id) ? NWListMetrics.dimmedOpacity : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, NWPhoneDesignMetrics.toolbarPaddingVertical)
        .padding(.horizontal, NWPhoneDesignMetrics.toolbarPaddingHorizontal)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }
}
