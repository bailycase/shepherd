import SwiftUI

/// The picture in a thread (ThreadImagesSent, ThreadImagesReceived): a button that opens the image full size.
/// `Content` is what the host's bytes have become: not here yet, a picture, or something that cannot be drawn. The
/// size is known before any byte arrives (the snapshot names it), so a picture lands without moving what is around it.
public struct NWThreadImage: View {
    public enum Content {
        case loading
        case picture(Image)
        case failed
    }

    let name: String
    let size: CGSize
    let content: Content
    let open: () -> Void
    let retry: (() -> Void)?

    /// `size` is the box in points. `open` opens it full size; `retry` is drawn on a failed one.
    public init(name: String, size: CGSize, content: Content, open: @escaping () -> Void, retry: (() -> Void)? = nil) {
        self.name = name
        self.size = size
        self.content = content
        self.open = open
        self.retry = retry
    }

    private var label: String {
        switch content {
        case .picture: "Open \(name), \(Int(size.width)) by \(Int(size.height))"
        case .loading: "Loading \(name)"
        case .failed: retry == nil ? "\(name) couldn't be loaded" : "Retry loading \(name)"
        }
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        // A failed picture's one control is Retry (the box would open nothing); every other state opens the image.
        Button(action: { if case .failed = content { retry?() } else { open() } }) {
            ZStack {
                nw.bgSunken
                switch content {
                case .picture(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .loading:
                    // Nothing moves in the thread but text: the field holds the picture's place, at its size.
                    Color.nw.bgHover.opacity(NWThreadImageMetrics.loadingFill).accessibilityHidden(true)
                case .failed:
                    VStack(spacing: NW.Space.s) {
                        Image(systemName: "photo").imageScale(.large).foregroundStyle(nw.textTertiary)
                        Text("Couldn't load").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                        if retry != nil { Text("Retry").font(.nw(.caption, weight: .medium)).foregroundStyle(nw.textSecondary) }
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .nwFocusRing(radius: NW.Radius.m)
        .help(name)
        .accessibilityLabel(label)
        .disabled({ if case .failed = content { retry == nil } else { false } }())
    }
}

/// An image the thread does not draw: a web image (never fetched) or one the host does not offer. A chip with the
/// `photo` glyph, its name, and why it is not here ("web image · not loaded"). `open` makes it a button (a web
/// image opens in the browser); nil leaves it plain text.
public struct NWThreadImageChip: View {
    let name: String
    let detail: String
    let open: (() -> Void)?

    public init(name: String, detail: String, open: (() -> Void)? = nil) {
        self.name = name
        self.detail = detail
        self.open = open
    }

    public var body: some View {
        let nw = Color.nw
        let label = HStack(spacing: NW.Space.s) {
            Image(systemName: "photo").imageScale(.small).foregroundStyle(nw.textSecondary).accessibilityHidden(true)
            Text(name).font(.nw(.mono)).foregroundStyle(open == nil ? nw.textSecondary : nw.textPrimary).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWThreadMetrics.attachmentHeight)
        .nwBorder(nw.lineStrong, radius: NW.Radius.s)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        if let open {
            Button(action: open) { label }.buttonStyle(.plain).nwFocusRing(radius: NW.Radius.s)
                .accessibilityLabel("\(name), \(detail)")
        } else {
            label.accessibilityElement(children: .ignore).accessibilityLabel("\(name), \(detail)")
        }
    }
}

/// A picture with a caption under it (ThreadImagesReceived): the alt text the agent wrote.
public struct NWThreadImageCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

public enum NWThreadImageMetrics {
    /// How much of `bgHover` a loading picture's field takes over `bgSunken`.
    public static let loadingFill: Double = 0.6
    /// A sent image's longest side beside its bubble, and a received one's width (ThreadImagesSent, ThreadImagesReceived).
    public static let sentLongestSide: CGFloat = 180
    public static let sentWidest: CGFloat = 240
    public static let receivedWidest: CGFloat = 384
    public static let receivedTallest: CGFloat = 240
    /// A box for an image of `width` × `height` pixels, fitted inside `widest` × `tallest` and never past its own size.
    public static func box(width: Int?, height: Int?, widest: CGFloat, tallest: CGFloat) -> CGSize {
        guard let width, let height, width > 0, height > 0 else { return CGSize(width: widest, height: tallest) }
        let scale = min(widest / CGFloat(width), tallest / CGFloat(height), 1)
        return CGSize(width: (CGFloat(width) * scale).rounded(), height: (CGFloat(height) * scale).rounded())
    }
}
