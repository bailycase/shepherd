import SwiftUI

// The Design tool on iPhone (MobileDesigns, MobileDesignBoard): a design's tile, a design
// system's row, a board's page dots, the comment card that rises over a board, and the board's
// toolbar. The boards draw in their own system; everything here is Shepherd Design.

/// The phone's own measures, as MobileDesigns and MobileDesignBoard draw them.
public enum SHPhoneDesignMetrics {
    // A design's tile (MobileDesigns)
    /// The thumbnail: 110pt tall, radius 10, a 1px `lineSubtle` line.
    public static let tileHeight: CGFloat = 110
    public static let tileRadius: CGFloat = 10
    /// Between the thumbnail, the name and the line under it.
    public static let tileSpacing: CGFloat = SH.Space.s
    public static let tileNameSize: CGFloat = 14
    public static let tileDetailSize: CGFloat = 12
    /// The grid: 14pt between rows, 12pt between columns.
    public static let gridRowSpacing: CGFloat = 14
    public static let gridColumnSpacing: CGFloat = SH.Space.l

    // A design system's row
    /// At least 52pt, 8×14 padding, 12pt between its parts.
    public static let systemRowHeight: CGFloat = 52
    public static let systemRowPaddingVertical: CGFloat = SH.Space.m
    public static let systemRowPaddingHorizontal: CGFloat = 14
    public static let systemRowSpacing: CGFloat = SH.Space.l
    /// Three 7×14 swatches (radius 2), 2pt apart, in a 20pt column.
    public static let swatchWidth: CGFloat = 7
    public static let swatchHeight: CGFloat = 14
    public static let swatchRadius: CGFloat = 2
    public static let swatchSpacing: CGFloat = SH.Space.xxs
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
    public static let cardPaddingVertical: CGFloat = SH.Space.l
    public static let cardPaddingHorizontal: CGFloat = 14
    public static let cardSpacing: CGFloat = SH.Space.m
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
    public static let toolSpacing: CGFloat = SH.Space.xs
    public static let toolbarPaddingVertical: CGFloat = 10
    public static let toolbarPaddingHorizontal: CGFloat = 14
}

/// A design on the phone's Designs screen (MobileDesigns): its first board in a 110pt thumbnail
/// (radius 10, a 1px `lineSubtle` line, on the board's own background), its name in 14
/// semibold, and "acme-web · 4 boards · 2m" in 12 `textTertiary`.
public struct SHDesignTile<Thumbnail: View>: View {
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
        let _ = SHRenderProbe.tick("design.tile")
        let shape = RoundedRectangle(cornerRadius: SHPhoneDesignMetrics.tileRadius)
        Button(action: action) {
            VStack(alignment: .leading, spacing: SHPhoneDesignMetrics.tileSpacing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: SHPhoneDesignMetrics.tileHeight)
                    .background(Color.sh.bgBase)
                    .clipShape(shape)
                    .shBorder(Color.sh.lineSubtle, radius: SHPhoneDesignMetrics.tileRadius)
                Text(name)
                    .font(.shSans(SHPhoneDesignMetrics.tileNameSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([detail, host].compactMap { $0 }.joined(separator: " · "))
                    .font(.shSans(SHPhoneDesignMetrics.tileDetailSize))
                    .foregroundStyle(Color.sh.textTertiary)
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
/// its name in sans 15 bold over its source in 12.5 `textTertiary`, and a chevron. At least
/// 52pt, in a list card.
public struct SHDesignSystemRow: View, Equatable {
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

    public nonisolated static func == (a: SHDesignSystemRow, b: SHDesignSystemRow) -> Bool {
        a.name == b.name && a.source == b.source && a.colors == b.colors && a.chevron == b.chevron
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SHPhoneDesignMetrics.systemRowSpacing) {
            HStack(spacing: SHPhoneDesignMetrics.swatchSpacing) {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: SHPhoneDesignMetrics.swatchRadius)
                        .fill(color)
                        .frame(width: SHPhoneDesignMetrics.swatchWidth, height: SHPhoneDesignMetrics.swatchHeight)
                }
            }
            .frame(width: SHPhoneDesignMetrics.swatchColumn)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name)
                    .font(.shSans(SHPhoneDesignMetrics.systemNameSize, .bold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if let source {
                    Text(source)
                        .font(.shSans(SHPhoneDesignMetrics.systemSourceSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, SHPhoneDesignMetrics.systemRowPaddingVertical)
        .padding(.horizontal, SHPhoneDesignMetrics.systemRowPaddingHorizontal)
        .frame(maxWidth: .infinity, minHeight: SHPhoneDesignMetrics.systemRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One dot per board under the board's name (MobileDesignBoard): the one shown in
/// `textPrimary`, the rest `lineStrong`.
public struct SHBoardDots: View, Equatable {
    let count: Int
    let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public var body: some View {
        HStack(spacing: SHPhoneDesignMetrics.dotSpacing) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.sh.textPrimary : Color.sh.lineStrong)
                    .frame(width: SHPhoneDesignMetrics.dotSize, height: SHPhoneDesignMetrics.dotSize)
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
public struct SHPhoneCommentCard: View, Equatable {
    let number: Int
    let target: String
    let meta: String
    let text: String
    let status: String?
    let answer: SHCommentEntry?

    public init(number: Int, target: String, meta: String, text: String, status: String? = nil, answer: SHCommentEntry? = nil) {
        self.number = number
        self.target = target
        self.meta = meta
        self.text = text
        self.status = status
        self.answer = answer
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SHPhoneDesignMetrics.cardSpacing) {
            HStack(spacing: SH.Space.m) {
                SHCommentPin(number, size: .card)
                (Text("on ") + Text(target).fontWeight(.semibold).foregroundStyle(sh.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SH.Space.m)
                Text(meta).lineLimit(1)
            }
            .font(.shSans(SHPhoneDesignMetrics.cardMetaSize))
            .foregroundStyle(sh.textTertiary)
            phoneText(text)
            if let status {
                HStack(spacing: SH.Space.m) {
                    ProgressView().progressViewStyle(SHSpinnerStyle(size: SHPhoneDesignMetrics.cardSpinner, color: sh.running))
                    Text(status).lineLimit(2)
                }
                .font(.shSans(SHPhoneDesignMetrics.cardStatusSize))
                .foregroundStyle(sh.textSecondary)
                .accessibilityElement(children: .combine)
            }
            if let answer {
                VStack(alignment: .leading, spacing: SHDesignMetrics.entrySpacing) {
                    (Text(answer.author).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
                        + Text(" · \(answer.age)").foregroundStyle(sh.textTertiary))
                        .font(.shSans(SHPhoneDesignMetrics.cardMetaSize))
                    phoneText(answer.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SHDesignMetrics.entryGap)
                .overlay(alignment: .top) { SHHairline() }
            }
        }
        .padding(.vertical, SHPhoneDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, SHPhoneDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shPopover(radius: SHPhoneDesignMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }

    private func phoneText(_ text: String) -> some View {
        Text(text)
            .shText(size: SHPhoneDesignMetrics.cardTextSize, lineHeight: SHPhoneDesignMetrics.cardLineHeight)
            .foregroundStyle(Color.sh.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The board's toolbar on the phone (MobileDesignBoard): its tools spread evenly on `bgWindow`
/// under a hairline, each a 20pt glyph over an 11pt label; the active one `running`.
public struct SHBoardToolbar: View {
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
                    VStack(spacing: SHPhoneDesignMetrics.toolSpacing) {
                        Image(systemName: tool.symbol)
                            .font(.shSans(SHPhoneDesignMetrics.toolSymbolSize))
                            .frame(width: SHPhoneDesignMetrics.toolGlyph, height: SHPhoneDesignMetrics.toolGlyph)
                        Text(tool.title)
                            .font(.shSans(SHPhoneDesignMetrics.toolLabelSize))
                            .lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.sh.running : Color.sh.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(tool.id))
                .opacity(disabled.contains(tool.id) ? SHListMetrics.dimmedOpacity : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, SHPhoneDesignMetrics.toolbarPaddingVertical)
        .padding(.horizontal, SHPhoneDesignMetrics.toolbarPaddingHorizontal)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
    }
}
