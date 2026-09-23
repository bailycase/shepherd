import SwiftUI

/// One finished run in a ledger.
public struct NWRunLedgerEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: AgentState
    /// One line: what it did, or why it failed.
    public var summary: String
    /// "5 files · 41m".
    public var meta: String

    public init(id: String, name: String, state: AgentState, summary: String, meta: String) {
        self.id = id
        self.name = name
        self.state = state
        self.summary = summary
        self.meta = meta
    }
}

/// A finished group of runs, as the ledger shows it.
public struct NWRunLedgerSummary: Equatable, Sendable {
    /// "3 subagents".
    public var title: String
    /// The header glyph's state: done, or failed when any run failed.
    public var state: AgentState
    /// "all done · 45m".
    public var status: String
    /// The group's combined diff; hidden when zero.
    public var added: Int
    public var removed: Int
    /// In spawn order.
    public var entries: [NWRunLedgerEntry]

    public init(title: String, state: AgentState, status: String, added: Int, removed: Int, entries: [NWRunLedgerEntry]) {
        self.title = title
        self.state = state
        self.status = status
        self.added = added
        self.removed = removed
        self.entries = entries
    }
}

/// The permanent record of a finished run group (Agents board): a header on `bgSunken` (glyph,
/// title, one step per run, status, combined diff) and one row per run. Selecting a row opens
/// it in the inspector; the selected row is tinted with a running rule on the pane side.
public struct NWRunLedger: View, Equatable {
    let ledger: NWRunLedgerSummary
    @Binding var selection: String?
    /// The selection when built, for `==`.
    private let selected: String?

    public init(_ ledger: NWRunLedgerSummary, selection: Binding<String?>) {
        self.ledger = ledger
        self._selection = selection
        self.selected = selection.wrappedValue
    }

    public nonisolated static func == (a: NWRunLedger, b: NWRunLedger) -> Bool {
        a.ledger == b.ledger && a.selected == b.selected
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            header
            ForEach(ledger.entries) { entry in
                NWHairline()
                NWRunLedgerRow(entry: entry, selected: entry.id == selection) { selection = entry.id }
            }
        }
        .frame(maxWidth: .infinity)
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        let nw = Color.nw
        return HStack(spacing: 10) {
            NWBranchGlyph(ledger.state, size: 13)
            Text(ledger.title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1).fixedSize()
            NWStepStrip(ledger.entries.map(\.state), segmentWidth: NWRunLayout.stepWidth).fixedSize()
            Text(ledger.status).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
            Spacer(minLength: NW.Space.m)
            if ledger.added + ledger.removed > 0 {
                NWDiffStat(added: ledger.added, removed: ledger.removed, font: .nwMono(11))
            }
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWRunLayout.headerHeight)
        .background(nw.bgSunken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ledger.title), \(ledger.status)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NWRunLedgerRow: View {
    let entry: NWRunLedgerEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: 10) {
                NWStatusDot(entry.state)
                Text(entry.name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    .frame(width: NWRunLayout.nameWidth * ThemeStore.shared.textScale, alignment: .leading)
                Text(entry.summary).font(.nw(.ui, weight: .regular))
                    .foregroundStyle(entry.state == .failed ? nw.failed : nw.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.meta).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).monospacedDigit().lineLimit(1).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? nw.running : nw.textTertiary)
            }
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: NW.Height.rowComfortable)
            .background(selected ? nw.runningTint : hovering ? nw.bgHover : .clear)
            .overlay(alignment: .trailing) {
                if selected { nw.running.frame(width: NWRunLayout.selectionRule) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel("\(entry.name), \(entry.state.label), \(entry.summary)")
        .accessibilityValue(entry.meta)
        .accessibilityHint("Opens the run in the inspector")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The ledger's and runs strip's own dimensions (Agents board).
enum NWRunLayout {
    static let headerHeight: CGFloat = 32
    static let stepWidth: CGFloat = 14
    /// The strip holds many runs, so its steps are narrower.
    static let stripCellWidth: CGFloat = 8
    static let nameWidth: CGFloat = 70
    static let selectionRule: CGFloat = 2
}
