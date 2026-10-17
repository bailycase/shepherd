import SwiftUI

/// An image open full size (ThreadImageOpen): a bar across the top with the name, its facts and
/// "1 of 2", then Copy, Add to message, Show in Finder and close; the picture centered under a
/// scrim, ‹ › at its sides when there is more than one, and "Sent by you · Esc to close" along
/// the bottom. A control the caller does not supply is not drawn. While the bytes load the
/// picture's place is a `bgSunken` field; if they cannot be read it says so in place of the picture.
public struct NWImageViewer: View {
    public enum Content {
        case loading
        case picture(Image)
        /// A live view that takes the whole room and pans and zooms itself (a Mermaid diagram).
        case diagram(AnyView)
        case failed(String)
    }

    let name: String
    let facts: String
    let position: String?
    let content: Content
    let caption: String
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let copy: (() -> Void)?
    let addToMessage: (() -> Void)?
    let showInFinder: (() -> Void)?
    let retry: (() -> Void)?
    let close: () -> Void
    /// How far the window's own controls reach into the bar from the leading edge (the traffic lights, 70pt, unless the window is
    /// full screen): the bar's content starts after them.
    let leadingInset: CGFloat
    /// The picture's size in pixels, when known: the picture is then drawn at exactly its fitted size, so the arrows sit beside
    /// the photo, not at the window's edges (a resizable image takes the whole width it is offered, whatever its shape).
    let pixels: CGSize?

    /// `facts` is the mono line after the name ("1170 × 2532 · PNG · 1.4 MB"); `position` is "1 of 2"
    /// (nil for one image); `caption` is the line along the bottom.
    public init(name: String, facts: String, position: String? = nil, content: Content, caption: String,
                previous: (() -> Void)? = nil, next: (() -> Void)? = nil, copy: (() -> Void)? = nil,
                addToMessage: (() -> Void)? = nil, showInFinder: (() -> Void)? = nil, retry: (() -> Void)? = nil,
                leadingInset: CGFloat = 0, pixels: CGSize? = nil, close: @escaping () -> Void) {
        self.leadingInset = leadingInset
        self.pixels = pixels
        self.name = name
        self.facts = facts
        self.position = position
        self.content = content
        self.caption = caption
        self.previous = previous
        self.next = next
        self.copy = copy
        self.addToMessage = addToMessage
        self.showInFinder = showInFinder
        self.retry = retry
        self.close = close
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            // 44pt, then its 1px `lineSubtle` rule below it (the board's header is 44pt with its border outside).
            bar
            NWHairline()
            // The picture and, when there is more than one image, a round ‹ › 16pt either side of it, the three centred together (the board
            // does not pin the arrows to the window's edges). The arrow with nowhere to go is drawn disabled, as the board's first image has it.
            GeometryReader { room in
                HStack(spacing: NW.Space.xl) {
                    if position != nil { arrow("chevron.left", label: "Previous image", action: previous) }
                    picture(fitting: room.size)
                    if position != nil { arrow("chevron.right", label: "Next image", action: next) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The board's 36pt footer, its line centred.
            Text(caption)
                .font(.nw(.mono))
                .foregroundStyle(nw.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: NWImageViewerMetrics.footer)
        }
        // The thread stays visible beneath, dimmed by `imageScrim` (`bgBase` at 94%), not blacked out.
        .background(nw.imageScrim)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Image viewer, \(name)")
    }

    /// The bar (ThreadImageOpen): 44pt on `bgWindow` over a `lineSubtle` hairline, 12pt at each side and between its parts; the name in `ui`
    /// semibold, its facts and "1 of 2" in `mono` `textTertiary`, then Copy, Add to message and Show in Finder as 28pt ghost buttons with 14pt
    /// glyphs, and the 28pt close circle on `lineStrong`.
    private var bar: some View {
        // The band runs the window's width; its content is one centred column (`barMaxWidth`) after the window controls, so a wide
        // window does not throw the name into one corner and the buttons into the other. When the labelled buttons do not fit
        // beside the name (a narrow window, large text) they become icons; their names stay for VoiceOver and the tooltip.
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset, height: 1)
            ViewThatFits(in: .horizontal) {
                barContent(labels: true)
                barContent(labels: false)
            }
            .frame(maxWidth: NWImageViewerMetrics.barMaxWidth)
            .padding(.horizontal, NW.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .frame(height: NWImageViewerMetrics.bar)
        .background(Color.nw.bgWindow)
    }

    private func barContent(labels: Bool) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            Text(name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1).truncationMode(.middle)
                // The name gives way first: the facts and "1 of 2" are what the bar is for.
                .layoutPriority(-1)
            Text(facts).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize()
            if let position { Text(position).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize() }
            Spacer(minLength: NW.Space.l)
            if let copy { action("Copy", "doc.on.doc", labels, copy) }
            if let addToMessage { action("Add to message", "plus", labels, addToMessage) }
            if let showInFinder { action("Show in Finder", "folder", labels, showInFinder) }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: NWImageViewerMetrics.closeGlyph, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: NWImageViewerMetrics.close, height: NWImageViewerMetrics.close)
                    .nwBorder(nw.lineStrong, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .nwFocusRingCircle()
            .accessibilityLabel("Close")
        }
    }

    private func action(_ title: String, _ symbol: String, _ labels: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: symbol).font(.system(size: NWImageViewerMetrics.glyph, weight: .medium))
                if labels { Text(title).lineLimit(1).fixedSize() }
            }
        }
        .buttonStyle(.nw(.ghost, size: .m))
        .accessibilityLabel(title)
        .nwHelp(title)
    }

    /// The round ‹ › beside the picture: 36pt, `bgRaised` with a `lineSubtle` ring, a 14pt chevron.
    private func arrow(_ symbol: String, label: String, action: (() -> Void)?) -> some View {
        let nw = Color.nw
        return Button(action: { action?() }) {
            Image(systemName: symbol)
                .font(.system(size: NWImageViewerMetrics.glyph, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWImageViewerMetrics.arrow, height: NWImageViewerMetrics.arrow)
                .background(nw.bgRaised, in: Circle())
                .nwBorder(nw.lineSubtle, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .nwEnabledOpacity(action != nil)
        .nwFocusRingCircle()
        .accessibilityLabel(label)
    }

    /// The room the picture may take: what is left of the body after the arrows and their gaps, the 24pt at each side, and the
    /// 48pt above and below (the board's 1170 × 2532 picture is 724pt tall in a 900pt window).
    private func fitted(in body: CGSize) -> CGSize? {
        guard let pixels, pixels.width > 0, pixels.height > 0 else { return nil }
        let arrows = position != nil ? 2 * (NWImageViewerMetrics.arrow + NW.Space.xl) : 0
        let room = CGSize(width: max(1, body.width - arrows - 2 * NW.Space.xxl),
                          height: max(1, body.height - 2 * NWImageViewerMetrics.pictureInset))
        let scale = min(room.width / pixels.width, room.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(.down), height: (pixels.height * scale).rounded(.down))
    }

    @ViewBuilder private func picture(fitting body: CGSize) -> some View {
        let nw = Color.nw
        switch content {
        case .picture(let image):
            let size = fitted(in: body)
            image.resizable().aspectRatio(contentMode: .fit)
                .frame(width: size?.width, height: size?.height)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                // The board's shadow: 0 12 32, `bgBase` at 60%.
                .shadow(color: nw.bgBase.opacity(NWImageViewerMetrics.shadowOpacity), radius: NWImageViewerMetrics.shadowBlur / 2,
                        y: NWImageViewerMetrics.shadowOffset)
                // The board's picture leaves 48pt above and below it; without its pixel size it is offered that much less height.
                .padding(.vertical, size == nil ? NWImageViewerMetrics.pictureInset : 0)
                .accessibilityLabel(name)
                .accessibilityAddTraits(.isImage)
        case .diagram(let view):
            view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(nw.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                .padding(.horizontal, NW.Space.xxl)
                .padding(.vertical, NW.Space.xxl)
        case .loading:
            RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.bgSunken)
                .frame(width: NWImageViewerMetrics.placeholderWidth, height: NWImageViewerMetrics.placeholderHeight)
                .overlay { ProgressView().controlSize(.small) }
                .accessibilityLabel("Loading \(name)")
        case .failed(let message):
            VStack(spacing: NW.Space.m) {
                Image(systemName: "exclamationmark.triangle").imageScale(.large).foregroundStyle(nw.failed).accessibilityHidden(true)
                Text(message).font(.nw(.ui)).foregroundStyle(nw.textPrimary).multilineTextAlignment(.center)
                if let retry { Button("Try again", action: retry).buttonStyle(.nw(.secondary, size: .s)) }
            }
            .padding(NW.Space.xxl)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(nw.lineStrong, radius: NW.Radius.m)
        }
    }
}

public enum NWImageViewerMetrics {
    /// The bar and the footer (ThreadImageOpen): 44 and 36.
    public static let bar: CGFloat = 44
    public static let footer: CGFloat = 36
    /// The bar's content stays in a column this wide (the thread's 820pt measure), centred, with 24pt of side room.
    public static let barMaxWidth: CGFloat = 820
    /// The close circle and the round ‹ › buttons: 28 and 36. Glyphs in the bar and beside the picture are 14; the close ✕ is 12.
    public static let close: CGFloat = 28
    public static let arrow: CGFloat = 36
    public static let glyph: CGFloat = 14
    /// The room above and below the picture, measured on the board.
    public static let pictureInset: CGFloat = 48
    public static let closeGlyph: CGFloat = 12
    /// The picture's shadow: offset 12, blur 32, `bgBase` at 60%.
    public static let shadowOffset: CGFloat = 12
    public static let shadowBlur: CGFloat = 32
    public static let shadowOpacity: Double = 0.6
    /// The field standing in for a picture while its bytes load.
    public static let placeholderWidth: CGFloat = 240
    public static let placeholderHeight: CGFloat = 320
}
