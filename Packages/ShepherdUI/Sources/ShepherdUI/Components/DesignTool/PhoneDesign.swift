import SwiftUI

// The Design tool on iPhone (MobileDesigns, MobileDesignBoard): a design's tile, a design
// system's row, a board's page dots, the comment card that rises over a board, and the board's
// toolbar. The boards draw in their own system; everything here is Shepherd Design.

/// The phone's own measures, as MobileDesigns and MobileDesignBoard draw them.
public enum SHPhoneDesignMetrics {
    // A design's tile (MobileDesigns)
    /// The tile is a card at radius 16: the thumbnail 112pt tall on a `bgHover` wash, flush to its
    /// top, and under it the name in 15 semibold over the line in 13 `textSecondary`, 10 above
    /// and 12 below, 12 at the sides.
    public static let tileHeight: CGFloat = 112
    public static let tileRadius: CGFloat = SH.Radius.xxl
    public static let tileNameSize: CGFloat = 15
    public static let tileDetailSize: CGFloat = 13
    public static let tileFooterTop: CGFloat = 10
    public static let tileFooterSides: CGFloat = 12
    public static let tileFooterBottom: CGFloat = 12
    /// The grid: 12pt between rows and columns, a tile at least this wide (two on a phone, three
    /// on one side of an open Duo).
    public static let gridRowSpacing: CGFloat = SH.Space.l
    public static let gridColumnSpacing: CGFloat = SH.Space.l
    public static let gridColumnMinimum: CGFloat = 160

    // A design system's row
    /// At least 52pt, 10×16 padding, 12pt between its parts.
    public static let systemRowHeight: CGFloat = 52
    public static let systemRowPaddingVertical: CGFloat = 10
    public static let systemRowPaddingHorizontal: CGFloat = SH.Space.xl
    public static let systemRowSpacing: CGFloat = SH.Space.l
    /// Three 7×14 swatches (radius 2), 2pt apart, in a 20pt column.
    public static let swatchWidth: CGFloat = 7
    public static let swatchHeight: CGFloat = 14
    public static let swatchRadius: CGFloat = 2
    public static let swatchSpacing: CGFloat = SH.Space.xxs
    public static let swatchColumn: CGFloat = 20
    public static let systemNameSize: CGFloat = 15
    public static let systemSourceSize: CGFloat = 13

    // A board (MobileDesignBoard)
    /// The page dots under the board's name: 5pt, 4pt apart.
    public static let dotSize: CGFloat = 5
    public static let dotSpacing: CGFloat = SH.Space.xs
    public static let boardTitleSize: CGFloat = 16
    /// The comment card over the board: 12×14 padding, 8pt between its parts, radius 14, a
    /// header in 12, the comment in 14/1.45, the agent's progress in 12.5, shimmering.
    public static let cardPaddingVertical: CGFloat = SH.Space.l
    public static let cardPaddingHorizontal: CGFloat = 14
    public static let cardSpacing: CGFloat = SH.Space.m
    public static let cardRadius: CGFloat = 14
    public static let cardMetaSize: CGFloat = 12
    public static let cardTextSize: CGFloat = 14
    public static let cardLineHeight: CGFloat = 1.45
    public static let cardStatusSize: CGFloat = 12.5
    /// The toolbar floats as a 60pt glass capsule 16pt in from the sides: each tool a 52pt capsule
    /// with a 22pt glyph over a 12pt medium label, 2pt apart, the chosen one on `bgSelected`.
    public static let toolGlyph: CGFloat = 22
    /// The symbol drawn in that 22pt box.
    public static let toolSymbolSize: CGFloat = 19
    public static let toolLabelSize: CGFloat = 12
    public static let toolSpacing: CGFloat = SH.Space.xxs
    public static let toolHeight: CGFloat = 52
    public static let toolbarHeight: CGFloat = 60
    public static let toolbarInset: CGFloat = SH.Space.xs
    /// The comment card's radius and padding (12×16), and the pin in its head.
    public static let threadRadius: CGFloat = 20
    public static let threadPaddingVertical: CGFloat = SH.Space.l
    public static let threadPaddingHorizontal: CGFloat = SH.Space.xl
    public static let threadPin: CGFloat = 22
    public static let replyHeight: CGFloat = 36
    /// Its author and Resolve in 14, its comment and reply in 15 at 1.4.
    public static let threadAuthor: CGFloat = 14
    public static let threadText: CGFloat = 15
    public static let threadLineHeight: CGFloat = 1.4
}

/// A design on the Designs screen (MobileDesigns, DuoOpenDesigns): a card at radius 16 with its
/// first board in a 112pt thumbnail on a `bgHover` wash flush to the top, its name in 15
/// semibold, and "acme-web · 4 boards · 2m" in 13 `textSecondary`.
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
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: SHPhoneDesignMetrics.tileHeight)
                    .background(Color.sh.bgHover)
                    .clipped()
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(name)
                        .font(.shSans(SHPhoneDesignMetrics.tileNameSize, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text([detail, host].compactMap { $0 }.joined(separator: " · "))
                        .font(.shSans(SHPhoneDesignMetrics.tileDetailSize))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, SHPhoneDesignMetrics.tileFooterTop)
                .padding(.horizontal, SHPhoneDesignMetrics.tileFooterSides)
                .padding(.bottom, SHPhoneDesignMetrics.tileFooterBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .shCard(radius: SHPhoneDesignMetrics.tileRadius, line: Color.sh.lineSubtle, lift: true)
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
                    .font(.shSans(SHPhoneDesignMetrics.systemNameSize, .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if let source {
                    Text(source)
                        .font(.shSans(SHPhoneDesignMetrics.systemSourceSize))
                        .foregroundStyle(sh.textSecondary)
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
                    .fill(index == current ? Color.sh.textPrimary : Color.sh.textTertiary.opacity(0.5))
                    .frame(width: SHPhoneDesignMetrics.dotSize, height: SHPhoneDesignMetrics.dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Board \(current + 1) of \(count)")
    }
}

/// A comment as it rises over a board on the phone (MobileDesignBoard): the small pin, "on" and
/// the element in `textPrimary` semibold, the author and age trailing, the comment in 14/1.45;
/// while the design agent works on it, a shimmering status and "Design agent is updating A ·
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
                Text(status).lineLimit(2)
                    .shShimmer(active: true)
                    .font(.shSans(SHPhoneDesignMetrics.cardStatusSize))
                    .foregroundStyle(sh.textSecondary)
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

/// The board's toolbar on the phone (MobileDesignBoard): a floating glass capsule, each tool a
/// 22pt glyph in `textSecondary` over its 12pt label in `textPrimary`; the active one on
/// `bgSelected`.
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
                            .foregroundStyle(Color.sh.textSecondary)
                            .frame(width: SHPhoneDesignMetrics.toolGlyph, height: SHPhoneDesignMetrics.toolGlyph)
                        Text(tool.title)
                            .font(.shSans(SHPhoneDesignMetrics.toolLabelSize, .medium))
                            .foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: SHPhoneDesignMetrics.toolHeight)
                    .background(on ? Color.sh.bgSelected : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(tool.id))
                .opacity(disabled.contains(tool.id) ? SHListMetrics.dimmedOpacity : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(SHPhoneDesignMetrics.toolbarInset)
        .frame(height: SHPhoneDesignMetrics.toolbarHeight)
        .glassEffect(.regular, in: Capsule())
    }
}

/// A comment on the phone's board (MobileDesignBoard), the card over the toolbar: a 20pt card
/// with the pin in 22pt `primary`, the author in 14 semibold and the age in `textTertiary`,
/// Resolve trailing in `textPrimary`, the comment in 15, each answer under a hairline, and the
/// reply as a filled capsule.
public struct SHPhoneCommentThread: View {
    let number: Int
    let author: String
    let age: String
    let note: String?
    let text: String
    let entries: [SHCommentEntry]
    @Binding var reply: String
    let onResolve: (() -> Void)?
    let onReply: (() -> Void)?
    @FocusState private var replyFocused: Bool

    public init(number: Int, author: String, age: String, note: String? = nil, text: String, entries: [SHCommentEntry] = [],
                reply: Binding<String>, onResolve: (() -> Void)? = nil, onReply: (() -> Void)? = nil) {
        self.number = number
        self.author = author
        self.age = age
        self.note = note
        self.text = text
        self.entries = entries
        _reply = reply
        self.onResolve = onResolve
        self.onReply = onReply
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SHPhoneDesignMetrics.threadRadius)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                SHCommentPin(number, size: .card)
                Text(author).font(.shSans(SHPhoneDesignMetrics.threadAuthor, .semibold)).foregroundStyle(sh.textPrimary)
                Text([age, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.shSans(SHPhoneDesignMetrics.threadAuthor))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let onResolve {
                    Button(action: onResolve) {
                        Text("Resolve").font(.shSans(SHPhoneDesignMetrics.threadAuthor, .medium)).foregroundStyle(sh.textPrimary)
                            .frame(minHeight: SH.Height.touch).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            phoneText(text)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: SHDesignMetrics.entrySpacing) {
                    (Text(entry.author).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
                        + Text(" · \(entry.age)").foregroundStyle(sh.textTertiary))
                        .font(.shSans(SHPhoneDesignMetrics.cardMetaSize))
                    phoneText(entry.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SHDesignMetrics.entryGap)
                .overlay(alignment: .top) { SHHairline() }
            }
            if let onReply {
                TextField("Reply…", text: $reply, prompt: Text("Reply…").foregroundStyle(sh.textTertiary), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.shSans(SHPhoneDesignMetrics.threadText))
                    .foregroundStyle(sh.textPrimary)
                    .focused($replyFocused)
                    .submitLabel(.send)
                    .onSubmit(onReply)
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.s)
                    .frame(minHeight: SHPhoneDesignMetrics.replyHeight)
                    .background(sh.bgSelected, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { replyFocused = true }
                    .padding(.top, SH.Space.xs)
            }
        }
        .padding(.vertical, SHPhoneDesignMetrics.threadPaddingVertical)
        .padding(.horizontal, SHPhoneDesignMetrics.threadPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHPhoneDesignMetrics.threadRadius, line: sh.lineSubtle, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment by \(author)")
    }

    private func phoneText(_ text: String) -> some View {
        Text(text)
            .shText(size: SHPhoneDesignMetrics.threadText, lineHeight: SHPhoneDesignMetrics.threadLineHeight)
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
