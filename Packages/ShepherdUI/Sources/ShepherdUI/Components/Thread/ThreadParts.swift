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
    public static let activityHeight: CGFloat = 26
    public static let activityIcon: CGFloat = 13
    public static let chevron: CGFloat = 10
    /// A call row in an expanded line.
    public static let callRowHeight: CGFloat = 22
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
    public static let changesHeaderHeight: CGFloat = 32
    public static let changesRowHeight: CGFloat = 28
    public static let codeHeaderHeight: CGFloat = 28
    /// The copy and retry buttons under a turn, and the code block's copy.
    public static let footerButton: CGFloat = 24
    public static let codeCopyButton: CGFloat = 22
    public static let bubbleMaxWidth: CGFloat = 600
    /// Agent prose measure.
    public static let proseMeasure: CGFloat = 640
    public static let attachmentHeight: CGFloat = 26
    public static let attachmentThumbnail: CGFloat = 20
}

/// The live elapsed time on a running line: "14s", "1m 02s", "1h 02m".
public enum NWElapsed {
    public static func text(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return String(format: "%dh %02dm", whole / 3600, (whole % 3600) / 60)
    }
}

/// Ticks once a second from `since`; only this text redraws.
struct NWElapsedText: View {
    let since: Date
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(NWElapsed.text(context.date.timeIntervalSince(since)))
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
        }
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

/// A file or image with a message (NWThread board): 26pt, a 1px strong line, radius 6. Files
/// lead with a document glyph; images with their 20pt thumbnail. In the composer it has a
/// remove button; in a sent bubble it has none.
public struct NWAttachmentChip: View {
    let name: String
    let prefix: String?
    let thumbnail: Image?
    let remove: (() -> Void)?

    /// `thumbnail` shows an image's preview in place of the file glyph; `remove` adds the
    /// remove button.
    public init(_ name: String, prefix: String? = nil, thumbnail: Image? = nil, remove: (() -> Void)? = nil) {
        self.name = name
        self.prefix = prefix
        self.thumbnail = thumbnail
        self.remove = remove
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: NWThreadMetrics.attachmentThumbnail, height: NWThreadMetrics.attachmentThumbnail)
                    .background(nw.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: NW.Radius.xs))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if let prefix { Text(prefix).foregroundStyle(nw.textTertiary) }
                Text(name).foregroundStyle(nw.textPrimary)
            }
            .font(.nwSans(12))
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
        .padding(.leading, thumbnail == nil ? NW.Space.m : 3)
        .padding(.trailing, remove == nil && thumbnail != nil ? NW.Space.xs : NW.Space.m)
        .frame(height: NWThreadMetrics.attachmentHeight)
        .nwBorder(nw.lineStrong, radius: NW.Radius.s)
        .accessibilityElement(children: .contain)
    }
}
