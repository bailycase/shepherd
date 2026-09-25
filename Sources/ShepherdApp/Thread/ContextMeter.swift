import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The context meter (ContextIdeas › A: its own circle, beside Send), its details popover, and
// compactions in the thread. The presentation is derived in ShepherdRemote once per change;
// this maps it onto ShepherdUI's components.

extension EnvironmentValues {
    /// The thread's compaction lines: which show what the agent kept.
    @Entry var compactionExpansion: NativeCompactionExpansion? = nil
}

extension NWContextRingState {
    init(_ ring: NativeContextMeter.Ring) {
        switch ring {
        case .empty: self = .empty
        case .compacting: self = .compacting
        case .estimated: self = .estimated
        case .fill(let fraction, let tone): self = .fill(fraction, NWContextTone(tone))
        }
    }
}

extension NWContextTone {
    init(_ tone: NativeContextMeter.Tone) {
        switch tone {
        case .calm: self = .calm
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }
}

extension NWContextDetailsModel.ItemKind {
    init(_ kind: NativeContextItem.Kind) {
        switch kind {
        case .file: self = .file
        case .command: self = .command
        case .tool: self = .tool
        }
    }
}

extension NWCompactionDivider.Tone {
    init(_ tone: NativeCompactionRow.Tone) {
        switch tone {
        case .normal: self = .normal
        case .warning: self = .warning
        case .quiet: self = .quiet
        }
    }
}

extension NWContextDetailsModel {
    init(_ details: NativeContextDetails) {
        let variant: Variant = switch details.variant {
        case .empty: .empty
        case .simple: .simple
        case .split: .split
        case .almostFull: .almostFull
        case .compacted: .compacted
        case .compacting(let started): .compacting(startedAt: Date(timeIntervalSince1970: started / 1000))
        }
        func part(_ part: NativeContextDetails.Part?) -> Part? {
            switch part {
            case .system?: .system
            case .instructions?: .instructions
            case .messages?: .messages
            case .toolResults?: .toolResults
            case nil: nil
            }
        }
        self.init(
            variant: variant, title: details.title, meta: details.meta, total: details.total, ofWindow: details.ofWindow,
            trailing: details.trailing, segments: details.segments.map { Segment(part: part($0.part), fraction: $0.fraction) },
            mark: details.mark, markLabel: details.markLabel,
            rows: details.rows.map { Row(part: part($0.part) ?? .system, label: $0.label, value: $0.value) },
            free: details.free,
            items: details.largest.map { item in
                Item(id: item.entryID, kind: ItemKind(item.kind), label: item.label, value: item.value)
            },
            note: details.note, emphasis: details.emphasis, footnote: details.footnote, showsSummary: details.summaryEntryID != nil,
            compactOffered: details.compactOffered)
    }
}

/// The ring beside Send. It reads only the store's meter, so it redraws when the usage changes
/// and never with a streamed chunk or a keystroke; equal inputs (the same store, the details open
/// or not) skip its body, whatever closure the control row hands it.
struct ContextMeterButton: View, Equatable {
    let store: NativeThreadStore
    let expanded: Bool
    let toggle: () -> Void

    nonisolated static func == (lhs: ContextMeterButton, rhs: ContextMeterButton) -> Bool {
        lhs.store === rhs.store && lhs.expanded == rhs.expanded
    }

    var body: some View {
        let _ = NWRenderProbe.tick("composer.contextMeter")
        if let meter = store.contextMeter {
            NWContextMeterButton(NWContextRingState(meter.ring), expanded: expanded, help: meter.helpText,
                                 accessibilityLabel: meter.accessibilityLabel, action: toggle)
                // 32pt, as the board draws it, in a row of 28pt controls without growing the row.
                .padding(.vertical, -(NWContextMetrics.buttonSize - NWComposerMetrics.actionSize) / 2)
        }
    }
}

/// The details the ring opens, above it (ContextDetails): Esc or a click outside closes it,
/// and it closes itself when a compaction it showed is done.
struct ContextDetailsPopover: View {
    let store: NativeThreadStore
    let active: Bool
    /// Scrolls the thread to an entry (a tool result, a compaction).
    let find: (String) -> Void
    let close: () -> Void

    var body: some View {
        if let details = store.contextDetails {
            let compacting = store.contextMeter?.ring == .compacting
            NWContextDetails(NWContextDetailsModel(details), actions: NWContextDetailsActions(
                compact: { keep in Task { await store.compact(instructions: keep) } },
                find: { id in find(id) },
                showSummary: {
                    guard let id = details.summaryEntryID else { return }
                    store.compactions.expand(id)
                    find(id)
                },
                compactEnabled: active && store.supports("compact") && !store.running,
                compactHelp: store.running ? "Compact once the agent has stopped: compacting ends its turn." : nil))
            .onExitCommand(perform: close)
            .onChange(of: compacting) { was, now in if was && !now { close() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context")
        }
    }
}

/// A compaction where it happened, and what the agent kept, opened in place.
struct CompactionItem: View {
    let row: NativeCompactionRow
    @Environment(\.compactionExpansion) private var expansion
    @State private var ownExpanded = false

    private var expanded: Bool { expansion?.isExpanded(row.id) ?? ownExpanded }

    var body: some View {
        let open = expanded && !row.sections.isEmpty
        VStack(alignment: .leading, spacing: NWCompactionMetrics.openGap) {
            NWCompactionDivider(
                title: row.title, tokens: row.tokens,
                tone: NWCompactionDivider.Tone(row.tone),
                running: row.running, expanded: row.sections.isEmpty ? nil : open, help: row.error) {
                if let expansion { expansion.toggle(row.id) } else { ownExpanded.toggle() }
            }
            if open {
                NWCompactionSummary(size: row.summarySize,
                                    sections: row.sections.map { NWSummarySection(id: $0.id, title: $0.title, text: $0.text, files: $0.files) }) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.summary ?? "", forType: .string)
                }
                .nwTransition(.content)
            }
        }
        .padding(.vertical, NW.Space.xs)
        .nwAnimation(.disclosure, value: open)
    }
}
