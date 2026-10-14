import SwiftUI
import ImageIO

// MARK: Images

/// A run of images in prose (ThreadImagesReceived): consecutive `![alt](src)` lines draw side by side, wrapping, 12pt
/// between lines and 8pt between neighbours. A local file this device can read (`nwProseFileRoot` set: the agent's files
/// are here) is a thumbnail within `proseImageMaxWidth` × `proseImageMaxHeight` with its alt text as a caption, and
/// opens in the image viewer (`nwImageOpener`; the default app where there is none). Anything else is a chip: a remote
/// URL is never fetched, only opened in the browser from its chip, and a file on another machine names itself.
struct NWProseImageGroup: View {
    let images: [NWProseImage]
    @Environment(\.nwProseFileRoot) private var root

    /// A run of images in order: thumbnails flow together, and an image that is a chip takes a row of its own (the board's
    /// Grafana link under the two images).
    private enum Row {
        case thumbnails([Int])
        case chip(Int)
    }

    var body: some View {
        let sources = images.map { NWProseImageSource($0.source, root: root) }
        let files: [URL] = sources.compactMap { if case .file(let url) = $0 { url } else { nil } }
        VStack(alignment: .leading, spacing: NW.Space.l) {
            ForEach(Array(Self.rows(sources).enumerated()), id: \.offset) { _, row in
                switch row {
                case .thumbnails(let indexes):
                    NWFlowLayout(spacing: NW.Space.m, lineSpacing: NW.Space.l) {
                        ForEach(indexes, id: \.self) { index in view(index, sources, files) }
                    }
                case .chip(let index):
                    view(index, sources, files)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func view(_ index: Int, _ sources: [NWProseImageSource], _ files: [URL]) -> some View {
        NWProseImageView(image: images[index], source: sources[index], files: files,
                         fileIndex: files.firstIndex { sources[index] == .file($0) } ?? 0)
    }

    private static func rows(_ sources: [NWProseImageSource]) -> [Row] {
        var rows: [Row] = []
        for (index, source) in sources.enumerated() {
            if case .file = source {
                if case .thumbnails(let run)? = rows.last { rows[rows.count - 1] = .thumbnails(run + [index]) } else { rows.append(.thumbnails([index])) }
            } else {
                rows.append(.chip(index))
            }
        }
        return rows
    }
}

struct NWProseImageView: View {
    let image: NWProseImage
    let source: NWProseImageSource
    /// Every readable local image in its run, and this one's place among them: what the viewer pages through.
    let files: [URL]
    let fileIndex: Int
    @Environment(\.nwImageOpener) private var opener
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: (key: NWProseThumbnails.Key, image: CGImage)?

    var body: some View {
        Group {
            if case .file(let url) = source,
               let cg = (thumbnail?.key == NWProseThumbnails.key(url) ? thumbnail?.image : nil) ?? NWProseThumbnails.cached(url) {
                let size = NWImageFit.size(pixels: CGSize(width: cg.width, height: cg.height), scale: displayScale,
                                           within: CGSize(width: NWThreadMetrics.proseImageMaxWidth, height: NWThreadMetrics.proseImageMaxHeight))
                VStack(alignment: .leading, spacing: NWImageMetrics.captionGap) {
                    NWImageThumb(image: Image(decorative: cg, scale: displayScale), size: size,
                                 label: "Open \(image.alt.isEmpty ? url.lastPathComponent : image.alt)") {
                        if let opener { opener.open(files, fileIndex) } else { openURL(url) }
                    }
                    .help(url.path)
                    if !image.alt.isEmpty {
                        Text(image.alt).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: NWThreadMetrics.proseImageSlot, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The board's wrapper: every image has the same slot, so a narrow one leaves the room a wide one would take.
                .frame(width: NWThreadMetrics.proseImageSlot, alignment: .leading)
            } else {
                chip
            }
        }
        // Keyed on the file's revision too: an overwrite at the same path loads again.
        .task(id: source.file.map(NWProseThumbnails.key)) {
            guard case .file(let url) = source, NWProseThumbnails.cached(url) == nil else { return }
            let loaded = await NWProseThumbnails.load(url, pixels: NWThreadMetrics.proseImageMaxWidth * displayScale)
            guard !Task.isCancelled else { return }
            thumbnail = loaded.map { (NWProseThumbnails.key(url), $0) }
        }
    }

    @ViewBuilder private var chip: some View {
        let label = NWProseImageChip(name: source.chipName(alt: image.alt), detail: source.detail)
        if case .web(let url) = source {
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
                .nwFocusRing(radius: NW.Radius.s)
                .help("Shepherd never loads web images. Opens in your browser.")
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
            case "file":
                // file://host/path names another machine's file: only an empty host or localhost is this one.
                let host = url.host(percentEncoded: false)?.lowercased() ?? ""
                self = root == nil || !(host.isEmpty || host == "localhost") ? .unavailable(url.path) : .file(url)
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

    /// The file, when this is one this device reads.
    var file: URL? { if case .file(let url) = self { url } else { nil } }

    /// The file or URL's last component: "shot.png".
    var name: String {
        switch self {
        case .file(let url), .web(let url): url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case .unavailable(let text): (text as NSString).lastPathComponent
        }
    }

    /// What a chip says after the name: a web image is "web image · not loaded".
    var detail: String? {
        if case .web = self { return "web image · not loaded" }
        return nil
    }

    /// A web image's chip names where it is (host and path), the privacy fact; others use their alt text, then their name.
    func chipName(alt: String) -> String {
        if case .web(let url) = self, let host = url.host() { return host + url.path }
        return alt.isEmpty ? name : alt
    }
}

/// An image that is not drawn: the `photo` glyph, its name, and what it is, 26pt with a 1px
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
                Text(detail).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).lineLimit(1)
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

/// Thumbnails of local images, decoded off the main actor at the size they are drawn (ImageIO never decodes the full
/// image) and kept for the session. A file is keyed by its path *and* its revision (modification date and size), so an
/// image the agent overwrites at the same path draws anew instead of the old pixels.
@MainActor
enum NWProseThumbnails {
    struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
    }

    private static var values: [Key: CGImage] = [:]

    /// The file's current revision: read on every look, a stat call. A `URL` caches the resource values it has read, so
    /// the read goes through a fresh one (a cached value would hide an overwrite).
    static func key(_ url: URL) -> Key {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Key(url: url, modified: values?.contentModificationDate, size: values?.fileSize)
    }

    static func cached(_ url: URL) -> CGImage? { values[key(url)] }

    static func load(_ url: URL, pixels: CGFloat) async -> CGImage? {
        let key = key(url)
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
        values[key] = image.value
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
    let voice: NWProseVoice
    let code: (String, String?) -> Code
    @State private var open: Bool
    @Environment(\.nwProseSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` starts it open (previews).
    init(summary: AttributedString, blocks: [NWProseBlock], depth: Int, voice: NWProseVoice = .reply, open: Bool = false,
         code: @escaping (String, String?) -> Code) {
        self.summary = summary
        self.blocks = blocks
        self.depth = depth
        self.voice = voice
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
                VStack(alignment: .leading, spacing: voice == .thinking ? NW.Space.m : NW.Space.l) {
                    NWProseBlocks(blocks: blocks, nested: true, depth: depth, voice: voice, code: code)
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
            Group {
                if voice == .thinking {
                    Text(summary).font(NWThinking.headingFont).italic().foregroundStyle(nw.textSecondary)
                } else {
                    Text(summary).font(.nw(.body, weight: .medium, size: size)).foregroundStyle(nw.textPrimary)
                }
            }
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
