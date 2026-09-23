import SwiftUI

/// One run's segment in the strip.
public struct NWRunsStripCell: Identifiable, Equatable, Sendable {
    /// The run, as `open` receives it.
    public var id: String
    public var name: String
    public var state: AgentState
    /// Replaces the state's word ("Paused" for a paused run, which draws as waiting).
    public var stateLabel: String?

    public init(id: String, name: String, state: AgentState, stateLabel: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.stateLabel = stateLabel
    }

    /// The run's word in the strip's tally ("running", "paused", "needs you").
    public var word: String { (stateLabel ?? state.label).lowercased() }
    /// The segment's tooltip: "worker, running".
    public var help: String { "\(name), \(word)" }
    /// "worker, running — open".
    public var accessibilityLabel: String { "\(help) — open" }
}

/// Many live sibling runs, folded to one row.
public struct NWRunsStripSummary: Equatable, Sendable {
    /// "12 subagents".
    public var title: String
    /// The glyph's state: needs you, else running, else queued, else failed, else done.
    public var state: AgentState
    /// One segment per run, in spawn order.
    public var cells: [NWRunsStripCell]
    /// "7 done · 3 running · 1 queued · 1 needs you · 1 failed": runs counted as their cells
    /// draw them.
    public var states: String
    /// "3.6m tok"; nil when no run reported tokens.
    public var tokens: String?
    /// The group's span: from the first start, live until `until` is set.
    public var since: Date?
    public var until: Date?

    public init(title: String, state: AgentState, cells: [NWRunsStripCell], states: String, tokens: String? = nil,
                since: Date? = nil, until: Date? = nil) {
        self.title = title
        self.state = state
        self.cells = cells
        self.states = states
        self.tokens = tokens
        self.since = since
        self.until = until
    }
}

/// More than three sibling runs fold into one row in the ledger header's form: glyph, count,
/// one segment per run, the state tally, tokens and the group's elapsed time, and a disclosure
/// that shows every card. Runs that need you keep their own card under it. Each segment opens
/// its run; the rest of the row expands and collapses the cards.
public struct NWRunsStrip: View, Equatable {
    let summary: NWRunsStripSummary
    @Binding var isExpanded: Bool
    let open: (String) -> Void
    /// The expansion when built, for `==`.
    private let expanded: Bool
    @State private var hovered: String?

    /// `open` receives a segment's run id.
    public init(_ summary: NWRunsStripSummary, isExpanded: Binding<Bool>, open: @escaping (String) -> Void) {
        self.init(summary, isExpanded: isExpanded, hovered: nil, open: open)
    }

    /// `hovered` starts a segment hovered, for previews.
    init(_ summary: NWRunsStripSummary, isExpanded: Binding<Bool>, hovered: String?, open: @escaping (String) -> Void) {
        self.summary = summary
        self._isExpanded = isExpanded
        self.open = open
        self.expanded = isExpanded.wrappedValue
        self._hovered = State(initialValue: hovered)
    }

    public nonisolated static func == (a: NWRunsStrip, b: NWRunsStrip) -> Bool {
        a.summary == b.summary && a.expanded == b.expanded
    }

    public var body: some View {
        let nw = Color.nw
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 10) {
                NWBranchGlyph(summary.state, size: 13)
                Text(summary.title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1).fixedSize()
                    .nwContentTransition(.numeric())
                NWStepStrip(summary.cells.map(\.state), segmentWidth: NWRunLayout.stripCellWidth).fixedSize()
                    .anchorPreference(key: NWRunsStripSegmentsKey.self, value: .bounds) { $0 }
                Text(summary.states).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                    .nwContentTransition(.numeric())
                    .layoutPriority(2)
                Spacer(minLength: NW.Space.m)
                // The tally ("1 needs you") outranks the totals: tokens go first, then the time.
                // Which of them fits follows the width at once.
                ViewThatFits(in: .horizontal) {
                    totals(tokens: summary.tokens)
                    totals(tokens: nil)
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                .layoutPriority(1)
                .nwInstant()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .nwAnimation(.disclosure, value: isExpanded)
            }
            // Runs changing state recolor their steps and roll the tally.
            .nwAnimation(.content, value: summary.cells.map(\.state))
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: NWRunLayout.headerHeight)
            .background(nw.bgSunken)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityLabel("\(summary.title), \(summary.states)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the cards" : "Shows every card")
        // The segments' targets sit over the row rather than inside its button, so each is a
        // button of its own (a click, a tooltip, VoiceOver, keyboard focus) and a click
        // anywhere else still toggles the row.
        .overlayPreferenceValue(NWRunsStripSegmentsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let strip = proxy[anchor]
                    ForEach(Array(summary.cells.enumerated()), id: \.element.id) { index, cell in
                        let target = Self.target(index, strip: strip, height: proxy.size.height)
                        segment(cell)
                            .frame(width: target.width, height: target.height)
                            .position(x: target.midX, y: target.midY)
                    }
                }
            }
        }
    }

    private func segment(_ cell: NWRunsStripCell) -> some View {
        Button { open(cell.id) } label: {
            ZStack {
                // At rest the target draws nothing: the strip underneath is the segment.
                if hovered == cell.id {
                    RoundedRectangle(cornerRadius: NWStepStrip.cornerRadius)
                        .fill(NWStepStrip.fill(cell.state))
                        .frame(width: NWRunLayout.stripCellWidth, height: NWRunLayout.stripHoverHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = cell.id } else if hovered == cell.id { hovered = nil }
        }
        .nwAnimation(.hover, value: hovered == cell.id)
        .help(cell.help)
        .accessibilityLabel(cell.accessibilityLabel)
    }

    /// Segment `index`'s click target, in the space `strip` (the segments' bounds) is measured
    /// in: the segment and half the gap on each side, so the targets tile the strip with no
    /// dead gap, and the row's full height.
    static func target(_ index: Int, strip: CGRect, height: CGFloat,
                       segmentWidth: CGFloat = NWRunLayout.stripCellWidth) -> CGRect {
        let gap = NWStepStrip.spacing
        return CGRect(x: strip.minX - gap / 2 + CGFloat(index) * (segmentWidth + gap), y: 0,
                      width: segmentWidth + gap, height: height)
    }

    private func totals(tokens: String?) -> some View {
        HStack(spacing: 0) {
            if let tokens { Text(tokens) }
            if let since = summary.since {
                if tokens != nil { Text(" · ") }
                NWElapsedText(since: since, until: summary.until)
            }
        }
        .fixedSize()
    }
}

/// Where the strip's segments sit inside its row.
private struct NWRunsStripSegmentsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
