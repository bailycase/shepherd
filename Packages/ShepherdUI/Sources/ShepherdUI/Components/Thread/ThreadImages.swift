import SwiftUI

// Images in the thread (ThreadImageOpen, ThreadImagesSent, ThreadImagesReceived boards): the thumbnail both the user's
// sent images and the agent's local images draw, the group above a sent bubble, and the full-thread viewer. Value inputs
// only: the app decodes, owns the open state and runs the actions.

public enum NWImageMetrics {
    /// The viewer's scrim over the blurred thread: `bgBase` at the board's 94% opacity.
    public static let scrimOpacity = 0.94
    /// The viewer's previous and next buttons.
    public static let navButton: CGFloat = 36
    /// The chevron inside it.
    public static let navGlyph: CGFloat = 14
    /// The shadow under the open image: the board's `0 12 32` in `bgBase` at 60%.
    public static let imageShadowOpacity = 0.6
    public static let imageShadowRadius: CGFloat = NW.Space.xxxl / 2
    /// The open image fits the room between the buttons and this much less than the body is tall (the board's 724pt image in
    /// a 772pt body at 1440×900: one `xxl` above and below it).
    public static let imageReserve: CGFloat = 2 * NW.Space.xxl
    /// The board's open image height at 1440×900; smaller windows reduce it further.
    public static let imageMaxHeight: CGFloat = 724
    /// The viewer decodes an image to at most this many pixels on its long edge.
    public static let viewerPixels: CGFloat = 4096
    /// The viewer's toolbar content stays in a column this wide, centred (the thread's 820pt measure), so a wide window does
    /// not throw the name to one corner and the buttons to the other. The band behind it still runs the window's width.
    public static let toolbarMaxWidth: CGFloat = 820
    /// A thumbnail's caption sits this far under it.
    public static let captionGap = NW.Space.xs
}

/// How an image fits its box: its pixels at the screen's scale, scaled down (never up) to fit, aspect kept.
public enum NWImageFit {
    public static func size(pixels: CGSize, scale: CGFloat, within box: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return box }
        let natural = CGSize(width: pixels.width / max(scale, 1), height: pixels.height / max(scale, 1))
        let factor = min(1, box.width / natural.width, box.height / natural.height)
        return CGSize(width: (natural.width * factor).rounded(), height: (natural.height * factor).rounded())
    }
}

/// One image as a thumbnail: radius 8, a 1px `lineSubtle` line (`lineStrong` on hover), and a button that opens it. The
/// accessibility label names the file and its pixels ("Open checkout-iphone.png, 1170 by 2532").
public struct NWImageThumb: View {
    let image: Image
    let size: CGSize
    let label: String
    let open: () -> Void
    @State private var hovering = false

    public init(image: Image, size: CGSize, label: String, open: @escaping () -> Void) {
        self.image = image
        self.size = size
        self.label = label
        self.open = open
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: open) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .background(nw.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(hovering ? nw.lineStrong : nw.lineSubtle, radius: NW.Radius.m)
                .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .nwFocusRing(radius: NW.Radius.m)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }
}

/// An image the user sent, for the group above its bubble.
public struct NWSentImage: Identifiable {
    public let id: String
    public let name: String
    public let thumbnail: Image
    public let pixels: CGSize

    public init(id: String, name: String, thumbnail: Image, pixels: CGSize) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.pixels = pixels
    }

    /// "Open checkout-iphone.png, 1170 by 2532".
    public var openLabel: String { "Open \(name), \(Int(pixels.width)) by \(Int(pixels.height))" }
}

/// A sent message's images, trailing above its bubble: each within 240×180 at its own aspect, 6pt apart, wrapping
/// within 560pt (ThreadImagesSent).
public struct NWSentImages: View {
    let images: [NWSentImage]
    let open: (Int) -> Void
    @Environment(\.displayScale) private var displayScale

    public init(_ images: [NWSentImage], open: @escaping (Int) -> Void) {
        self.images = images
        self.open = open
    }

    public var body: some View {
        let box = CGSize(width: NWThreadMetrics.sentImageMaxWidth, height: NWThreadMetrics.sentImageMaxHeight)
        NWFlowLayout(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                NWImageThumb(image: image.thumbnail, size: NWImageFit.size(pixels: image.pixels, scale: displayScale, within: box),
                             label: image.openLabel) { open(index) }
            }
        }
        .frame(maxWidth: NWThreadMetrics.sentImagesMaxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(images.count == 1 ? "1 image you sent" : "\(images.count) images you sent")
    }
}

// MARK: Viewer

/// What the viewer shows for the image it is open on.
public struct NWImageViewerContent {
    public var name: String
    /// "1170 × 2532 · PNG · 1.4 MB".
    public var detail: String
    /// "1 of 2"; nil for a single image.
    public var position: String?
    /// Where it came from: "Sent by you", "From the agent".
    public var origin: String
    /// Nil while it decodes.
    public var image: Image?
    /// Its size in pixels, once known: the viewer fits the image to it.
    public var pixels: CGSize?
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Add to message is offered; `addUnavailable` says why not (as its tooltip).
    public var canAdd: Bool
    public var addUnavailable: String?
    /// While set (the original is still being read, or could not be), Copy, Add to message and Show in Finder are disabled
    /// with this as their tooltip: they never act on a lossy preview.
    public var actionsWaitFor: String?

    public init(name: String, detail: String, position: String? = nil, origin: String, image: Image? = nil, pixels: CGSize? = nil,
                canGoBack: Bool = false,
                canGoForward: Bool = false, canAdd: Bool = true, addUnavailable: String? = nil, actionsWaitFor: String? = nil) {
        self.actionsWaitFor = actionsWaitFor
        self.name = name
        self.detail = detail
        self.position = position
        self.origin = origin
        self.image = image
        self.pixels = pixels
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.canAdd = canAdd
        self.addUnavailable = addUnavailable
    }
}

public struct NWImageViewerActions {
    public var copy: () -> Void
    public var add: () -> Void
    public var reveal: () -> Void
    public var previous: () -> Void
    public var next: () -> Void
    public var close: () -> Void

    public init(copy: @escaping () -> Void, add: @escaping () -> Void, reveal: @escaping () -> Void,
                previous: @escaping () -> Void, next: @escaping () -> Void, close: @escaping () -> Void) {
        self.copy = copy
        self.add = add
        self.reveal = reveal
        self.previous = previous
        self.next = next
        self.close = close
    }
}

/// An image open at full size over the whole thread (ThreadImageOpen): a 44pt header with the name, its size and type,
/// "1 of N", Copy, Add to message, Show in Finder and Close; the image fitted between round previous and next buttons;
/// "Sent by you · Esc to close" at the foot. ← → step, Esc closes.
public struct NWImageViewer: View {
    let content: NWImageViewerContent
    let actions: NWImageViewerActions
    /// What the window's controls take from the toolbar's leading edge (the window controls sit over the column when the
    /// sidebar is not docked): the toolbar starts after it.
    let leadingInset: CGFloat
    @FocusState private var focused: Bool
    @State private var copied = false
    @Environment(\.displayScale) private var displayScale

    public init(content: NWImageViewerContent, actions: NWImageViewerActions, leadingInset: CGFloat = 0) {
        self.content = content
        self.actions = actions
        self.leadingInset = leadingInset
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            header
            // The body: previous, the image and next sit together in the middle (the board's centred row, `xl` apart, `xxl` of
            // room around), never pushed to the window's edges.
            GeometryReader { box in
                let room = CGSize(width: box.size.width - 2 * (NWImageMetrics.navButton + NW.Space.xl),
                                  height: min(NWImageMetrics.imageMaxHeight, box.size.height - NWImageMetrics.imageReserve))
                let fitted = content.pixels.map { NWImageFit.size(pixels: $0, scale: displayScale, within: room) }
                    ?? CGSize(width: min(room.width, room.height), height: room.height)
                HStack(spacing: NW.Space.xl) {
                    step("chevron.left", label: "Previous image", enabled: content.canGoBack, action: actions.previous)
                    Group {
                        if let image = content.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                                .accessibilityLabel(content.name)
                                .accessibilityAddTraits(.isImage)
                        } else {
                            nw.bgSunken
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                    .shadow(color: nw.bgBase.opacity(NWImageMetrics.imageShadowOpacity), radius: NWImageMetrics.imageShadowRadius, y: NW.Space.l)
                    step("chevron.right", label: "Next image", enabled: content.canGoForward, action: actions.next)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(NW.Space.xxl)
            Text("\(content.origin) · Esc to close")
                .font(.nw(.mono)).foregroundStyle(nw.textTertiary)
                .padding(.bottom, NW.Space.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(nw.bgBase.opacity(NWImageMetrics.scrimOpacity))
        .contentShape(Rectangle())
        // The keys live on a view of their own: focus on the container would put `isFocused` on every button's ring.
        .background {
            Color.clear
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.escape) { actions.close(); return .handled }
                .onKeyPress(.leftArrow) { guard content.canGoBack else { return .ignored }; actions.previous(); return .handled }
                .onKeyPress(.rightArrow) { guard content.canGoForward else { return .ignored }; actions.next(); return .handled }
                .accessibilityHidden(true)
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image: \(content.name)")
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        // Full buttons while they fit beside the name; icons alone (named for VoiceOver, tooltips say what they do) when
        // the column is narrow or the text is large, so nothing is cut off.
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset, height: 1)
            ViewThatFits(in: .horizontal) {
                toolbar(labels: true)
                toolbar(labels: false)
            }
            .frame(maxWidth: NWImageMetrics.toolbarMaxWidth)
            .padding(.horizontal, NW.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .frame(height: NWToolbarMetrics.height)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func toolbar(labels: Bool) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            Text(content.name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Text(content.detail).font(.nw(.code)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize()
                .layoutPriority(1)
            if let position = content.position {
                Text(position).font(.nw(.code)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize()
                    .layoutPriority(1)
            }
            Spacer(minLength: NW.Space.l)
            Button {
                actions.copy()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: { action(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc", labels) }
                .buttonStyle(.nw(.ghost))
                .disabled(content.actionsWaitFor != nil)
                .nwHelp(content.actionsWaitFor ?? "Copy image")
                .accessibilityLabel("Copy image")
            Button(action: actions.add) { action("Add to message", "plus", labels) }
                .buttonStyle(.nw(.ghost))
                .disabled(!content.canAdd || content.actionsWaitFor != nil)
                .nwHelp(content.actionsWaitFor ?? (content.canAdd ? "Attach this image to your next message" : content.addUnavailable ?? ""))
                .accessibilityLabel("Add to message")
            Button(action: actions.reveal) { action("Show in Finder", "folder", labels) }
                .buttonStyle(.nw(.ghost))
                .disabled(content.actionsWaitFor != nil)
                .nwHelp(content.actionsWaitFor ?? "Show in Finder")
                .accessibilityLabel("Show in Finder")
            Button(action: actions.close) { Image(systemName: "xmark") }
                .buttonStyle(.nwIcon(bordered: true))
                .nwHelp("Close")
                .accessibilityLabel("Close")
        }
        .layoutPriority(0)
    }

    @ViewBuilder private func action(_ title: String, _ symbol: String, _ labels: Bool) -> some View {
        if labels { Label(title, systemImage: symbol).lineLimit(1).fixedSize() } else { Image(systemName: symbol) }
    }

    /// The round previous and next buttons: 36pt, `bgRaised` with a `lineSubtle` line, the board's `iv-round`; 40% when disabled.
    private func step(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: NWImageMetrics.navGlyph, weight: .medium))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: NWImageMetrics.navButton, height: NWImageMetrics.navButton)
                .background(Color.nw.bgRaised, in: Circle())
                .nwBorder(Color.nw.lineSubtle, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .nwFocusRingCircle()
        .nwEnabledOpacity(enabled)
        .disabled(!enabled)
        .nwTouchTarget(height: NWImageMetrics.navButton, width: NWImageMetrics.navButton)
        .accessibilityLabel(label)
    }
}
