import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The thread's own dimensions (NWThread board): activity lines, their calls, the live tail,
/// bubbles and the prose measure.
public enum NWThreadMetrics {
    /// An activity line's minimum height.
    public static let activityHeight: CGFloat = touchable(26)
    public static let activityIcon: CGFloat = 13
    public static let chevron: CGFloat = 10
    /// A live line (LiveText: the running call, live thinking): 26pt on every platform, since
    /// nothing on it takes a tap; live thinking's chevron is 11pt.
    public static let liveHeight: CGFloat = 26
    public static let liveChevron: CGFloat = 11
    /// A call row in an expanded line.
    public static let callRowHeight: CGFloat = touchable(22)
    /// The calls list's kind column ("edit", "bash"), before it widens for longer names.
    public static let callLabelWidth: CGFloat = 32
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
        max(height, NW.Height.touch)
        #else
        height
        #endif
    }
}

enum NWPasteboard {
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
public struct NWDiffStat: View {
    let added: Int
    let removed: Int
    let font: Font?

    public init(added: Int, removed: Int, font: Font? = nil) {
        self.added = added
        self.removed = removed
        self.font = font
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Text("+\(added)").foregroundStyle(.nw.done)
            Text("\u{2212}\(removed)").foregroundStyle(.nw.failed)
        }
        .font(font ?? .nw(.mono))
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// Code in prose: mono 12 on `bgSunken` with a 1px line, radius 4.
public struct NWInlineCode: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nwMono(12))
            .foregroundStyle(.nw.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .nwBorder(.nw.lineSubtle, radius: NW.Radius.xs)
    }
}

/// Above the messages the queue delivered as one turn (Queue & steer boards · In the thread): a
/// hairline each side of the queue glyph and "From the queue · 2" in caption tertiary, or "From
/// the queue" for one.
public struct NWQueueDivider: View {
    let count: Int

    public init(count: Int) { self.count = count }

    private var label: String { count > 1 ? "From the queue · \(count)" : "From the queue" }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            NWHairline()
            HStack(spacing: NW.Space.xs) {
                NWQueueGlyph(size: NWThreadMetrics.queueGlyph)
                Text(label)
            }
            .font(.nw(.caption))
            .foregroundStyle(.nw.textTertiary)
            .fixedSize()
            NWHairline()
        }
        .padding(.vertical, NW.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A file or image with a message (NWThread board): 26pt, a 1px strong line, radius 6. Files
/// lead with a document glyph; images with their 20pt thumbnail. In the composer it has a
/// remove button; in a sent bubble it has none. `.compact` is the queue's read-only chip: 22pt,
/// a 16pt thumbnail (or a photo glyph where the bytes stayed on another Mac), radius 4.
public struct NWAttachmentChip: View {
    public enum Size: Sendable { case regular, compact }

    let name: String
    let prefix: String?
    let thumbnail: Image?
    let size: Size
    let remove: (() -> Void)?

    /// `thumbnail` shows an image's preview in place of the file glyph; `remove` adds the
    /// remove button.
    public init(_ name: String, prefix: String? = nil, thumbnail: Image? = nil, size: Size = .regular, remove: (() -> Void)? = nil) {
        self.name = name
        self.prefix = prefix
        self.thumbnail = thumbnail
        self.size = size
        self.remove = remove
    }

    public var body: some View {
        let nw = Color.nw
        let compact = size == .compact
        let side = compact ? NWQueueMetrics.chipThumbnail : NWThreadMetrics.attachmentThumbnail
        HStack(spacing: compact ? NW.Space.xs : NW.Space.s) {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .background(nw.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? NWQueueMetrics.chipThumbnailRadius : NW.Radius.xs))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: compact ? "photo" : "doc")
                    .font(.system(size: compact ? 11 : 10, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if let prefix { Text(prefix).foregroundStyle(nw.textTertiary) }
                Text(name).foregroundStyle(nw.textPrimary)
            }
            .font(.nwSans(compact ? 11 : 12))
            .lineLimit(1)
            .truncationMode(.middle)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(nw.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.leading, thumbnail == nil ? (compact ? NW.Space.s : NW.Space.m) : 3)
        .padding(.trailing, compact ? NW.Space.s : remove == nil && thumbnail != nil ? NW.Space.xs : NW.Space.m)
        .frame(height: compact ? NWQueueMetrics.chipHeight : NWThreadMetrics.attachmentHeight)
        .nwBorder(nw.lineStrong, radius: compact ? NW.Radius.xs : NW.Radius.s)
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityElement(children: .contain)
    }
}

/// "↓ Jump to latest": a `bgRaised` capsule above the composer while the thread is detached from
/// its tail (`action` set). It grows in from the bottom and leaves the same way; its motion is
/// its own, so the rows behind it never animate with it. On iOS its hit area is the 44pt touch
/// minimum around the drawn capsule.
public struct NWJumpToLatest: View {
    let action: (() -> Void)?

    /// nil hides it.
    public init(action: (() -> Void)?) {
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        ZStack {
            if let action {
                Button(action: action) {
                    Label("Jump to latest", systemImage: "arrow.down")
                        .font(Font.nw(.caption, weight: .medium)).foregroundStyle(nw.textSecondary)
                        // Grows with the text on iOS, whose type scales.
                        .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.xs)
                        .frame(minHeight: NW.Height.controlM)
                        .background(nw.bgRaised, in: Capsule())
                        .nwBorder(nw.lineStrong, in: Capsule())
                        .nwTouchTarget(height: NW.Height.controlM)
                }
                .buttonStyle(.plain)
                .nwTransition(.overlay, anchor: .bottom)
                .accessibilityLabel("Jump to latest")
            }
        }
        .nwAnimation(.overlay, value: action != nil)
    }
}
