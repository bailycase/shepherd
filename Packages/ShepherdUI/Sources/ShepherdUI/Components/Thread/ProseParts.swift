import SwiftUI
import ImageIO

// MARK: Images

/// An image in prose. A local file this device can read (`nwProseFileRoot` set: the agent's
/// files are here) draws as a thumbnail within `proseImageMaxWidth` × `proseImageMaxHeight`,
/// radius 8 with a hairline `lineSubtle` border, and opens in the default app on click. Anything
/// else is a chip (the attachment chip's anatomy with the `photo` glyph): a remote URL is never
/// fetched, only opened in the browser from its chip, and a file on another machine names itself.
struct NWProseImageView: View {
    let image: NWProseImage
    @Environment(\.nwProseFileRoot) private var root
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    var body: some View {
        let source = NWProseImageSource(image.source, root: root)
        Group {
            if case .file(let url) = source, let cg = thumbnail ?? NWProseThumbnails.cached(url) {
                Button { openURL(url) } label: {
                    Image(decorative: cg, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(CGFloat(cg.width) / displayScale, NWThreadMetrics.proseImageMaxWidth),
                               maxHeight: min(CGFloat(cg.height) / displayScale, NWThreadMetrics.proseImageMaxHeight),
                               alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                }
                .buttonStyle(.plain)
                .nwFocusRing(radius: NW.Radius.m)
                .help(url.path)
                .accessibilityLabel(image.alt.isEmpty ? url.lastPathComponent : image.alt)
                .accessibilityAddTraits(.isImage)
            } else {
                chip(source)
            }
        }
        .task(id: source) {
            guard case .file(let url) = source, NWProseThumbnails.cached(url) == nil else { return }
            thumbnail = await NWProseThumbnails.load(url, pixels: NWThreadMetrics.proseImageMaxWidth * displayScale)
        }
    }

    @ViewBuilder private func chip(_ source: NWProseImageSource) -> some View {
        let label = NWProseImageChip(name: image.alt.isEmpty ? source.name : image.alt, detail: source.detail)
        if case .web(let url) = source {
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
                .nwFocusRing(radius: NW.Radius.s)
                .help(url.absoluteString)
                .accessibilityHint("Opens the image in your browser")
        } else {
            label.help(image.source)
        }
    }
}

/// Where an image in prose lives, and whether this device may draw it.
enum NWProseImageSource: Hashable {
    /// A file this device can read.
    case file(URL)
    /// A web image: never fetched, opened in the browser on request.
    case web(URL)
    /// Anything else: a file on the agent's machine (a remote agent), a `data:` URL, or text
    /// that is not a URL.
    case unavailable(String)

    init(_ source: String, root: URL?) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https": self = .web(url)
            case "file": self = root == nil ? .unavailable(url.path) : .file(url)
            default: self = .unavailable(trimmed)
            }
            return
        }
        guard let root else { self = .unavailable(trimmed); return }
        let path = trimmed.removingPercentEncoding ?? trimmed
        if path.hasPrefix("/") {
            self = .file(URL(fileURLWithPath: path))
        } else if path.hasPrefix("~/") {
            self = .file(URL.homeDirectory.appending(path: String(path.dropFirst(2))))
        } else {
            self = .file(root.appending(path: path))
        }
    }

    /// The file or URL's last component: "shot.png".
    var name: String {
        switch self {
        case .file(let url), .web(let url): url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case .unavailable(let text): (text as NSString).lastPathComponent
        }
    }

    /// The host a web image is on; nothing for a file.
    var detail: String? {
        if case .web(let url) = self { return url.host() }
        return nil
    }
}

/// An image that is not drawn: the `photo` glyph, its name, and its host, 26pt with a 1px
/// `lineStrong` line and radius 6, as an attachment chip.
struct NWProseImageChip: View {
    let name: String
    let detail: String?

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Image(systemName: "photo")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            Text(name).foregroundStyle(nw.textPrimary).lineLimit(1).truncationMode(.middle)
            if let detail {
                Text(detail).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
            }
        }
        .font(.nwSans(12))
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWThreadMetrics.attachmentHeight)
        .nwBorder(nw.lineStrong, radius: NW.Radius.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image, \(name)")
    }
}

/// Thumbnails of local images, decoded off the main actor at the size they are drawn (ImageIO
/// never decodes the full image) and kept for the session.
@MainActor
enum NWProseThumbnails {
    private static var values: [URL: CGImage] = [:]

    static func cached(_ url: URL) -> CGImage? { values[url] }

    static func load(_ url: URL, pixels: CGFloat) async -> CGImage? {
        let image = await Task.detached(priority: .utility) { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(pixels),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(SendableImage.init)
        }.value
        guard let image else { return nil }
        if values.count > 64 { values.removeAll(keepingCapacity: true) }
        values[url] = image.value
        return image.value
    }

    private struct SendableImage: @unchecked Sendable {
        let value: CGImage
    }
}

// MARK: Disclosure

/// `<details>`: a 10pt chevron and the summary in body medium, the whole line a button; open,
/// the blocks inside sit 12pt past a 2pt `lineStrong` rule, as expanded thinking does. With
/// nothing inside, the summary is a plain line: its chevron's place stays, empty, and nothing
/// opens.
struct NWProseDetails<Code: View>: View {
    let summary: AttributedString
    let blocks: [NWProseBlock]
    let depth: Int
    let code: (String, String?) -> Code
    @State private var open: Bool
    @Environment(\.nwProseSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` starts it open (previews).
    init(summary: AttributedString, blocks: [NWProseBlock], depth: Int, open: Bool = false, code: @escaping (String, String?) -> Code) {
        self.summary = summary
        self.blocks = blocks
        self.depth = depth
        self.code = code
        _open = State(initialValue: open)
    }

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            if blocks.isEmpty {
                label(expandable: false)
            } else {
                Button {
                    withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { open.toggle() }
                } label: {
                    label(expandable: true)
                }
                .buttonStyle(.plain)
                .nwFocusRing(radius: NW.Radius.xs)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
            if open, !blocks.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.l) {
                    NWProseBlocks(blocks: blocks, nested: true, depth: depth, code: code)
                }
                .padding(.leading, NW.Space.l)
                .overlay(alignment: .leading) { nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
                .nwTransition(.disclosure)
            }
        }
    }

    private func label(expandable: Bool) -> some View {
        let nw = Color.nw
        return HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
            NWThreadChevron(isExpanded: open, shown: expandable).foregroundStyle(nw.textSecondary)
            Text(summary).font(.nw(.body, weight: .medium, size: size)).foregroundStyle(nw.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
        .frame(minHeight: expandable ? NW.Height.touch : nil)
        #endif
        .contentShape(Rectangle())
    }
}

// MARK: Footnotes

/// The message's notes after a hairline: each number in caption tertiary where a list's
/// marker sits, and its text in caption `textSecondary`.
struct NWProseFootnotes: View {
    let notes: [NWProseFootnote]

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            NWHairline().padding(.bottom, NW.Space.xs)
            ForEach(notes, id: \.number) { note in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(note.number)").font(.nw(.caption)).foregroundStyle(nw.textTertiary).monospacedDigit()
                        .frame(width: NWThreadMetrics.listIndent - NW.Space.s, alignment: .trailing)
                        .padding(.trailing, NW.Space.s)
                    Text(note.text).nwText(.caption).foregroundStyle(nw.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
