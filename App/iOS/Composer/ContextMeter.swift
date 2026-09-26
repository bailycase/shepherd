import SwiftUI
import UIKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The context meter on iPad and iPhone (ContextIdeas › A: its own circle, beside Send, in the
// same spot as on the Mac; a tap opens the details as a sheet), and compactions in the thread.
// The presentation is derived in ShepherdRemote once per change; this maps it onto ShepherdUI's
// components, as the Mac's `Thread/ContextMeter.swift` does.

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
        func kind(_ kind: NativeContextItem.Kind) -> ItemKind {
            switch kind {
            case .file: .file
            case .command: .command
            case .tool: .tool
            }
        }
        self.init(
            variant: variant, title: details.title, meta: details.meta, total: details.total, ofWindow: details.ofWindow,
            trailing: details.trailing, segments: details.segments.map { Segment(part: part($0.part), fraction: $0.fraction) },
            mark: details.mark, markLabel: details.markLabel,
            rows: details.rows.map { Row(part: part($0.part) ?? .system, label: $0.label, value: $0.value) },
            free: details.free,
            items: details.largest.map { Item(id: $0.entryID, kind: kind($0.kind), label: $0.label, value: $0.value) },
            note: details.note, emphasis: details.emphasis, footnote: details.footnote, showsSummary: details.summaryEntryID != nil,
            compactOffered: details.compactOffered)
    }
}

/// The ring beside Send. It reads only the store's meter, so it redraws when the usage changes
/// and never with a streamed chunk or a keystroke; equal inputs skip its body, whatever closure
/// the composer hands it. No ring from a host that reports no context.
struct ContextMeterButton: View, Equatable {
    let store: NativeThreadStore
    let expanded: Bool
    let open: () -> Void

    nonisolated static func == (lhs: ContextMeterButton, rhs: ContextMeterButton) -> Bool {
        lhs.store === rhs.store && lhs.expanded == rhs.expanded
    }

    var body: some View {
        if let meter = store.contextMeter {
            // The numbers are in the sheet: touch has no hover, and the composer never shows
            // text for the ring. A pointer over it on iPad shows them as on the Mac.
            NWContextMeterButton(NWContextRingState(meter.ring), expanded: expanded, help: meter.helpText,
                                 accessibilityLabel: meter.accessibilityLabel, action: open)
                .accessibilityHint("Shows what fills the context")
        }
    }
}

/// The ring's details as a sheet (ContextDetails, ContextFull, and the compacting and
/// just-compacted states). It closes itself when a compaction it showed is done, and when an
/// item it finds is shown in the thread.
struct ContextDetailsSheet: View {
    let store: NativeThreadStore
    let live: Bool
    /// Scrolls the thread to an entry (a tool result, a compaction).
    let find: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0
    /// Fitted to the details until the reader drags the sheet to the whole screen.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        let compacting = store.contextMeter?.ring == .compacting
        ScrollView {
            if let details = store.contextDetails {
                NWContextDetails(NWContextDetailsModel(details), actions: NWContextDetailsActions(
                    compact: { keep in Task { await store.compact(instructions: keep) } },
                    find: { id in
                        dismiss()
                        find(id)
                    },
                    showSummary: {
                        guard let id = details.summaryEntryID else { return }
                        store.compactions.expand(id)
                        dismiss()
                        find(id)
                    },
                    compactEnabled: live && store.supports("compact") && !store.running,
                    compactHelp: store.running ? "Compact once the agent has stopped: compacting ends its turn." : nil),
                    presentation: .sheet)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { new in
                    let fitted = detent != .large
                    height = new
                    if fitted { detent = .height(new) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Context")
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.nw.bgRaised)
        // As tall as the details (a keyboard for what to keep lifts the sheet), or the whole
        // screen when they are taller.
        .presentationDetents(height > 0 ? [.height(height), .large] : [.medium, .large], selection: $detent)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.nw.bgRaised)
        .onChange(of: compacting) { was, now in if was && !now { dismiss() } }
        .onChange(of: store.contextMeter == nil) { _, gone in if gone { dismiss() } }
        // Esc on a hardware keyboard closes it, as on the Mac.
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
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
                    UIPasteboard.general.string = row.summary ?? ""
                }
                .nwTransition(.content)
            }
        }
        .nwAnimation(.disclosure, value: open)
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

/// A request to bring a thread entry into view, from the context sheet (Largest, Show summary).
struct ThreadFindRequest: Equatable {
    let entryID: String
    let id = UUID()
}
