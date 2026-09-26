import SwiftUI

/// Compaction in the thread (ContextIdeas › In the thread, ContextCompacted).
public enum NWCompactionMetrics {
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
public struct NWCompactionDivider: View {
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
            HStack(spacing: NWCompactionMetrics.ruleGap) {
                rule
                HStack(spacing: NWCompactionMetrics.partGap) {
                    words
                    summaryToggle(separated: true)
                }
                .lineLimit(1)
                .fixedSize()
                rule
            }
            HStack(spacing: NWCompactionMetrics.partGap) {
                words
                summaryToggle(separated: true)
            }
            .lineLimit(1)
            .fixedSize()
            VStack(spacing: NW.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: NWCompactionMetrics.partGap) { words }
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
        let nw = Color.nw
        let warning = tone == .warning
        if !running {
            Image(systemName: warning ? "exclamationmark.triangle" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: NWCompactionMetrics.icon - 1, weight: .medium))
                .foregroundStyle(warning ? nw.lanternText : nw.textTertiary)
        }
        Group {
            if running { Text(title).nwShimmer() } else { Text(title) }
        }
        .font(.nwSans(12)).foregroundStyle(warning ? nw.lanternText : nw.textSecondary)
        if let tokens { Text(tokens).font(.nwMono(11)).foregroundStyle(nw.textTertiary).fixedSize() }
    }

    /// "· Show summary", or Hide summary while it is open.
    @ViewBuilder private func summaryToggle(separated: Bool) -> some View {
        let nw = Color.nw
        if let expanded {
            if separated { Text("·").font(.nwSans(12)).foregroundStyle(nw.lineStrong) }
            Button(action: toggle) {
                HStack(spacing: NW.Space.xs) {
                    Text(expanded ? "Hide summary" : "Show summary").font(.nwSans(12)).foregroundStyle(nw.textPrimary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: NWCompactionMetrics.chevron - 1, weight: .semibold))
                        .foregroundStyle(nw.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            // A 44pt target on touch; nothing changes on the Mac.
            .nwTouchTarget(height: NWCompactionMetrics.toggleHeight)
            .accessibilityLabel(expanded ? "Hide what the agent kept" : "Show what the agent kept")
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.nw.lineSubtle).frame(height: 1).frame(maxWidth: .infinity)
    }
}

/// One section of what the agent kept.
public struct NWSummarySection: Equatable, Sendable, Identifiable {
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
public struct NWCompactionSummary: View {
    let size: String?
    let sections: [NWSummarySection]
    let copy: () -> Void

    public init(size: String?, sections: [NWSummarySection], copy: @escaping () -> Void) {
        self.size = size
        self.sections = sections
        self.copy = copy
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NWCompactionMetrics.sectionGap) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "text.alignleft").font(.system(size: NWCompactionMetrics.icon - 1, weight: .medium))
                    .foregroundStyle(nw.textTertiary)
                // The size beside the title when it fits; on a phone it goes under it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NW.Space.m) { title; meta }
                    VStack(alignment: .leading, spacing: NW.Space.xxs) { title; meta }
                }
                Spacer(minLength: NW.Space.m)
                Button(action: copy) {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                        .frame(width: NWCompactionMetrics.copySize, height: NWCompactionMetrics.copySize)
                }
                .buttonStyle(.nwIcon(size: NWCompactionMetrics.copySize))
                .help("Copy summary")
                .accessibilityLabel("Copy summary")
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: section.files.isEmpty ? 3 : NW.Space.xs) {
                    if !section.title.isEmpty {
                        Text(section.title).font(.nwSans(12, .semibold)).foregroundStyle(nw.textPrimary)
                    }
                    if section.files.isEmpty {
                        Text(section.text).font(.nwSans(12.5)).lineSpacing(3).foregroundStyle(nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        NWFlowLayout(spacing: NW.Space.l, lineSpacing: NW.Space.xs) {
                            ForEach(section.files, id: \.self) { name in
                                Text(name).font(.nwMono(11)).foregroundStyle(nw.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, NWCompactionMetrics.cardVertical)
        .padding(.horizontal, NWCompactionMetrics.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(fill: nw.bgSunken, line: nw.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the agent kept")
    }

    private var title: some View {
        Text("What the agent kept").font(.nwSans(12, .semibold)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).fixedSize()
    }

    private var meta: some View {
        Text([size, "written by the agent"].compactMap { $0 }.joined(separator: " · "))
            .font(.nwMono(10.5)).foregroundStyle(Color.nw.textTertiary).lineLimit(1).fixedSize()
    }
}
