import SwiftUI

// Design references (DesignRefStates): the chip a thread shows for a design piece it was handed,
// the bigger preview a chip opens on hover, the thread's pin on the canvas with its note, and the
// toasts the canvas shows after Implement in a thread… or Copy reference. Everything here takes
// its words and pictures as values: nothing reads a design.

/// The boards' own measures for design references (DesignRefStates, RefChipHover, RefNoteBack).
public enum NWReferenceMetrics {
    // The chip
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
    // The preview
    public static let previewWidth: CGFloat = 340
    public static let previewPadding: CGFloat = 12
    public static let previewSpacing: CGFloat = 10
    public static let previewPicture = CGSize(width: 316, height: 107)
    public static let previewPictureRadius: CGFloat = 6
    public static let previewMetaSize: CGFloat = 11.5
    public static let previewVersionSize: CGFloat = 11
    public static let previewGap: CGFloat = 6
    public static let changesPaddingVertical: CGFloat = 8
    public static let changesPaddingHorizontal: CGFloat = 10
    public static let changesSpacing: CGFloat = 5
    public static let changesTitleSize: CGFloat = 12
    public static let changesLineSize: CGFloat = 11
    public static let getsTagHeight: CGFloat = 18
    public static let getsTagSize: CGFloat = 10.5
    public static let getsSpacing: CGFloat = 3
    public static let getsTagPadding: CGFloat = 4
    // The thread's pin and its note
    public static let notePin: CGFloat = 26
    public static let notePinPoint: CGFloat = 4
    public static let notePinRing: CGFloat = 1.5
    public static let notePinGlyph: CGFloat = 11
    public static let noteWidth: CGFloat = 300
    public static let notePaddingVertical: CGFloat = 12
    public static let notePaddingHorizontal: CGFloat = 14
    public static let noteSpacing: CGFloat = 10
    public static let noteTagHeight: CGFloat = 18
    public static let noteTagSize: CGFloat = 11
    public static let noteMetaSize: CGFloat = 11.5
    public static let noteTextSize: CGFloat = 13
    public static let noteCodeSize: CGFloat = 12
    public static let noteFooterSize: CGFloat = 11
    /// The note opens this far after its pin.
    public static let noteGap: CGFloat = 14
    // The toasts
    public static let toastWidth: CGFloat = 520
    public static let toastSpacing: CGFloat = 12
    public static let toastPaddingVertical: CGFloat = 11
    public static let toastPaddingLeading: CGFloat = 14
    public static let toastPaddingTrailing: CGFloat = 12
    public static let toastGlyph: CGFloat = 14
    public static let toastTextSize: CGFloat = 13
    /// The toast sits this far above the canvas's bottom edge.
    public static let toastBottom: CGFloat = 22
    // The agent's line
    public static let detailRowHeight: CGFloat = 22
    public static let detailLabelWidth: CGFloat = 32
    public static let detailIndent: CGFloat = 9
    public static let detailRail: CGFloat = 16
}

/// A picture handed to a design reference's views: the image and what it shows, so a view
/// compares it by `id` and redraws only when another picture lands.
public struct NWReferenceImage: Equatable, @unchecked Sendable {
    public let id: String
    public let image: Image

    public init(id: String, image: Image) {
        self.id = id
        self.image = image
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// How a reference stands (DesignReferenceChip(ref, state:)): as sent; the design moved on since
/// (an amber dot, "updated since · now v26"); the design is gone (the chip dims and its picture
/// is a dashed trash tile); on another host (the host's name as a tag); or on a host that is
/// offline (the tag and the words in amber). Each carries its words.
public enum NWReferenceState: Equatable, Sendable {
    case current
    case updated(String)
    case deleted(String)
    case anotherHost(String)
    case hostOffline(host: String, words: String)
}

/// A reference's picture as a chip, a picker row or a sheet draws it: the image filling a
/// rounded tile with a faint ring, or the sunken tile while none is at hand. A deleted design's
/// is a dashed tile with a trash glyph.
public struct NWReferenceThumbnail: View, Equatable {
    let image: NWReferenceImage?
    let size: CGSize
    let radius: CGFloat
    let deleted: Bool

    public init(_ image: NWReferenceImage?, size: CGSize = NWReferenceMetrics.thumbnail, radius: CGFloat = NWReferenceMetrics.thumbnailRadius,
                deleted: Bool = false) {
        self.image = image
        self.size = size
        self.radius = radius
        self.deleted = deleted
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: radius)
        Group {
            if deleted {
                Image(systemName: "trash")
                    .font(.system(size: NWReferenceMetrics.deletedGlyph))
                    .foregroundStyle(nw.textTertiary)
                    .frame(width: size.width, height: size.height)
                    .nwBorder(nw.lineStrong, in: shape, dash: NWReferenceMetrics.dash)
            } else if let image {
                image.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipShape(shape)
                    .overlay { Color.clear.nwBorder(nw.lineStrong, in: shape) }
            } else {
                shape.fill(nw.bgSunken)
                    .frame(width: size.width, height: size.height)
                    .overlay { Color.clear.nwBorder(nw.lineStrong, in: shape) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// design › board › element on one line (12.5): the parents in `textSecondary`, the piece last in
/// `textPrimary` semibold, `›` between in `textTertiary`. The design's name gives way first.
struct NWReferenceCrumbs: View {
    let crumbs: [String]
    var size: CGFloat = NWReferenceMetrics.crumbSize

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NWReferenceMetrics.crumbSpacing) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Text("›").foregroundStyle(nw.textTertiary) }
                let last = index == crumbs.count - 1
                Text(crumb)
                    .fontWeight(last ? .semibold : .regular)
                    .foregroundStyle(last ? nw.textPrimary : nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The design's name truncates first, then the board's; the piece holds on.
                    .layoutPriority(last ? 2 : Double(index))
            }
        }
        .font(.nwSans(size))
    }
}

/// A host's name as its small mono tag (build-01), amber when the host is offline.
public struct NWReferenceHostTag: View {
    let host: String
    let offline: Bool

    public init(_ host: String, offline: Bool = false) {
        self.host = host
        self.offline = offline
    }

    public var body: some View {
        Text(host)
            .font(.nwMono(NWReferenceMetrics.hostTagSize))
            .foregroundStyle(offline ? Color.nw.lanternText : Color.nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, NWReferenceMetrics.hostTagPadding)
            .frame(height: NWReferenceMetrics.hostTagHeight)
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.xs)
            .fixedSize()
    }
}

/// The reference chip (DesignReferenceChip): the only design UI a thread ever shows. A 40×26
/// picture, the breadcrumb, and under it the version and how the reference stands. In the
/// composer it has a remove button; in a sent message it opens the design. `highlighted` is its
/// hover ring, while its preview is open.
public struct NWDesignReferenceChip: View {
    let crumbs: [String]
    let version: String?
    let state: NWReferenceState
    let thumbnail: NWReferenceImage?
    let highlighted: Bool
    let remove: (() -> Void)?

    public init(crumbs: [String], version: String?, state: NWReferenceState = .current, thumbnail: NWReferenceImage? = nil,
                highlighted: Bool = false, remove: (() -> Void)? = nil) {
        self.crumbs = crumbs
        self.version = version
        self.state = state
        self.thumbnail = thumbnail
        self.highlighted = highlighted
        self.remove = remove
    }

    private var deleted: Bool { if case .deleted = state { true } else { false } }

    public var body: some View {
        let nw = Color.nw
        let M = NWReferenceMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.chipRadius)
        HStack(spacing: M.chipSpacing) {
            NWReferenceThumbnail(thumbnail, deleted: deleted)
            VStack(alignment: .leading, spacing: M.lineSpacing) {
                NWReferenceCrumbs(crumbs: crumbs)
                meta
            }
            .layoutPriority(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: M.removeGlyph, weight: .semibold))
                        .foregroundStyle(nw.textTertiary)
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
                shape.fill(nw.bgBubble)
                if highlighted { shape.fill(nw.runningTint) }
            }
        }
        .overlay { Color.clear.nwBorder(highlighted ? nw.running : nw.lineStrong, in: shape) }
        .frame(maxWidth: M.chipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(deleted ? M.deletedOpacity : 1)
        .nwAnimation(.hover, value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var meta: some View {
        let nw = Color.nw
        let M = NWReferenceMetrics.self
        return HStack(spacing: M.crumbSpacing) {
            if let version {
                Text(version).font(.nwMono(M.versionSize)).foregroundStyle(nw.textTertiary).lineLimit(1).fixedSize()
                Text("·").font(.nwSans(M.metaSize)).foregroundStyle(nw.textTertiary)
            }
            switch state {
            case .current:
                words("design reference", color: nw.textTertiary)
            case .updated(let text):
                Circle().fill(nw.lantern).frame(width: M.stateDot, height: M.stateDot)
                words(text, color: nw.lanternText)
            case .deleted(let text):
                words(text, color: nw.textTertiary)
            case .anotherHost(let host):
                NWReferenceHostTag(host)
            case .hostOffline(let host, let text):
                NWReferenceHostTag(host, offline: true)
                words(text, color: nw.lanternText)
            }
        }
    }

    private func words(_ text: String, color: Color) -> some View {
        Text(text).font(.nwSans(NWReferenceMetrics.metaSize)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
    }

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
public struct NWReferenceChanges: Equatable, Sendable {
    public var title: String
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

/// The chip's bigger preview (DesignReferencePreview), after a short hover: the picture, the
/// breadcrumb, the version with when it was pinned and its system, what changed since (amber,
/// when the design moved on), what the agent gets, and Open in design (and Send vN). 340pt on the
/// popover's surface.
public struct NWDesignReferencePreview: View {
    let picture: NWReferenceImage?
    let crumbs: [String]
    let version: String?
    let pinned: String?
    let system: String?
    let changes: NWReferenceChanges?
    let gets: [String]
    let deleted: Bool
    let openTitle: String
    let open: (() -> Void)?
    let sendLatestTitle: String?
    let sendLatest: (() -> Void)?

    public init(picture: NWReferenceImage?, crumbs: [String], version: String?, pinned: String? = nil, system: String? = nil,
                changes: NWReferenceChanges? = nil, gets: [String], deleted: Bool = false, openTitle: String = "Open in design",
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

    public var body: some View {
        let nw = Color.nw
        let M = NWReferenceMetrics.self
        VStack(alignment: .leading, spacing: M.previewSpacing) {
            NWReferenceThumbnail(picture, size: M.previewPicture, radius: M.previewPictureRadius, deleted: deleted)
            NWReferenceCrumbs(crumbs: crumbs)
            HStack(spacing: NW.Space.s) {
                if let version { Text(version).font(.nwMono(M.previewVersionSize)).foregroundStyle(nw.textSecondary) }
                if let pinned { Text(pinned) }
                if let system {
                    Text("·")
                    Text(system).font(.nwMono(M.previewVersionSize))
                }
            }
            .font(.nwSans(M.previewMetaSize))
            .foregroundStyle(nw.textTertiary)
            .lineLimit(1)
            if let changes {
                VStack(alignment: .leading, spacing: M.changesSpacing) {
                    Text(changes.title).font(.nwSans(M.changesTitleSize, .semibold)).foregroundStyle(nw.lanternText)
                    Text(changes.lines.joined(separator: "\n"))
                        .font(.nwMono(M.changesLineSize))
                        .foregroundStyle(nw.textSecondary)
                        .lineSpacing(NW.Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, M.changesPaddingVertical)
                .padding(.horizontal, M.changesPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            }
            if !gets.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: M.previewGap) {
                    Text("The agent gets").font(.nwSans(M.previewMetaSize)).foregroundStyle(nw.textTertiary)
                        .fixedSize()
                    NWFlowLayout(spacing: M.getsSpacing) {
                        ForEach(gets, id: \.self) { NWReferenceGetsTag($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if open != nil || sendLatest != nil {
                HStack(spacing: NW.Space.s) {
                    if let open {
                        Button(openTitle, systemImage: "arrow.up.forward.square", action: open)
                            .buttonStyle(.nw(.secondary, size: .s))
                    }
                    if let sendLatest, let sendLatestTitle {
                        Button(sendLatestTitle, systemImage: "arrow.counterclockwise", action: sendLatest)
                            .buttonStyle(.nw(.ghost, size: .s))
                    }
                }
            }
        }
        .padding(M.previewPadding)
        .frame(width: M.previewWidth, alignment: .leading)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design reference preview")
    }
}

/// One of "The agent gets" tags: mono 10.5 on `bgSelected`, 18pt, radius 4.
struct NWReferenceGetsTag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.nwMono(NWReferenceMetrics.getsTagSize))
            .foregroundStyle(Color.nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, NWReferenceMetrics.getsTagPadding)
            .frame(height: NWReferenceMetrics.getsTagHeight)
            .background(Color.nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .fixedSize()
    }
}

// MARK: - Notes back

/// The pin a thread's note sits under on the canvas (CanvasNotePin(.thread)): the comment pin's
/// teardrop in `running` blue with a code glyph, so it never reads as a lantern comment or as the
/// design agent's.
public struct NWThreadNotePin: View {
    public init() {}

    public var body: some View {
        let M = NWReferenceMetrics.self
        let side = M.notePin
        let shape = UnevenRoundedRectangle(topLeadingRadius: side / 2, bottomLeadingRadius: M.notePinPoint,
                                           bottomTrailingRadius: side / 2, topTrailingRadius: side / 2)
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: M.notePinGlyph, weight: .semibold))
            .foregroundStyle(Color.nw.running)
            .frame(width: side, height: side)
            .background {
                ZStack {
                    shape.fill(Color.nw.bgRaised)
                    shape.fill(Color.nw.runningTint)
                }
            }
            .overlay { shape.strokeBorder(Color.nw.running, lineWidth: M.notePinRing) }
            .shadow(color: Color.nw.knobShadow, radius: NWDesignMetrics.pinShadowRadius, y: NWDesignMetrics.pinShadowY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note from a thread")
    }
}

/// A thread's note as the canvas shows it beside its pin (ThreadNoteCard): "Thread" and the
/// thread's name with its age, the note (its `code` and #123 in mono), then Open thread, Resolve
/// and the version it was sent.
public struct NWThreadNoteCard: View {
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
        let nw = Color.nw
        let M = NWReferenceMetrics.self
        VStack(alignment: .leading, spacing: M.noteSpacing) {
            HStack(spacing: NW.Space.m) {
                Label("Thread", systemImage: "text.bubble")
                    .labelStyle(NWTightLabelStyle())
                    .font(.nwSans(M.noteTagSize, .medium))
                    .foregroundStyle(nw.running)
                    .padding(.horizontal, NW.Space.s)
                    .frame(height: M.noteTagHeight)
                    .background(nw.runningTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                    .fixedSize()
                Text(thread).font(.nwSans(M.noteMetaSize, .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Spacer(minLength: NW.Space.s)
                Text(age).font(.nwSans(M.noteMetaSize)).foregroundStyle(nw.textTertiary).fixedSize()
            }
            NWThreadNoteText(text)
            HStack(spacing: NW.Space.s) {
                if let openThread {
                    Button("Open thread", systemImage: "text.bubble", action: openThread).buttonStyle(.nw(.secondary, size: .s))
                }
                if let resolve {
                    Button("Resolve", systemImage: "checkmark", action: resolve).buttonStyle(.nw(.ghost, size: .s))
                }
                Spacer(minLength: NW.Space.s)
                if let from { Text(from).font(.nwSans(M.noteFooterSize)).foregroundStyle(nw.textTertiary).fixedSize() }
            }
            .padding(.top, M.noteSpacing)
            .overlay(alignment: .top) { NWHairline() }
        }
        .padding(.vertical, M.notePaddingVertical)
        .padding(.horizontal, M.notePaddingHorizontal)
        .frame(width: M.noteWidth, alignment: .leading)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note from \(thread)")
    }
}

/// A glyph and its label 5pt apart.
struct NWTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}

/// A note's words: plain text, with its `code` spans in mono and "#142" in mono `running`, the
/// rest 13 `textPrimary`. Nothing in it is a link.
public struct NWThreadNoteText: View {
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
        let M = NWReferenceMetrics.self
        var line = Text("")
        for run in Self.runs(text) {
            switch run {
            case .words(let words): line = Text("\(line)\(words)")
            case .code(let code): line = Text("\(line)\(Text(code).font(.nwMono(M.noteCodeSize)))")
            case .number(let number): line = Text("\(line)\(Text(number).font(.nwMono(M.noteCodeSize)).foregroundStyle(Color.nw.running))")
            }
        }
        return line
            .font(.nwSans(M.noteTextSize))
            .foregroundStyle(Color.nw.textPrimary)
            .lineSpacing(NW.Space.xxs)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - The toasts

/// A toast on the canvas after a design reference goes (Toast · sent, Toast · copied): a glyph
/// (a `done` check, or a link), the words in 13 with the thread's name semibold, an optional
/// button (Open thread), and a close. 520pt on the popover's surface at radius 12.
public struct NWReferenceToast: View {
    public enum Kind: Sendable {
        case sent
        case copied
    }

    let kind: Kind
    let message: Text
    let actionTitle: String?
    let actionSymbol: String?
    let action: (() -> Void)?
    let dismiss: () -> Void

    public init(_ kind: Kind, message: Text, actionTitle: String? = nil, actionSymbol: String? = nil, action: (() -> Void)? = nil,
                dismiss: @escaping () -> Void) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        let M = NWReferenceMetrics.self
        HStack(spacing: M.toastSpacing) {
            Image(systemName: kind == .sent ? "checkmark" : "link")
                .font(.system(size: M.toastGlyph, weight: .medium))
                .foregroundStyle(kind == .sent ? Color.nw.done : Color.nw.textSecondary)
                .accessibilityHidden(true)
            message
                .font(.nwSans(M.toastTextSize))
                .foregroundStyle(Color.nw.textPrimary)
                .lineSpacing(NW.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let actionTitle {
                Button(actionTitle, systemImage: actionSymbol ?? "arrow.right", action: action)
                    .buttonStyle(.nw(.secondary, size: .s))
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.nwIcon(size: NW.Height.controlS))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, M.toastPaddingVertical)
        .padding(.leading, M.toastPaddingLeading)
        .padding(.trailing, M.toastPaddingTrailing)
        .frame(maxWidth: M.toastWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
