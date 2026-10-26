import SwiftUI

/// The picture in a thread (ThreadImagesSent, ThreadImagesReceived): a button that opens the image full size.
/// `Content` is what the host's bytes have become: not here yet, a picture, or something that cannot be drawn. The
/// size is known before any byte arrives (the snapshot names it), so a picture lands without moving what is around it.
public struct SHThreadImage: View {
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
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        // A failed picture's one control is Retry (the box would open nothing); every other state opens the image.
        Button(action: { if case .failed = content { retry?() } else { open() } }) {
            ZStack {
                sh.bgSunken
                switch content {
                case .picture(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .loading:
                    // Nothing moves in the thread but text: the field holds the picture's place, at its size.
                    Color.sh.bgHover.opacity(SHThreadImageMetrics.loadingFill).accessibilityHidden(true)
                case .failed:
                    VStack(spacing: SH.Space.s) {
                        Image(systemName: "photo").imageScale(.large).foregroundStyle(sh.textTertiary)
                        Text("Couldn't load").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                        if retry != nil { Text("Retry").font(.sh(.caption, weight: .medium)).foregroundStyle(sh.textSecondary) }
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shBorder(sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .shFocusRing(radius: SH.Radius.m)
        .help(name)
        .accessibilityLabel(label)
        .disabled({ if case .failed = content { retry == nil } else { false } }())
    }
}

/// An image the thread does not draw: a web image (never fetched) or one the host does not offer. A chip with the
/// `photo` glyph, its name, and why it is not here ("web image · not loaded"). `open` makes it a button (a web
/// image opens in the browser); nil leaves it plain text.
public struct SHThreadImageChip: View {
    let name: String
    let detail: String
    let open: (() -> Void)?

    public init(name: String, detail: String, open: (() -> Void)? = nil) {
        self.name = name
        self.detail = detail
        self.open = open
    }

    public var body: some View {
        let sh = Color.sh
        let label = HStack(spacing: SH.Space.s) {
            Image(systemName: "photo").imageScale(.small).foregroundStyle(sh.textSecondary).accessibilityHidden(true)
            Text(name).font(.sh(.mono)).foregroundStyle(open == nil ? sh.textSecondary : sh.textPrimary).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHThreadMetrics.attachmentHeight)
        .shBorder(sh.lineStrong, radius: SH.Radius.s)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        if let open {
            Button(action: open) { label }.buttonStyle(.plain).shFocusRing(radius: SH.Radius.s)
                .accessibilityLabel("\(name), \(detail)")
        } else {
            label.accessibilityElement(children: .ignore).accessibilityLabel("\(name), \(detail)")
        }
    }
}

/// A picture with a caption under it (ThreadImagesReceived): the alt text the agent wrote.
public struct SHThreadImageCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

public enum SHThreadImageMetrics {
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
