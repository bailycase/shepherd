import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The thread's own dimensions (SHThread board): activity lines, their calls, the live tail,
/// bubbles and the prose measure.
public enum SHThreadMetrics {
    /// An activity line's minimum height.
    public static let activityHeight: CGFloat = touchable(26)
    public static let activityIcon: CGFloat = 13
    public static let chevron: CGFloat = 10
    /// A live line (LiveText: the running call, live thinking): 26pt on every platform, since
    /// nothing on it takes a tap.
    public static let liveHeight: CGFloat = 26
    /// A call row in an expanded line.
    public static let callRowHeight: CGFloat = touchable(24)
    /// The calls list's kind column ("edit", "bash"), before it widens for longer names.
    public static let callLabelWidth: CGFloat = 32
    /// The most characters the kind column widens for ("shepherd_child_message"); a longer name
    /// truncates, so a tool with a long name never takes the room its detail needs.
    public static let callLabelMaxCharacters = 22
    /// The least room an activity line's meta gets (four mono 11 characters); with less it is not drawn.
    public static let activityMetaMinimum: CGFloat = 26
    /// The hairline rail sits under the line's icon; its rows start 16pt right of it.
    public static let railInset: CGFloat = 9
    public static let railPadding: CGFloat = 16
    /// A running call's output lines start under its label.
    public static let liveTailIndent: CGFloat = 21
    /// Mono 11 at the board's 1.6 line height.
    public static let tailLineSpacing: CGFloat = 4
    /// Mono 11 lines in an expanded call's output.
    public static let outputMaxLines = 12
    /// The changes card (ChangesCard): rows 30pt, a 30pt tile, radius 10.
    public static let changesRowHeight: CGFloat = touchable(30)
    public static let changesTile: CGFloat = 30
    public static let changesRadius: CGFloat = 10
    /// Files the card lists before "N more".
    public static let changesShownFiles = 3
    public static let codeHeaderHeight: CGFloat = touchable(28)
    /// The copy and retry buttons under a turn, and the code block's copy.
    public static let footerButton: CGFloat = 24
    /// The footer buttons' glyphs (copy, retry, Response timing).
    public static let footerGlyph: CGFloat = 12
    /// A live line's clock, in mono (LiveText, ResponseVisibility › A).
    public static let liveClock: CGFloat = 11
    public static let codeCopyButton: CGFloat = 22
    public static let bubbleMaxWidth: CGFloat = 600
    /// Agent prose measure.
    public static let proseMeasure: CGFloat = 640
    /// A list item's text starts this far in; its marker sits right-aligned before it.
    public static let listIndent: CGFloat = 20
    /// The rule quotes, expanded thinking, and notes sit on.
    public static let ruleWidth: CGFloat = 2
    public static let attachmentHeight: CGFloat = 26
    public static let attachmentThumbnail: CGFloat = 20
    /// "From the queue"'s glyph.
    public static let queueGlyph: CGFloat = 11
    /// A table column takes its content's width up to this, then wraps; given room, a wrapped
    /// column grows past it.
    #if os(iOS)
    public static let tableColumnMax: CGFloat = 260
    #else
    public static let tableColumnMax: CGFloat = 360
    #endif
    /// The narrowest a table column shrinks to: past it, the table scrolls sideways instead.
    public static let tableColumnMin: CGFloat = 88
    /// A local image in prose fits within this box.
    public static let proseImageMaxWidth: CGFloat = 360
    public static let proseImageMaxHeight: CGFloat = 240
    /// The glyph before a diagram or math fence's label.
    public static let codeLabelGlyph: CGFloat = 10

    /// A row someone taps: the Mac's height, or the touch minimum on iOS.
    static func touchable(_ height: CGFloat) -> CGFloat {
        #if os(iOS)
        max(height, SH.Height.touch)
        #else
        height
        #endif
    }
}

enum SHPasteboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// "+58 −41": additions in `done`, removals in `failed`, mono, with a true minus sign.
public struct SHDiffStat: View {
    let added: Int
    let removed: Int
    let font: Font?

    public init(added: Int, removed: Int, font: Font? = nil) {
        self.added = added
        self.removed = removed
        self.font = font
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text("+\(added)").foregroundStyle(.sh.done)
            Text("\u{2212}\(removed)").foregroundStyle(.sh.failed)
        }
        .font(font ?? .sh(.mono))
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// Code in prose: mono 12 on `bgSunken` with a 1px line, radius 4.
public struct SHInlineCode: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.shMono(12))
            .foregroundStyle(.sh.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(.sh.lineSubtle, radius: SH.Radius.xs)
    }
}

/// Above the messages the queue delivered as one turn (Queue & steer boards · In the thread): a
/// hairline each side of the queue glyph and "From the queue · 2" in caption tertiary, or "From
/// the queue" for one.
public struct SHQueueDivider: View {
    let count: Int

    public init(count: Int) { self.count = count }

    private var label: String { count > 1 ? "From the queue · \(count)" : "From the queue" }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            SHHairline()
            HStack(spacing: SH.Space.xs) {
                SHQueueGlyph(size: SHThreadMetrics.queueGlyph)
                Text(label)
            }
            .font(.sh(.caption))
            .foregroundStyle(.sh.textTertiary)
            .fixedSize()
            SHHairline()
        }
        .padding(.vertical, SH.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A file or image with a message (SHThread board): 26pt, a 1px strong line, radius 6. Files
/// lead with a document glyph; images with their 20pt thumbnail. In the composer it has a
/// remove button; in a sent bubble it has none. `.compact` is the queue's read-only chip: 22pt,
/// a 16pt thumbnail (or a photo glyph where the bytes stayed on another Mac), radius 4.
public struct SHAttachmentChip: View {
    public enum Size: Sendable { case regular, compact }

    let name: String
    let prefix: String?
    let thumbnail: Image?
    let size: Size
    let remove: (() -> Void)?
    let detail: String?
    let problem: Bool
    let open: (() -> Void)?

    /// `thumbnail` shows an image's preview in place of the file glyph; `remove` adds the
    /// remove button. `detail` is a mono size after the name ("1.4 MB"); `problem` draws the
    /// chip and its detail in `failed` ("3.1 MB · over 2 MB"); `open` makes the thumbnail a
    /// button that opens the image full size.
    public init(_ name: String, prefix: String? = nil, thumbnail: Image? = nil, size: Size = .regular, detail: String? = nil,
                problem: Bool = false, open: (() -> Void)? = nil, remove: (() -> Void)? = nil) {
        self.name = name
        self.prefix = prefix
        self.thumbnail = thumbnail
        self.size = size
        self.detail = detail
        self.problem = problem
        self.open = open
        self.remove = remove
    }

    public var body: some View {
        let sh = Color.sh
        let compact = size == .compact
        let side = compact ? SHQueueMetrics.chipThumbnail : SHThreadMetrics.attachmentThumbnail
        HStack(spacing: compact ? SH.Space.xs : SH.Space.s) {
            if let thumbnail {
                let picture = thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .background(sh.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? SHQueueMetrics.chipThumbnailRadius : SH.Radius.xs))
                if let open {
                    // The picture stays the board's 20pt; the press area is the Mac's 24pt.
                    Button(action: open) { picture }
                        .buttonStyle(.plain)
                        .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -SH.Space.xxs)
                        .shFocusRing(radius: SH.Radius.xs)
                        .accessibilityLabel("Open \(name)")
                } else {
                    picture.accessibilityHidden(true)
                }
            } else {
                Image(systemName: compact ? "photo" : "doc")
                    .font(.system(size: compact ? 11 : 10, weight: .medium))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if let prefix { Text(prefix).foregroundStyle(sh.textTertiary) }
                Text(name).foregroundStyle(sh.textPrimary)
            }
            .font(.shSans(compact ? 11 : 12))
            .lineLimit(1)
            .truncationMode(.middle)
            if let detail {
                Text(detail).font(.sh(.micro)).foregroundStyle(problem ? sh.failed : sh.textTertiary).lineLimit(1)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(sh.textTertiary)
                        .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The x is drawn 14pt; its press area is the Mac's 24pt, so it takes the room its padding left.
                .padding(.horizontal, -SH.Space.xs)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.leading, thumbnail == nil ? (compact ? SH.Space.s : SH.Space.m) : 3)
        .padding(.trailing, compact ? SH.Space.s : remove == nil && thumbnail != nil ? SH.Space.xs : SH.Space.m)
        .frame(height: compact ? SHQueueMetrics.chipHeight : SHThreadMetrics.attachmentHeight)
        .shBorder(problem ? sh.failed : sh.lineStrong, radius: compact ? SH.Radius.xs : SH.Radius.s)
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityElement(children: .contain)
    }
}

/// "↓ Jump to latest": a `bgRaised` capsule above the composer while the thread is detached from
/// its tail (`action` set). It grows in from the bottom and leaves the same way; its motion is
/// its own, so the rows behind it never animate with it. On iOS its hit area is the 44pt touch
/// minimum around the drawn capsule.
public struct SHJumpToLatest: View {
    let action: (() -> Void)?

    /// nil hides it.
    public init(action: (() -> Void)?) {
        self.action = action
    }

    public var body: some View {
        let sh = Color.sh
        ZStack {
            if let action {
                Button(action: action) {
                    Label("Jump to latest", systemImage: "arrow.down")
                        .font(Font.sh(.caption, weight: .medium)).foregroundStyle(sh.textSecondary)
                        // Grows with the text on iOS, whose type scales.
                        .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.xs)
                        .frame(minHeight: SH.Height.controlM)
                        .background(sh.bgRaised, in: Capsule())
                        .shBorder(sh.lineStrong, in: Capsule())
                        .shTouchTarget(height: SH.Height.controlM)
                }
                .buttonStyle(.plain)
                .shTransition(.overlay, anchor: .bottom)
                .accessibilityLabel("Jump to latest")
            }
        }
        .shAnimation(.overlay, value: action != nil)
    }
}
