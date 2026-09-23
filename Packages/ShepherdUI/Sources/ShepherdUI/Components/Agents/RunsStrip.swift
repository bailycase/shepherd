import SwiftUI

/// Many live sibling runs, folded to one row.
public struct NWRunsStripSummary: Equatable, Sendable {
    /// "12 subagents".
    public var title: String
    /// The glyph's state: needs you, else running, else queued, else failed, else done.
    public var state: AgentState
    /// One step per run, in spawn order.
    public var cells: [AgentState]
    /// "7 done · 3 running · 1 queued · 1 needs you · 1 failed": runs counted as their cells
    /// draw them.
    public var states: String
    /// "3.6m tok"; nil when no run reported tokens.
    public var tokens: String?
    /// The group's span: from the first start, live until `until` is set.
    public var since: Date?
    public var until: Date?

    public init(title: String, state: AgentState, cells: [AgentState], states: String, tokens: String? = nil,
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
/// one step per run, the state tally, tokens and the group's elapsed time, and a disclosure
/// that shows every card. Runs that need you keep their own card under it.
public struct NWRunsStrip: View, Equatable {
    let summary: NWRunsStripSummary
    @Binding var isExpanded: Bool
    /// The expansion when built, for `==`.
    private let expanded: Bool

    public init(_ summary: NWRunsStripSummary, isExpanded: Binding<Bool>) {
        self.summary = summary
        self._isExpanded = isExpanded
        self.expanded = isExpanded.wrappedValue
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
                NWStepStrip(summary.cells, segmentWidth: NWRunLayout.stripCellWidth).fixedSize()
                Text(summary.states).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                    .layoutPriority(2)
                Spacer(minLength: NW.Space.m)
                // The tally ("1 needs you") outranks the totals: tokens go first, then the time.
                ViewThatFits(in: .horizontal) {
                    totals(tokens: summary.tokens)
                    totals(tokens: nil)
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                .layoutPriority(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
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
