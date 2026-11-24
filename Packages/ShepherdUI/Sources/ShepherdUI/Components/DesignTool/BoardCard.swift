import SwiftUI

/// A board an agent shows in its thread (ThreadBoardShown, ThreadBoardStale): the picture of the
/// board on a sunken field, then a footer with the nib, "design › **board**" over its mono meta
/// ("Checkout · 560 × 410 · revision 13"), the card's actions on the right, and an optional note
/// under it ("The design moved on since the agent showed this…"). Takes its words and picture as
/// values: nothing here reads a design.
public struct SHBoardCard<Actions: View>: View {
    public enum Picture {
        case loading
        case picture(Image)
        /// The copy has no picture to draw.
        case missing
    }

    let design: String
    let board: String
    let meta: [String]
    let note: String?
    /// The board's size in points: the picture's box before it lands, so nothing moves.
    let size: CGSize?
    let picture: Picture
    /// Clicking the picture (the viewer opens it); nil leaves it still.
    let open: (() -> Void)?
    let actions: Actions
    /// The Mac card's footer name, where it isn't "design, board", and its head over a board the
    /// agent drew (GXBoardDraft); the phone's card has neither.
    let title: String?
    let header: SHBoardCardHeader?

    public init(design: String, board: String, meta: [String], note: String? = nil, size: CGSize?, picture: Picture,
                open: (() -> Void)? = nil, title: String? = nil, header: SHBoardCardHeader? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.header = header
        self.design = design
        self.board = board
        self.meta = meta
        self.note = note
        self.size = size
        self.picture = picture
        self.open = open
        self.actions = actions()
    }

    public var body: some View {
        #if os(macOS)
        macCard
        #else
        phoneCard
        #endif
    }

    private var phoneCard: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        return VStack(spacing: 0) {
            field
            SHHairline()
            footer
        }
        .frame(maxWidth: .infinity)
        .background(sh.bgWindow, in: shape)
        .clipShape(shape)
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
    }

#if os(macOS)
    /// The Mac card as GXBoardShown, GXBoardDraft, GXBoardChange and GXBoardStale draw it: a raised
    /// card (radius 14, `lift`), its head when the agent drew the board, the picture on a field
    /// of its own, the note over the footer, then the footer line with the actions.
    private var macCard: some View {
        let sh = Color.sh
        let M = SHBoardCardMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xl)
        return VStack(alignment: .leading, spacing: 0) {
            if let header {
                HStack(spacing: M.headSpacing) {
                    Text(header.label).foregroundStyle(sh.textSecondary)
                    Text(header.tag).foregroundStyle(sh.textTertiary)
                }
                .font(.sh(.caption))
                .lineLimit(1)
                .padding(M.headInset)
            }
            macField
                .padding(.horizontal, M.fieldMargin)
                .padding(.top, M.fieldMargin)
            if let note {
                Text(note)
                    .font(.shSans(M.noteSize, .regular))
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(M.noteInset)
            }
            SHBoardFooterLine(design: design, board: board, meta: meta, title: title) { actions }
                .padding(M.footerInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Color.clear.shLift(shape) }
        .shBorder(sh.lineSubtle, in: shape)
        .accessibilityElement(children: .contain)
    }

    /// The picture on the sunken-by-a-hair field: 22pt over and under it, 16pt beside it.
    private var macField: some View {
        let sh = Color.sh
        let M = SHBoardCardMetrics.self
        return GeometryReader { proxy in
            let box = M.box(size, widest: proxy.size.width - 2 * M.macFieldSide)
            let drawn = Group {
                switch picture {
                case .picture(let image): image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                case .loading: sh.bgHover.opacity(SHThreadImageMetrics.loadingFill)
                case .missing:
                    Image(systemName: "photo").imageScale(.large).foregroundStyle(sh.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(sh.bgHover)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: M.pictureRadius))
            .shadow(color: .black.opacity(M.pictureShadow), radius: M.pictureShadowRadius, y: M.pictureShadowOffset)
            Group {
                if let open {
                    Button(action: open) { drawn }.buttonStyle(.plain).shFocusRing(radius: M.pictureRadius)
                        .help("Open full size").accessibilityLabel("Open \(board) full size")
                } else {
                    drawn.accessibilityLabel(board)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: M.box(size, widest: .infinity).height + 2 * M.macFieldTop)
        .background(sh.bgHover, in: RoundedRectangle(cornerRadius: M.fieldRadius))
    }
#endif

    /// The picture, fitted inside the field and never past its own size.
    private var field: some View {
        let sh = Color.sh
        let M = SHBoardCardMetrics.self
        return GeometryReader { proxy in
            let box = M.box(size, widest: proxy.size.width - 2 * M.fieldPadding)
            let drawn = Group {
                switch picture {
                case .picture(let image): image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                case .loading: sh.bgHover.opacity(SHThreadImageMetrics.loadingFill)
                case .missing:
                    Image(systemName: "photo").imageScale(.large).foregroundStyle(sh.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(sh.bgHover)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(sh.lineSubtle, radius: SH.Radius.xs)
            Group {
                if let open {
                    Button(action: open) { drawn }.buttonStyle(.plain).shFocusRing(radius: SH.Radius.xs)
                        .help("Open full size").accessibilityLabel("Open \(board) full size")
                } else {
                    drawn.accessibilityLabel(board)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: M.box(size, widest: .infinity).height + 2 * M.fieldPadding)
        .background(sh.bgSunken)
    }

    private var footer: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            SHBoardFooterLine(design: design, board: board, meta: meta) { actions }
            if let note {
                Text(note)
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Mac card's head over a board the agent drew (GXBoardDraft's "Drew a board  Draft").
public struct SHBoardCardHeader: Equatable, Sendable {
    public var label: String
    public var tag: String

    public init(label: String, tag: String) {
        self.label = label
        self.tag = tag
    }
}

/// A board the agent drew, before you add it (ThreadBoardDraft's "Draft", ThreadBoardChange's
/// "Changed"): a lantern word on its tint.
public struct SHBoardBadge: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.caption, weight: .semibold))
            .foregroundStyle(Color.sh.lanternText)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.s)
            .frame(height: SHBoardCardMetrics.badgeHeight)
            .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .fixedSize()
            .padding(.trailing, SH.Space.s)
    }
}

/// A board's footer line, in its card and under the pane (ThreadBoardShown, ThreadBoardPane): the
/// nib, "design › **board**" over its mono meta, and the actions on the right.
public struct SHBoardFooterLine<Actions: View>: View {
    let design: String
    let board: String
    let meta: [String]
    let actions: Actions
    /// The Mac line's name where it isn't "design, board".
    let title: String?

    public init(design: String, board: String, meta: [String], title: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.design = design
        self.board = board
        self.meta = meta
        self.title = title
        self.actions = actions()
    }

    /// The actions beside the name where everything fits untruncated, else on their own row under it (a phone's card).
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.m + SH.Space.xxs) {
                name
                Spacer(minLength: SH.Space.m)
                HStack(spacing: Self.actionSpacing) { actions }
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                name
                HStack(spacing: Self.actionSpacing) { actions }
            }
        }
    }

    private static var actionSpacing: CGFloat {
        #if os(macOS)
        0
        #else
        SH.Space.xs
        #endif
    }

    @ViewBuilder private var name: some View {
        #if os(macOS)
        macName
        #else
        phoneName
        #endif
    }

#if os(macOS)
    /// GXBoardShown's footer: the nib, the name in 13 over its meta in 12 tertiary, words 2pt apart.
    private var macName: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.l) {
            Image(systemName: "pencil.tip")
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title ?? (board == design ? board : design + ", " + board))
                    .font(.sh(.ui))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta.joined(separator: ", "))
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
#endif

    private var phoneName: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: "pencil.tip")
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                (Text(design + " › ").foregroundStyle(sh.textSecondary)
                    + Text(board).fontWeight(.semibold).foregroundStyle(sh.textPrimary))
                    .font(.sh(.ui))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta.joined(separator: " · "))
                    .font(.shMono(SHBoardCardMetrics.metaSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#if os(macOS)
/// A board card's action as GXBoardShown draws it: text, no pill; the main one in 13 medium
/// ink, a quiet one (Discard, Open in design beside a stronger link) in secondary. A hover
/// fill shows it is a button.
public struct SHBoardLinkStyle: ButtonStyle {
    let quiet: Bool

    public init(quiet: Bool = false) { self.quiet = quiet }

    public func makeBody(configuration: Configuration) -> some View {
        SHBoardLink(configuration: configuration, quiet: quiet)
    }
}

extension ButtonStyle where Self == SHBoardLinkStyle {
    public static func shBoardLink(quiet: Bool = false) -> SHBoardLinkStyle { SHBoardLinkStyle(quiet: quiet) }
}

private struct SHBoardLink: View {
    let configuration: ButtonStyleConfiguration
    let quiet: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        configuration.label
            .font(.sh(.ui, weight: quiet ? .regular : .medium))
            .foregroundStyle(quiet ? sh.textSecondary : sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, SHBoardCardMetrics.linkPadding)
            .frame(minHeight: SH.Height.controlM)
            .background(configuration.isPressed ? sh.bgSelected : hovering && enabled ? sh.bgHover : Color.clear, in: shape)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: SH.Radius.s)
    }
}
#endif

/// A board open beside the thread, in the side pane's Design tab (ThreadBoardPane): the board's
/// name as a tag with zoom out, the zoom, zoom in and Open in design on the right; the board on
/// the sunken canvas, fitted until you zoom; and its footer line with the pane's actions.
public struct SHBoardPane<Actions: View>: View {
    let design: String
    let board: String
    let meta: [String]
    /// The board's size in points.
    let size: CGSize?
    let picture: Image?
    let open: () -> Void
    let actions: Actions
    /// The footer line under the canvas (Discard and Apply on a board the agent drew); a shown
    /// board has none (GXBoardPane).
    let footer: Bool
    /// Nil fits the board in the canvas.
    @State private var zoom: CGFloat?

    public init(design: String, board: String, meta: [String], size: CGSize?, picture: Image?, open: @escaping () -> Void,
                footer: Bool = true, @ViewBuilder actions: () -> Actions) {
        self.footer = footer
        self.design = design
        self.board = board
        self.meta = meta
        self.size = size
        self.picture = picture
        self.open = open
        self.actions = actions()
    }

    public var body: some View {
        #if os(macOS)
        macPane
        #else
        oldPane
        #endif
    }

#if os(macOS)
    /// The Mac pane as GXBoardPane draws it: the design's name, the board and its revision, and
    /// Open in design over a canvas of its own (radius 10, 12pt in from the pane); the zoom is a
    /// pill in the canvas's corner.
    private var macPane: some View {
        let sh = Color.sh
        return GeometryReader { proxy in
            let M = SHBoardCardMetrics.self
            let canvas = CGSize(width: proxy.size.width - 2 * M.paneMargin,
                                height: max(proxy.size.height - M.paneHeader - M.paneMargin - (footer ? M.paneFooter : 0), 1))
            let fit = M.fitScale(size, in: canvas)
            let scale = zoom ?? fit
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.m) {
                    Text(design)
                        .font(.sh(.ui))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(([board] + meta.suffix(1)).joined(separator: ", "))
                        .font(.sh(.caption))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Button("Open in design", action: open).buttonStyle(.shBoardLink())
                }
                .padding(M.paneHeaderInset)
                .frame(height: M.paneHeader)
                ScrollView([.horizontal, .vertical]) {
                    let drawn = CGSize(width: (size?.width ?? M.tallest) * scale, height: (size?.height ?? M.tallest) * scale)
                    Group {
                        if let picture { picture.resizable().interpolation(.high) } else { sh.bgHover }
                    }
                    .frame(width: drawn.width, height: drawn.height)
                    .clipShape(RoundedRectangle(cornerRadius: M.pictureRadius))
                    .shadow(color: .black.opacity(M.pictureShadow), radius: M.pictureShadowRadius, y: M.pictureShadowOffset)
                    .padding(M.panePadding)
                    .frame(minWidth: canvas.width, minHeight: canvas.height)
                }
                .scrollIndicators(.automatic)
                .frame(width: canvas.width, height: canvas.height)
                .background(sh.bgHover, in: RoundedRectangle(cornerRadius: M.fieldRadius))
                .clipShape(RoundedRectangle(cornerRadius: M.fieldRadius))
                .overlay(alignment: .bottomTrailing) { zoomPill(scale) }
                .padding(.bottom, M.paneMargin)
                if footer {
                    SHBoardFooterLine(design: design, board: board, meta: meta) { actions }
                        .padding(.horizontal, SH.Space.l)
                        .frame(height: M.paneFooter)
                }
            }
        }
        .background(sh.bgWindow)
    }

    private func zoomPill(_ scale: CGFloat) -> some View {
        let sh = Color.sh
        let M = SHBoardCardMetrics.self
        let shape = Capsule()
        return HStack(spacing: 0) {
            Button { zoom = M.zoomed(scale, by: -1) } label: { Image(systemName: "minus") }
                .buttonStyle(.shIcon).help("Zoom out").accessibilityLabel("Zoom out").disabled(scale <= M.zoomRange.lowerBound)
            Text("\(Int((scale * 100).rounded()))%")
                .font(.shMono(M.metaSize))
                .foregroundStyle(sh.textTertiary)
                .monospacedDigit()
                .frame(minWidth: M.zoomLabelWidth)
                .onTapGesture { zoom = nil }
                .help("Fit")
            Button { zoom = M.zoomed(scale, by: 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.shIcon).help("Zoom in").accessibilityLabel("Zoom in").disabled(scale >= M.zoomRange.upperBound)
        }
        .padding(SH.Space.xxs)
        .background { Color.clear.shLift(shape) }
        .shBorder(sh.lineSubtle, in: shape)
        .padding(SH.Space.m)
    }
#endif

    private var oldPane: some View {
        let sh = Color.sh
        return GeometryReader { proxy in
            let M = SHBoardCardMetrics.self
            let canvas = CGSize(width: proxy.size.width, height: max(proxy.size.height - M.paneBars, 1))
            let fit = M.fitScale(size, in: canvas)
            let scale = zoom ?? fit
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.xs) {
                    Text(board)
                        .font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, SH.Space.m)
                        .frame(height: SH.Height.controlM)
                        .background(sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                    Spacer(minLength: SH.Space.m)
                    Button { zoom = M.zoomed(scale, by: -1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.shIcon).help("Zoom out").accessibilityLabel("Zoom out").disabled(scale <= M.zoomRange.lowerBound)
                    Text("\(Int((scale * 100).rounded()))%")
                        .font(.shMono(SHBoardCardMetrics.metaSize))
                        .foregroundStyle(sh.textTertiary)
                        .monospacedDigit()
                        .frame(minWidth: M.zoomLabelWidth)
                        .onTapGesture { zoom = nil }
                        .help("Fit")
                    Button { zoom = M.zoomed(scale, by: 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.shIcon).help("Zoom in").accessibilityLabel("Zoom in").disabled(scale >= M.zoomRange.upperBound)
                    Button("Open in design", action: open).buttonStyle(.sh(.ghost, size: .s))
                }
                .padding(.horizontal, SH.Space.m)
                .frame(height: M.paneToolbar)
                SHHairline()
                ScrollView([.horizontal, .vertical]) {
                    let drawn = CGSize(width: (size?.width ?? M.tallest) * scale, height: (size?.height ?? M.tallest) * scale)
                    Group {
                        if let picture { picture.resizable().interpolation(.high) } else { sh.bgHover }
                    }
                    .frame(width: drawn.width, height: drawn.height)
                    .shadow(color: .black.opacity(M.boardShadow), radius: SH.Space.m, y: SH.Space.xxs)
                    .padding(M.panePadding)
                    .frame(minWidth: canvas.width, minHeight: canvas.height)
                }
                .scrollIndicators(.automatic)
                .background(sh.bgSunken)
                SHHairline()
                SHBoardFooterLine(design: design, board: board, meta: meta) { actions }
                    .padding(.horizontal, SH.Space.l)
                    .frame(height: M.paneFooter)
            }
        }
        .background(sh.bgWindow)
    }
}

public enum SHBoardCardMetrics {
    /// The pane's toolbar and footer (ThreadBoardPane).
    public static let badgeHeight: CGFloat = 20
    public static let paneToolbar: CGFloat = 45
    public static let paneFooter: CGFloat = 52
    static let paneBars: CGFloat = paneToolbar + paneFooter
    /// The pane's canvas keeps this much room around the board.
    public static let panePadding: CGFloat = 24
    public static let zoomLabelWidth: CGFloat = 40
    public static let zoomRange: ClosedRange<CGFloat> = 0.1...4
    public static let zoomStep: CGFloat = 1.25
    public static let boardShadow: Double = 0.18
    /// The scale that fits a board of `size` points inside `canvas`, less the pane's padding, and
    /// never past its own size.
    public static func fitScale(_ size: CGSize?, in canvas: CGSize) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return 1 }
        let room = CGSize(width: canvas.width - 2 * panePadding, height: canvas.height - 2 * panePadding)
        return min(max(min(room.width / size.width, room.height / size.height, 1), zoomRange.lowerBound), zoomRange.upperBound)
    }
    /// One step in or out from `scale`, kept in `zoomRange`.
    public static func zoomed(_ scale: CGFloat, by steps: Int) -> CGFloat {
        min(max(scale * pow(zoomStep, CGFloat(steps)), zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The field's padding around the picture.
    public static let fieldPadding: CGFloat = 16
    /// The Mac card (GXBoardShown…): the field 10pt in from the card at radius 10, 22pt over and
    /// under its picture and 16pt beside it; the picture at radius 6 on a 1pt shadow.
    public static let fieldMargin: CGFloat = 10
    public static let fieldRadius: CGFloat = 10
    public static let macFieldTop: CGFloat = 22
    public static let macFieldSide: CGFloat = 16
    public static let pictureRadius: CGFloat = SH.Radius.s - 1
    public static let pictureShadow: Double = 0.14
    public static let pictureShadowRadius: CGFloat = 1.5
    public static let pictureShadowOffset: CGFloat = 1
    /// The head: its words 8pt apart, 10pt over them and 14pt in.
    public static let headSpacing: CGFloat = SH.Space.m
    public static let headInset = EdgeInsets(top: 10, leading: 14, bottom: 0, trailing: 14)
    /// The note over the footer (12.5), the footer (10 over, 12 under; 8pt in at the right, where
    /// a link's own 6pt makes up the 14), and a link's side padding.
    public static let noteSize: CGFloat = 12.5
    public static let noteInset = EdgeInsets(top: 10, leading: 14, bottom: 0, trailing: 14)
    public static let footerInset = EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 8)
    public static let linkPadding: CGFloat = SH.Space.s
    /// GXBoardPane: the head is 40pt, the canvas 12pt in from the pane's sides and foot.
    public static let paneHeader: CGFloat = 40
    public static let paneHeaderInset = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 10)
    public static let paneMargin: CGFloat = SH.Space.l
    /// The tallest a picture is drawn in the thread; a pane's board before its size is known.
    public static let tallest: CGFloat = 256
    public static let metaSize: CGFloat = 11
    /// A board of `size` points, fitted inside `widest` × `tallest` and never past its own size;
    /// a square of `tallest` before the size is known.
    public static func box(_ size: CGSize?, widest: CGFloat) -> CGSize {
        guard let size, size.width > 0, size.height > 0 else { return CGSize(width: tallest, height: tallest) }
        let scale = min(max(widest, 1) / size.width, tallest / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

#Preview("Board card") {
    VStack(spacing: SH.Space.xl) {
        SHBoardCard(design: "Checkout redesign", board: "A · Funnel first", meta: ["Checkout", "560 × 410", "revision 13"],
                    size: CGSize(width: 560, height: 410), picture: .loading, open: {}) {
            Button("Open in design") {}.buttonStyle(.sh(.ghost, size: .s))
        }
        SHBoardCard(design: "Checkout redesign", board: "A · Funnel first", meta: ["Checkout", "560 × 410", "shown at revision 13"],
                    note: "The design moved on since the agent showed this. It shows what the agent saw.",
                    size: CGSize(width: 560, height: 410), picture: .missing) {
            Button("Show v14") {}.buttonStyle(.sh(.secondary, size: .s))
            Button("Open in design") {}.buttonStyle(.sh(.ghost, size: .s))
        }
    }
    .padding()
    .frame(width: 820)
}
