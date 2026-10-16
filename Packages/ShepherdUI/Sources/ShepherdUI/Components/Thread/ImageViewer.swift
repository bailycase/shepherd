import SwiftUI

/// An image open over the thread: the picture centred on `sheetScrim`, ‹ › beside it when there is more than one, and one popover
/// pill under it holding "1 of 2", then Copy, Add to message, Show in Finder and close as icons. A click on the scrim closes it.
/// A control the caller does not supply is not drawn. While the bytes load the picture's place is a `bgSunken` field; if they
/// cannot be read it says so in place of the picture. The name and its facts are not drawn; VoiceOver reads them.
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
    /// The picture's size in pixels, when known: it is then drawn at exactly its fitted size, so the arrows and the pill sit
    /// against the photo, not at the window's edges.
    let pixels: CGSize?

    /// `facts` ("1170 × 2532 · PNG · 1.4 MB") and `caption` ("Sent by you · Esc to close") are spoken, not drawn; `position` is
    /// "1 of 2" (nil for one image).
    public init(name: String, facts: String, position: String? = nil, content: Content, caption: String,
                previous: (() -> Void)? = nil, next: (() -> Void)? = nil, copy: (() -> Void)? = nil,
                addToMessage: (() -> Void)? = nil, showInFinder: (() -> Void)? = nil, retry: (() -> Void)? = nil,
                pixels: CGSize? = nil, close: @escaping () -> Void) {
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
        let M = NWImageViewerMetrics.self
        GeometryReader { window in
            // The picture may take the window less `margin` all round, the arrows beside it, and the pill and its gap below it.
            let room = CGSize(width: max(1, window.size.width - 2 * M.margin - arrowsWidth),
                              height: max(1, window.size.height - 2 * M.margin - M.pill - NW.Space.l))
            ZStack {
                // A real button, so a click and VoiceOver's press both close it; Esc and the pill's close stay the keyboard's way.
                Button(action: close) { Color.nw.sheetScrim.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Close viewer")
                VStack(spacing: NW.Space.l) {
                    HStack(spacing: NW.Space.xl) {
                        if position != nil { arrow("chevron.left", label: "Previous image", action: previous) }
                        picture(size: shownSize(in: room))
                        if position != nil { arrow("chevron.right", label: "Next image", action: next) }
                    }
                    pill
                }
            }
            .frame(width: window.size.width, height: window.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Image viewer, \(name)")
        .accessibilityHint(caption)
    }

    private var arrowsWidth: CGFloat { position != nil ? 2 * (NWImageViewerMetrics.arrow + NW.Space.xl) : 0 }

    /// The popover pill: "1 of 2" in `mono` `textTertiary`, the actions as 28pt ghost icons, and the 28pt close circle, which
    /// sits 8pt inside the pill's round end.
    private var pill: some View {
        let nw = Color.nw
        let M = NWImageViewerMetrics.self
        return HStack(spacing: NW.Space.m) {
            if let position { Text(position).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize() }
            if let copy { action("Copy", "doc.on.doc", copy) }
            if let addToMessage { action("Add to message", "plus", addToMessage) }
            if let showInFinder { action("Show in Finder", "folder", showInFinder) }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: M.closeGlyph, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: M.close, height: M.close)
                    .nwBorder(nw.lineStrong, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .nwFocusRingCircle()
            .accessibilityLabel("Close")
        }
        .padding(.leading, position == nil ? NW.Space.m : NW.Space.l)
        .padding(.trailing, NW.Space.m)
        .frame(height: M.pill)
        .fixedSize()
        .nwPopover(radius: M.pill / 2)
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: NWImageViewerMetrics.glyph, weight: .medium))
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

    /// The picture's size in `room`: its fitted size (never enlarged), all of `room` for a diagram, or the placeholder's.
    private func shownSize(in room: CGSize) -> CGSize {
        if case .diagram = content { return room }
        guard let pixels, pixels.width > 0, pixels.height > 0 else {
            return CGSize(width: NWImageViewerMetrics.placeholderWidth, height: NWImageViewerMetrics.placeholderHeight)
        }
        let scale = min(1, room.width / pixels.width, room.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(.down), height: (pixels.height * scale).rounded(.down))
    }

    @ViewBuilder private func picture(size: CGSize) -> some View {
        let nw = Color.nw
        switch content {
        case .picture(let image):
            image.resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                .nwFloatShadow()
                .accessibilityLabel(name)
                .accessibilityValue(facts)
                .accessibilityAddTraits(.isImage)
        case .diagram(let view):
            view
                .frame(width: size.width, height: size.height)
                .background(nw.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                .nwFloatShadow()
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
    /// The thread left showing round the picture and its pill.
    public static let margin: CGFloat = 64
    /// The pill under the picture.
    public static let pill: CGFloat = 44
    /// The close circle and the round ‹ › buttons: 28 and 36. Glyphs in the pill and beside the picture are 14; the close ✕ is 12.
    public static let close: CGFloat = 28
    public static let arrow: CGFloat = 36
    public static let glyph: CGFloat = 14
    public static let closeGlyph: CGFloat = 12
    /// The field standing in for a picture while its bytes load.
    public static let placeholderWidth: CGFloat = 240
    public static let placeholderHeight: CGFloat = 320
}
