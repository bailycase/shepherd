import SwiftUI
import ImageIO

/// Markdown paths have no scheme; Launch Services needs an absolute file URL, not a relative URL.
enum SHProseLink {
    static func destination(_ url: URL, root: URL?) -> URL? {
        guard url.scheme == nil || url.isFileURL else { return url }
        // A remote agent's path must never open a same-named file on this device.
        guard let root else { return nil }
        if url.isFileURL { return url }
        guard url.host == nil, !url.path.isEmpty else { return nil }
        let path = (url.path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.absoluteURL
    }
}

// MARK: Images

/// An image in prose. A local file this device can read (`shProseFileRoot` set: the agent's
/// files are here) draws as a thumbnail within `proseImageMaxWidth` × `proseImageMaxHeight`,
/// radius 8 with a hairline `lineSubtle` border, and opens in the default app on click. Anything
/// else is a chip (the attachment chip's anatomy with the `photo` glyph): a remote URL is never
/// fetched, only opened in the browser from its chip, and a file on another machine names itself.
struct SHProseImageView: View {
    let image: SHProseImage
    @Environment(\.shProseFileRoot) private var root
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: (url: URL, image: CGImage)?

    var body: some View {
        let source = SHProseImageSource(image.source, root: root)
        Group {
            if case .file(let url) = source,
               let cg = (thumbnail?.url == url ? thumbnail?.image : nil) ?? SHProseThumbnails.cached(url) {
                Button { openURL(url) } label: {
                    Image(decorative: cg, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(CGFloat(cg.width) / displayScale, SHThreadMetrics.proseImageMaxWidth),
                               maxHeight: min(CGFloat(cg.height) / displayScale, SHThreadMetrics.proseImageMaxHeight),
                               alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                }
                .buttonStyle(.plain)
                .shFocusRing(radius: SH.Radius.m)
                .help(url.path)
                .accessibilityLabel(image.alt.isEmpty ? url.lastPathComponent : image.alt)
                .accessibilityAddTraits(.isImage)
            } else {
                chip(source)
            }
        }
        .task(id: source) {
            guard case .file(let url) = source, SHProseThumbnails.cached(url) == nil else { return }
            let loaded = await SHProseThumbnails.load(url, pixels: SHThreadMetrics.proseImageMaxWidth * displayScale)
            guard !Task.isCancelled else { return }
            thumbnail = loaded.map { (url, $0) }
        }
    }

    @ViewBuilder private func chip(_ source: SHProseImageSource) -> some View {
        let label = SHProseImageChip(name: image.alt.isEmpty ? source.name : image.alt, detail: source.detail)
        if case .web(let url) = source {
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
                .shFocusRing(radius: SH.Radius.s)
                .help(url.absoluteString)
                .accessibilityHint("Opens the image in your browser")
        } else {
            label.help(image.source)
        }
    }
}

/// Where an image in prose lives, and whether this device may draw it.
enum SHProseImageSource: Hashable {
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
struct SHProseImageChip: View {
    let name: String
    let detail: String?

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.s) {
            Image(systemName: "photo")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(name).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
            if let detail {
                Text(detail).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
        }
        .font(.shSans(12))
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHThreadMetrics.attachmentHeight)
        .shBorder(sh.lineStrong, radius: SH.Radius.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image, \(name)")
    }
}

/// Thumbnails of local images, decoded off the main actor at the size they are drawn (ImageIO
/// never decodes the full image) and kept for the session.
@MainActor
enum SHProseThumbnails {
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
struct SHProseDetails<Code: View>: View {
    let summary: AttributedString
    let blocks: [SHProseBlock]
    let path: [Int]
    let depth: Int
    let voice: SHProseVoice
    let code: (String, String?) -> Code
    @State private var open: Bool
    @Environment(\.shProseSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` starts it open (previews).
    init(summary: AttributedString, blocks: [SHProseBlock], path: [Int] = [], depth: Int, voice: SHProseVoice = .reply, open: Bool = false,
         code: @escaping (String, String?) -> Code) {
        self.summary = summary
        self.blocks = blocks
        self.path = path
        self.depth = depth
        self.voice = voice
        self.code = code
        _open = State(initialValue: open)
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if blocks.isEmpty {
                label(expandable: false)
            } else {
                Button {
                    withAnimation(SH.Motion.disclosure.animation(reduceMotion: reduceMotion)) { open.toggle() }
                } label: {
                    label(expandable: true)
                }
                .buttonStyle(.plain)
                .shFocusRing(radius: SH.Radius.xs)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
            if open, !blocks.isEmpty {
                VStack(alignment: .leading, spacing: voice == .thinking ? SH.Space.m : SH.Space.l) {
                    SHProseBlocks(blocks: blocks, path: path, nested: true, depth: depth, voice: voice, code: code)
                }
                .padding(.leading, SH.Space.l)
                .overlay(alignment: .leading) { sh.lineStrong.frame(width: SHThreadMetrics.ruleWidth) }
                .shTransition(.disclosure)
            }
        }
    }

    private func label(expandable: Bool) -> some View {
        let sh = Color.sh
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
            SHThreadChevron(isExpanded: open, shown: expandable).foregroundStyle(sh.textSecondary)
            Group {
                if voice == .thinking {
                    Text(summary).font(SHThinking.headingFont).italic().foregroundStyle(sh.textSecondary)
                } else {
                    Text(summary).font(.sh(.body, weight: .medium, size: size)).foregroundStyle(sh.textPrimary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
        .frame(minHeight: expandable ? SH.Height.touch : nil)
        #endif
        .contentShape(Rectangle())
    }
}

// MARK: Footnotes

/// The message's notes after a hairline: each number in caption tertiary where a list's
/// marker sits, and its text in caption `textSecondary`.
struct SHProseFootnotes: View {
    let notes: [SHProseFootnote]
    @Environment(\.shProseFileRoot) private var fileRoot
    @Environment(\.shProseFileLinks) private var fileLinks

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            SHHairline().padding(.bottom, SH.Space.xs)
            ForEach(notes, id: \.number) { note in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(note.number)").font(.sh(.caption)).foregroundStyle(sh.textTertiary).monospacedDigit()
                        .frame(width: SHThreadMetrics.listIndent - SH.Space.s, alignment: .trailing)
                        .padding(.trailing, SH.Space.s)
                    SHProseFileLinks.prose(note.text, root: fileRoot, actions: fileLinks).shText(.caption).foregroundStyle(sh.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(SHFileLinkTargets(actions: SHProseFileLinks.targets(note.text, root: fileRoot, actions: fileLinks)))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
