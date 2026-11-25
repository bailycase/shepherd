import SwiftUI

// Design references (DesignRefStates): the chip a thread shows for a design piece it was handed,
// the bigger preview a chip opens on hover, the thread's pin on the canvas with its note, and the
// toasts the canvas shows after Implement in a thread… or Copy reference. Everything here takes
// its words and pictures as values: nothing reads a design.

/// The boards' own measures for design references (DesignRefStates, RefChipHover, RefNoteBack).
public enum SHReferenceMetrics {
    // The phone's chip (the Mac's are the board* measures below)
    public static let chipPaddingLeading: CGFloat = 6
    public static let chipPaddingTrailing: CGFloat = 8
    public static let chipPaddingVertical: CGFloat = 6
    public static let chipRadius: CGFloat = 9
    public static let chipSpacing: CGFloat = 9
    /// A chip never grows past this; its design's name gives way first.
    public static let chipMaxWidth: CGFloat = 560
    public static let thumbnail = CGSize(width: 40, height: 26)
    public static let thumbnailRadius: CGFloat = 4
    public static let crumbSize: CGFloat = 12.5
    public static let crumbSpacing: CGFloat = 5
    public static let lineSpacing: CGFloat = 2
    public static let versionSize: CGFloat = 10.5
    public static let metaSize: CGFloat = 11
    public static let stateDot: CGFloat = 5
    public static let removeSize: CGFloat = 20
    public static let removeGlyph: CGFloat = 8
    public static let deletedGlyph: CGFloat = 10
    public static let deletedOpacity: Double = 0.75
    public static let dash: [CGFloat] = [3, 2]
    // A host's tag ("build-01")
    public static let hostTagHeight: CGFloat = 16
    public static let hostTagPadding: CGFloat = 5
    public static let hostTagSize: CGFloat = 10

    // MARK: The Mac (RefPasted, RefChipHover, RefNoteBack, RefCopied)
    // The chip (.gdz-ref): 44pt, its picture 48×34, on the composer's hover wash (raised in a bubble)
    public static let chipHeight: CGFloat = 44
    public static let boardChipPaddingLeading: CGFloat = 4
    public static let boardChipRadius: CGFloat = 10
    public static let boardChipSpacing: CGFloat = 10
    public static let chipRing: CGFloat = 1.5
    public static let boardThumbnail = CGSize(width: 48, height: 34)
    public static let boardThumbnailRadius: CGFloat = 6
    /// A picker row's picture (.gdz-ar).
    public static let rowThumbnail = CGSize(width: 46, height: 30)
    public static let rowThumbnailRadius: CGFloat = 5
    public static let boardCrumbSize: CGFloat = 13
    public static let crumbLine: CGFloat = 16
    public static let boardMetaSize: CGFloat = 12
    public static let boardRemoveGlyph: CGFloat = 9
    // The preview (.gdz-prev)
    public static let previewWidth: CGFloat = 340
    public static let previewPadding: CGFloat = 10
    public static let previewRadius: CGFloat = 14
    public static let previewTray: CGFloat = 150
    public static let previewTrayRadius: CGFloat = 8
    public static let previewPictureInset = CGSize(width: 24, height: 14)
    public static let previewPictureRadius: CGFloat = 5
    /// The picture's size in the tray: the preview's width less its padding and the inset on each side.
    public static let previewPicture = CGSize(width: 340 - 2 * 10 - 2 * 24, height: 150 - 2 * 14)
    public static let previewCrumbTop: CGFloat = 9
    public static let previewMetaTop: CGFloat = 2
    public static let previewInset: CGFloat = 2
    public static let previewMetaSize: CGFloat = 12
    public static let previewGap: CGFloat = 6
    public static let sectionTop: CGFloat = 10
    public static let changesPaddingVertical: CGFloat = 8
    public static let changesPaddingHorizontal: CGFloat = 10
    public static let changesRadius: CGFloat = 8
    public static let changesTitleSize: CGFloat = 12
    public static let changesLineSize: CGFloat = 12
    public static let changesLineSpacing: CGFloat = 3
    public static let getsTagHeight: CGFloat = 20
    public static let getsTagSize: CGFloat = 12
    public static let getsSpacing: CGFloat = 4
    public static let getsTagPadding: CGFloat = 6
    public static let footerSpacing: CGFloat = 16
    public static let footerPaddingTop: CGFloat = 8
    public static let linkSize: CGFloat = 13
    public static let linkGlyphSpacing: CGFloat = 5
    // The thread's pin and its note (.gdz-pin.th, .gdz-pop)
    public static let notePinRing: CGFloat = 1
    public static let notePinGlyph: CGFloat = 12
    public static let noteWidth: CGFloat = 300
    public static let notePaddingVertical: CGFloat = 12
    public static let notePaddingHorizontal: CGFloat = 14
    public static let noteRadius: CGFloat = 12
    public static let noteTextTop: CGFloat = 5
    public static let noteFooterTop: CGFloat = 10
    public static let noteMetaSize: CGFloat = 12
    public static let noteNameSize: CGFloat = 13
    public static let noteTextSize: CGFloat = 13
    public static let noteCodeSize: CGFloat = 12
    public static let noteTextSpacing: CGFloat = 4
    /// The note opens this far after its pin.
    public static let noteGap: CGFloat = 14
    // The toasts (.gdz-toast)
    /// The words wrap at this width, so the toast hugs them up to its 620pt (.gdz-toast).
    public static let toastMessageWidth: CGFloat = 500
    public static let toastMinHeight: CGFloat = 40
    public static let toastSpacing: CGFloat = 12
    public static let toastPadding: CGFloat = 8
    public static let toastPaddingLeading: CGFloat = 14
    public static let toastGlyph: CGFloat = 14
    public static let toastTextSize: CGFloat = 13
    public static let toastClose: CGFloat = 24
    /// The toast sits this far above the canvas's bottom edge.
    public static let toastBottom: CGFloat = 22
    // The agent's line
    public static let detailRowHeight: CGFloat = 18
    public static let detailRowGap: CGFloat = 3
    public static let detailLabelWidth: CGFloat = 40
    public static let detailColumnGap: CGFloat = 10
    public static let detailIndent: CGFloat = 5
    public static let detailRail: CGFloat = 14
    public static let detailSize: CGFloat = 12
}

/// A picture handed to a design reference's views: the image and what it shows, so a view
/// compares it by `id` and redraws only when another picture lands.
public struct SHReferenceImage: Equatable, @unchecked Sendable {
    public let id: String
    public let image: Image

    public init(id: String, image: Image) {
        self.id = id
        self.image = image
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// How a reference stands (DesignReferenceChip(ref, state:)): as sent; the design moved on since
/// (amber words, "updated since, now v26"); the design is gone (the chip dims and its picture
/// is a dashed trash tile); on another host (the host's name as a tag); or on a host that is
/// offline (the tag and the words in amber). Each carries its words.
public enum SHReferenceState: Equatable, Sendable {
    case current
    case updated(String)
    case deleted(String)
    case anotherHost(String)
    case hostOffline(host: String, words: String)
}

/// A reference's picture as a chip, a picker row or a sheet draws it: the image filling a
/// rounded tile with a faint ring, or the sunken tile while none is at hand. A deleted design's
/// is a dashed tile with a trash glyph.
public struct SHReferenceThumbnail: View, Equatable {
    let image: SHReferenceImage?
    let size: CGSize
    let radius: CGFloat
    let deleted: Bool

    public init(_ image: SHReferenceImage?, size: CGSize = SHReferenceMetrics.thumbnail, radius: CGFloat = SHReferenceMetrics.thumbnailRadius,
                deleted: Bool = false) {
        self.image = image
        self.size = size
        self.radius = radius
        self.deleted = deleted
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: radius)
        Group {
            if deleted {
                Image(systemName: "trash")
                    .font(.system(size: SHReferenceMetrics.deletedGlyph))
                    .foregroundStyle(sh.textTertiary)
                    .frame(width: size.width, height: size.height)
                    .shBorder(sh.lineStrong, in: shape, dash: SHReferenceMetrics.dash)
            } else if let image {
                image.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipShape(shape)
                    .overlay { Color.clear.shBorder(sh.lineStrong, in: shape) }
            } else {
                shape.fill(sh.bgSunken)
                    .frame(width: size.width, height: size.height)
                    .overlay { Color.clear.shBorder(sh.lineStrong, in: shape) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// design › board › element on one line (13): the parents in `textSecondary`, the piece last in
/// `textPrimary` semibold, `›` between in `textSecondary`. One line, so a long path gives way at
/// its end (the board's `.cr`). The phone's gives way at the design's name first.
struct SHReferenceCrumbs: View {
    let crumbs: [String]
    #if os(macOS)
    var size: CGFloat = SHReferenceMetrics.boardCrumbSize
    #else
    var size: CGFloat = SHReferenceMetrics.crumbSize
    #endif

    #if os(macOS)
    var body: some View {
        let sh = Color.sh
        var line = Text("")
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 { line = Text("\(line) › ") }
            let last = index == crumbs.count - 1
            line = Text("\(line)\(Text(crumb).fontWeight(last ? .semibold : .regular).foregroundStyle(last ? sh.textPrimary : sh.textSecondary))")
        }
        return line
            .font(.shSans(size))
            .foregroundStyle(sh.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
    #else
    var body: some View {
        let sh = Color.sh
        HStack(spacing: SHReferenceMetrics.crumbSpacing) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Text("›").foregroundStyle(sh.textTertiary) }
                let last = index == crumbs.count - 1
                Text(crumb)
                    .fontWeight(last ? .semibold : .regular)
                    .foregroundStyle(last ? sh.textPrimary : sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The design's name truncates first, then the board's; the piece holds on.
                    .layoutPriority(last ? 2 : Double(index))
            }
        }
        .font(.shSans(size))
    }
    #endif
}

/// A host's name as its small mono tag (build-01), amber when the host is offline.
public struct SHReferenceHostTag: View {
    let host: String
    let offline: Bool

    public init(_ host: String, offline: Bool = false) {
        self.host = host
        self.offline = offline
    }

    public var body: some View {
        Text(host)
            .font(.shMono(SHReferenceMetrics.hostTagSize))
            .foregroundStyle(offline ? Color.sh.lanternText : Color.sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SHReferenceMetrics.hostTagPadding)
            .frame(height: SHReferenceMetrics.hostTagHeight)
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
            .fixedSize()
    }
}

/// The reference chip (DesignReferenceChip): the only design UI a thread ever shows. A 48×34
/// picture, the breadcrumb, and under it the version and how the reference stands, in a 44pt
/// capsule on the hover wash (`raised`: on `bgRaised`, inside a sent message's bubble). In the
/// composer it has a remove button; in a sent message it opens the design. `highlighted` is its
/// hover ring, while its preview is open.
public struct SHDesignReferenceChip: View {
    let crumbs: [String]
    let version: String?
    let state: SHReferenceState
    let thumbnail: SHReferenceImage?
    let highlighted: Bool
    let raised: Bool
    let fills: Bool
    let remove: (() -> Void)?

    /// `fills`: as wide as it is offered, up to its most (a sent message's chip fills its bubble).
    public init(crumbs: [String], version: String?, state: SHReferenceState = .current, thumbnail: SHReferenceImage? = nil,
                highlighted: Bool = false, raised: Bool = false, fills: Bool = false, remove: (() -> Void)? = nil) {
        self.crumbs = crumbs
        self.version = version
        self.state = state
        self.thumbnail = thumbnail
        self.highlighted = highlighted
        self.raised = raised
        self.fills = fills
        self.remove = remove
    }

    private var deleted: Bool { if case .deleted = state { true } else { false } }

    #if os(macOS)
    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.boardChipRadius)
        HStack(spacing: M.boardChipSpacing) {
            SHReferenceThumbnail(thumbnail, size: M.boardThumbnail, radius: M.boardThumbnailRadius, deleted: deleted)
            VStack(alignment: .leading, spacing: 0) {
                SHReferenceCrumbs(crumbs: crumbs).frame(height: M.crumbLine)
                meta.frame(height: M.crumbLine)
            }
            .layoutPriority(1)
            if fills { Spacer(minLength: 0) }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: M.boardRemoveGlyph, weight: .semibold))
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: M.removeSize, height: M.removeSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, SH.Space.xs)
                .help("Remove")
                .accessibilityLabel("Remove")
            }
        }
        .padding(.leading, M.boardChipPaddingLeading)
        .padding(.trailing, M.chipPaddingTrailing)
        .frame(height: M.chipHeight)
        .background(raised ? sh.bgRaised : sh.bgHover, in: shape)
        .overlay { shape.strokeBorder(sh.textTertiary, lineWidth: M.chipRing).opacity(highlighted ? 1 : 0) }
        .frame(maxWidth: M.chipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(deleted ? M.deletedOpacity : 1)
        .shAnimation(.hover, value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// "v23 · design reference" in 12 `textTertiary`; amber when the design moved on or its host is away.
    private var meta: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        let amber: Bool = switch state {
        case .updated, .hostOffline: true
        case .current, .deleted, .anotherHost: false
        }
        return HStack(spacing: M.crumbSpacing) {
            Text(metaWords)
                .font(.shSans(M.boardMetaSize))
                .foregroundStyle(amber ? sh.lanternText : sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            switch state {
            case .anotherHost(let host): SHReferenceHostTag(host)
            case .hostOffline(let host, _): SHReferenceHostTag(host, offline: true)
            case .current, .updated, .deleted: EmptyView()
            }
        }
    }

    private var metaWords: String {
        let words: String = switch state {
        case .current, .anotherHost: "design reference"
        case .updated(let text), .deleted(let text), .hostOffline(_, let text): text
        }
        return [version, words].compactMap { $0 }.joined(separator: " · ")
    }

    #else
    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.chipRadius)
        HStack(spacing: M.chipSpacing) {
            SHReferenceThumbnail(thumbnail, deleted: deleted)
            VStack(alignment: .leading, spacing: M.lineSpacing) {
                SHReferenceCrumbs(crumbs: crumbs)
                meta
            }
            .layoutPriority(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: M.removeGlyph, weight: .semibold))
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: M.removeSize, height: M.removeSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove")
            }
        }
        .padding(.leading, M.chipPaddingLeading)
        .padding(.trailing, M.chipPaddingTrailing)
        .padding(.vertical, M.chipPaddingVertical)
        .background {
            ZStack {
                shape.fill(sh.bgBubble)
                if highlighted { shape.fill(sh.runningTint) }
            }
        }
        .overlay { Color.clear.shBorder(highlighted ? sh.running : sh.lineStrong, in: shape) }
        .frame(maxWidth: M.chipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(deleted ? M.deletedOpacity : 1)
        .shAnimation(.hover, value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var meta: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        return HStack(spacing: M.crumbSpacing) {
            if let version {
                Text(version).font(.shMono(M.versionSize)).foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
                Text("·").font(.shSans(M.metaSize)).foregroundStyle(sh.textTertiary)
            }
            switch state {
            case .current:
                words("design reference", color: sh.textTertiary)
            case .updated(let text):
                Circle().fill(sh.lantern).frame(width: M.stateDot, height: M.stateDot)
                words(text, color: sh.lanternText)
            case .deleted(let text):
                words(text, color: sh.textTertiary)
            case .anotherHost(let host):
                SHReferenceHostTag(host)
            case .hostOffline(let host, let text):
                SHReferenceHostTag(host, offline: true)
                words(text, color: sh.lanternText)
            }
        }
    }

    private func words(_ text: String, color: Color) -> some View {
        Text(text).font(.shSans(SHReferenceMetrics.metaSize)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
    }

    #endif

    private var accessibilityText: String {
        var parts = ["Design reference", crumbs.joined(separator: ", ")]
        if let version { parts.append(version) }
        switch state {
        case .current: break
        case .updated(let text), .deleted(let text): parts.append(text)
        case .anotherHost(let host): parts.append("on \(host)")
        case .hostOffline(let host, let text): parts.append("\(host), \(text)")
        }
        return parts.joined(separator: ", ")
    }
}

/// What changed since a chip's version (the preview's amber box): "Changed since v23 · now v26"
/// and short mono lines ("padding 24 → 20").
public struct SHReferenceChanges: Equatable, Sendable {
    public var title: String
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

/// The chip's bigger preview (DesignReferencePreview), after a short hover: the picture on its
/// tray, the breadcrumb, the version with when it was pinned and its system, what changed since
/// (amber, when the design moved on), what the agent gets, and Open in design (and Send vN).
/// 340pt at radius 14 on the popover's surface.
public struct SHDesignReferencePreview: View {
    let picture: SHReferenceImage?
    let crumbs: [String]
    let version: String?
    let pinned: String?
    let system: String?
    let changes: SHReferenceChanges?
    let gets: [String]
    let deleted: Bool
    let openTitle: String
    let open: (() -> Void)?
    let sendLatestTitle: String?
    let sendLatest: (() -> Void)?

    public init(picture: SHReferenceImage?, crumbs: [String], version: String?, pinned: String? = nil, system: String? = nil,
                changes: SHReferenceChanges? = nil, gets: [String], deleted: Bool = false, openTitle: String = "Open in design",
                open: (() -> Void)?, sendLatestTitle: String? = nil, sendLatest: (() -> Void)? = nil) {
        self.picture = picture
        self.crumbs = crumbs
        self.version = version
        self.pinned = pinned
        self.system = system
        self.changes = changes
        self.gets = gets
        self.deleted = deleted
        self.openTitle = openTitle
        self.open = open
        self.sendLatestTitle = sendLatestTitle
        self.sendLatest = sendLatest
    }

    /// "v23 · pinned Sep 27, 10:42 · acme-web".
    private var meta: String { [version, pinned, system].compactMap { $0 }.joined(separator: " · ") }

    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            let tray = RoundedRectangle(cornerRadius: M.previewTrayRadius)
            SHReferenceThumbnail(picture, size: M.previewPicture, radius: M.previewPictureRadius, deleted: deleted)
                .frame(maxWidth: .infinity)
                .frame(height: M.previewTray)
                .background(sh.bgHover, in: tray)
                .shBorder(sh.lineStrong, in: tray)
            SHReferenceCrumbs(crumbs: crumbs)
                .padding(.top, M.previewCrumbTop)
                .padding(.horizontal, M.previewInset)
            if !meta.isEmpty {
                Text(meta)
                    .font(.shSans(M.previewMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .padding(.top, M.previewMetaTop)
                    .padding(.horizontal, M.previewInset)
            }
            if let changes {
                VStack(alignment: .leading, spacing: 0) {
                    Text(changes.title).font(.shSans(M.changesTitleSize, .semibold)).foregroundStyle(sh.lanternText)
                    Text(changes.lines.joined(separator: "\n"))
                        .font(.shMono(M.changesLineSize))
                        .foregroundStyle(sh.textPrimary)
                        .lineSpacing(M.changesLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, M.changesPaddingVertical)
                .padding(.horizontal, M.changesPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: M.changesRadius))
                .padding(.top, M.sectionTop)
            }
            if !gets.isEmpty {
                SHFlowLayout(spacing: M.previewGap, lineSpacing: M.getsSpacing) {
                    Text("The agent gets").font(.shSans(M.previewMetaSize)).foregroundStyle(sh.textTertiary)
                        .frame(height: M.getsTagHeight)
                    ForEach(gets, id: \.self) { SHReferenceGetsTag($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, M.sectionTop)
                .padding(.horizontal, M.previewInset)
            }
            if open != nil || sendLatest != nil {
                HStack(spacing: M.footerSpacing) {
                    if let open {
                        Button(action: open) {
                            HStack(spacing: M.linkGlyphSpacing) {
                                Image(systemName: "arrow.up.forward.square")
                                Text(openTitle)
                            }
                        }
                        .buttonStyle(.shLink(color: sh.textPrimary, font: .shSans(M.linkSize, .medium)))
                    }
                    if let sendLatest, let sendLatestTitle {
                        Button(sendLatestTitle, action: sendLatest)
                            .buttonStyle(.shLink(color: sh.textSecondary, font: .shSans(M.linkSize)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, M.footerPaddingTop)
                .padding(.horizontal, M.previewInset)
                .overlay(alignment: .top) { SHHairline() }
                .padding(.top, M.sectionTop)
            }
        }
        .padding(M.previewPadding)
        .frame(width: M.previewWidth, alignment: .leading)
        .shPopover(radius: M.previewRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design reference preview")
    }
}

/// One of "The agent gets" tags: mono 12 on `bgHover`, 20pt, radius 4.
struct SHReferenceGetsTag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.shMono(SHReferenceMetrics.getsTagSize))
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SHReferenceMetrics.getsTagPadding)
            .frame(height: SHReferenceMetrics.getsTagHeight)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .fixedSize()
    }
}

// MARK: - Notes back

/// The pin a thread's note sits under on the canvas (.gdz-pin.th): the canvas's pin size, a
/// raised disc with a line and a code glyph, so it never reads as a comment's number.
public struct SHThreadNotePin: View {
    public init() {}

    public var body: some View {
        let M = SHReferenceMetrics.self
        let side = SHDesignMetrics.pinSize
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: M.notePinGlyph, weight: .semibold))
            .foregroundStyle(Color.sh.textPrimary)
            .frame(width: side, height: side)
            .background(Color.sh.bgRaised, in: Circle())
            .overlay { Circle().strokeBorder(Color.sh.lineStrong, lineWidth: M.notePinRing) }
            .shadow(color: Color.sh.knobShadow, radius: SHDesignMetrics.pinShadowRadius, y: SHDesignMetrics.pinShadowY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note from a thread")
    }
}

/// A thread's note as the canvas shows it beside its pin (ThreadNoteCard): "Note from" and the
/// thread's name with its age, the note (its `code` in mono), then Open thread, Resolve and the
/// version it was sent. 300pt on the popover's surface.
public struct SHThreadNoteCard: View {
    let thread: String
    let age: String
    let text: String
    let from: String?
    let openThread: (() -> Void)?
    let resolve: (() -> Void)?

    public init(thread: String, age: String, text: String, from: String?, openThread: (() -> Void)?, resolve: (() -> Void)?) {
        self.thread = thread
        self.age = age
        self.text = text
        self.from = from
        self.openThread = openThread
        self.resolve = resolve
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text("Note from").font(.shSans(M.noteMetaSize)).foregroundStyle(sh.textTertiary).fixedSize()
                Text(thread).font(.shSans(M.noteNameSize, .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.s)
                Text(age).font(.shSans(M.noteMetaSize)).foregroundStyle(sh.textTertiary).fixedSize()
            }
            SHThreadNoteText(text).padding(.top, M.noteTextTop)
            HStack(spacing: M.footerSpacing) {
                if let openThread {
                    Button("Open thread", action: openThread).buttonStyle(.shLink(color: sh.textPrimary, font: .shSans(M.linkSize, .medium)))
                }
                if let resolve {
                    Button("Resolve", action: resolve).buttonStyle(.shLink(color: sh.textSecondary, font: .shSans(M.linkSize)))
                }
                Spacer(minLength: SH.Space.s)
                if let from { Text(from).font(.shSans(M.noteMetaSize)).foregroundStyle(sh.textTertiary).fixedSize() }
            }
            .padding(.top, M.noteFooterTop)
        }
        .padding(.vertical, M.notePaddingVertical)
        .padding(.horizontal, M.notePaddingHorizontal)
        .frame(width: M.noteWidth, alignment: .leading)
        .shPopover(radius: M.noteRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note from \(thread)")
    }
}

/// A glyph and its label 5pt apart.
struct SHTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}

/// A note's words: plain text, with its `code` spans in mono, the rest 13 `textPrimary`. Nothing
/// in it is a link.
public struct SHThreadNoteText: View {
    let text: String

    public init(_ text: String) { self.text = text }

    /// The note in runs: plain words, `code`, and pull request numbers ("#142").
    public enum Run: Equatable, Sendable {
        case words(String)
        case code(String)
        case number(String)
    }

    public static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var words = ""
        func flush() { if !words.isEmpty { out.append(.words(words)); words = "" } }
        var rest = Substring(text)
        while let first = rest.first {
            if first == "`", let close = rest.dropFirst().firstIndex(of: "`") {
                let code = rest[rest.index(after: rest.startIndex)..<close]
                if !code.isEmpty {
                    flush()
                    out.append(.code(String(code)))
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            if first == "#", words.last.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty {
                    flush()
                    out.append(.number("#" + digits))
                    rest = rest.dropFirst(1 + digits.count)
                    continue
                }
            }
            words.append(first)
            rest = rest.dropFirst()
        }
        flush()
        return out
    }

    public var body: some View {
        let M = SHReferenceMetrics.self
        var line = Text("")
        for run in Self.runs(text) {
            switch run {
            case .words(let words): line = Text("\(line)\(words)")
            case .code(let code): line = Text("\(line)\(Text(code).font(.shMono(M.noteCodeSize)))")
            case .number(let number): line = Text("\(line)\(number)")
            }
        }
        return line
            .font(.shSans(M.noteTextSize))
            .foregroundStyle(Color.sh.textPrimary)
            .lineSpacing(M.noteTextSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - The toasts

/// A toast on the canvas after a design reference goes (Toast · sent, Toast · copied): a link glyph
/// for a copy, the words in 13 with the thread's name semibold, an optional text button (Open
/// thread), and a close. At most 620pt on the popover's surface at radius 12.
public struct SHReferenceToast: View {
    public enum Kind: Sendable {
        case sent
        case copied
    }

    let kind: Kind
    let message: Text
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: () -> Void

    public init(_ kind: Kind, message: Text, actionTitle: String? = nil, action: (() -> Void)? = nil, dismiss: @escaping () -> Void) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        HStack(spacing: M.toastSpacing) {
            if kind == .copied {
                Image(systemName: "link")
                    .font(.system(size: M.toastGlyph, weight: .medium))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
            }
            message
                .font(.shSans(M.toastTextSize))
                .foregroundStyle(sh.textPrimary)
                .lineSpacing(SH.Space.xxs)
                .frame(maxWidth: M.toastMessageWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.shLink(color: sh.textPrimary, font: .shSans(M.linkSize, .medium)))
                    .padding(.leading, SH.Space.xs)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.shIcon(size: M.toastClose))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(M.toastPadding)
        .padding(.leading, M.toastPaddingLeading - M.toastPadding)
        .frame(minHeight: M.toastMinHeight)
        .shPopover(radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
