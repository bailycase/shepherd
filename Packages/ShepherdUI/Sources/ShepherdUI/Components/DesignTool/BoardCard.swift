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
    /// Clicking the picture (the pane opens it); nil leaves it still.
    let open: (() -> Void)?
    let actions: Actions

    public init(design: String, board: String, meta: [String], note: String? = nil, size: CGSize?, picture: Picture,
                open: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
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
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(spacing: 0) {
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
                        .help("Open beside the thread").accessibilityLabel("Open \(board) beside the thread")
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
        let M = SHBoardCardMetrics.self
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m + SH.Space.xxs) {
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
                        .font(.shMono(M.metaSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: SH.Space.m)
                HStack(spacing: SH.Space.xs) { actions }
            }
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

public enum SHBoardCardMetrics {
    /// The field's padding around the picture.
    public static let fieldPadding: CGFloat = 16
    /// The tallest a picture is drawn in the thread.
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
