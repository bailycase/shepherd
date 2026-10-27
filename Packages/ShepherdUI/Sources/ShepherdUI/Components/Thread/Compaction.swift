import SwiftUI

/// Compaction in the thread (ContextIdeas › In the thread, ContextCompacted).
public enum SHCompactionMetrics {
    /// The rules on either side of the line, 12pt from it; its parts 7pt apart.
    public static let ruleGap: CGFloat = 12
    public static let partGap: CGFloat = 7
    public static let icon: CGFloat = 12
    public static let chevron: CGFloat = 9
    /// The summary card: 14pt above and below, 16pt at the sides, sections 12pt apart.
    public static let cardVertical: CGFloat = 14
    public static let cardHorizontal: CGFloat = 16
    public static let sectionGap: CGFloat = 12
    public static let copySize: CGFloat = 24
    /// The divider and the open summary, 14pt apart.
    public static let openGap: CGFloat = 14
    /// Show summary's line, which a touch target pads to 44pt.
    public static let toggleHeight: CGFloat = 16
}

/// One line where a compaction happened, like other thread events: rules on either side of an
/// icon, what happened ("Compacted automatically"), the context before and after in mono, and
/// Show summary, which opens what the agent kept in place. While it runs the words shimmer; an
/// overflow is said in `lanternText`; one that stopped changed nothing and offers no summary.
public struct SHCompactionDivider: View {
    public enum Tone: Equatable, Sendable { case normal, warning, quiet }

    let title: String
    let tokens: String?
    let tone: Tone
    let running: Bool
    /// nil when there is no summary to show.
    let expanded: Bool?
    let help: String?
    let toggle: () -> Void

    public init(title: String, tokens: String?, tone: Tone = .normal, running: Bool = false, expanded: Bool?, help: String? = nil,
                toggle: @escaping () -> Void = {}) {
        self.title = title
        self.tokens = tokens
        self.tone = tone
        self.running = running
        self.expanded = expanded
        self.help = help
        self.toggle = toggle
    }

    public var body: some View {
        // The one line when it fits; on a phone (or at a large text size) the rules go first,
        // then Show summary moves under the words, which wrap.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SHCompactionMetrics.ruleGap) {
                rule
                HStack(spacing: SHCompactionMetrics.partGap) {
                    words
                    summaryToggle(separated: true)
                }
                .lineLimit(1)
                .fixedSize()
                rule
            }
            HStack(spacing: SHCompactionMetrics.partGap) {
                words
                summaryToggle(separated: true)
            }
            .lineLimit(1)
            .fixedSize()
            VStack(spacing: SH.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: SHCompactionMetrics.partGap) { words }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                summaryToggle(separated: false)
            }
        }
        .frame(maxWidth: .infinity)
        .help(help ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// The glyph, what happened, and the sizes.
    @ViewBuilder private var words: some View {
        let sh = Color.sh
        let warning = tone == .warning
        if !running {
            Image(systemName: warning ? "exclamationmark.triangle" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: SHCompactionMetrics.icon - 1, weight: .medium))
                .foregroundStyle(warning ? sh.lanternText : sh.textTertiary)
        }
        Group {
            if running { Text(title).shShimmer() } else { Text(title) }
        }
        .font(.shSans(12)).foregroundStyle(warning ? sh.lanternText : sh.textSecondary)
        if let tokens { Text(tokens).font(.shMono(11)).foregroundStyle(sh.textTertiary).fixedSize() }
    }

    /// "· Show summary", or Hide summary while it is open.
    @ViewBuilder private func summaryToggle(separated: Bool) -> some View {
        let sh = Color.sh
        if let expanded {
            if separated { Text("·").font(.shSans(12)).foregroundStyle(sh.lineStrong) }
            Button(action: toggle) {
                HStack(spacing: SH.Space.xs) {
                    Text(expanded ? "Hide summary" : "Show summary").font(.shSans(12)).foregroundStyle(sh.textPrimary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: SHCompactionMetrics.chevron - 1, weight: .semibold))
                        .foregroundStyle(sh.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            // A 44pt target on touch; nothing changes on the Mac.
            .shTouchTarget(height: SHCompactionMetrics.toggleHeight)
            .accessibilityLabel(expanded ? "Hide what the agent kept" : "Show what the agent kept")
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.sh.lineSubtle).frame(height: 1).frame(maxWidth: .infinity)
    }
}

/// One section of what the agent kept.
public struct SHSummarySection: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var text: AttributedString
    /// "Files changed": names in mono, in a row.
    public var files: [String]

    public init(id: Int, title: String, text: AttributedString, files: [String] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.files = files
    }
}

/// What the agent kept (`CompactionSummary`): the agent's own summary in its sections, on a
/// sunken card, with its size and Copy.
public struct SHCompactionSummary: View {
    let size: String?
    let sections: [SHSummarySection]
    let copy: () -> Void

    public init(size: String?, sections: [SHSummarySection], copy: @escaping () -> Void) {
        self.size = size
        self.sections = sections
        self.copy = copy
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SHCompactionMetrics.sectionGap) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "text.alignleft").font(.system(size: SHCompactionMetrics.icon - 1, weight: .medium))
                    .foregroundStyle(sh.textTertiary)
                // The size beside the title when it fits; on a phone it goes under it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SH.Space.m) { title; meta }
                    VStack(alignment: .leading, spacing: SH.Space.xxs) { title; meta }
                }
                Spacer(minLength: SH.Space.m)
                Button(action: copy) {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                        .frame(width: SHCompactionMetrics.copySize, height: SHCompactionMetrics.copySize)
                }
                .buttonStyle(.shIcon(size: SHCompactionMetrics.copySize))
                .help("Copy summary")
                .accessibilityLabel("Copy summary")
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: section.files.isEmpty ? 3 : SH.Space.xs) {
                    if !section.title.isEmpty {
                        Text(section.title).font(.shSans(12, .semibold)).foregroundStyle(sh.textPrimary)
                    }
                    if section.files.isEmpty {
                        Text(section.text).font(.shSans(12.5)).lineSpacing(3).foregroundStyle(sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        SHFlowLayout(spacing: SH.Space.l, lineSpacing: SH.Space.xs) {
                            ForEach(section.files, id: \.self) { name in
                                Text(name).font(.shMono(11)).foregroundStyle(sh.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, SHCompactionMetrics.cardVertical)
        .padding(.horizontal, SHCompactionMetrics.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(fill: sh.bgSunken, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the agent kept")
    }

    private var title: some View {
        Text("What the agent kept").font(.shSans(12, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).fixedSize()
    }

    private var meta: some View {
        Text([size, "written by the agent"].compactMap { $0 }.joined(separator: " · "))
            .font(.shMono(10.5)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).fixedSize()
    }
}
