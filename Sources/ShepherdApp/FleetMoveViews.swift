import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Moving a thread to another Mac (FleetMove board): the card a move draws above the conversation, and "Move to Mac" in a thread's menu. Plain values in (`FleetMovePresentation`); what a pick does is the caller's.

/// The card a move draws above the conversation: its steps while it goes, one line while it waits for the turn to end, or why it stopped.
struct FleetMoveCardView: View, Equatable {
    let card: FleetMoveCard
    var cancel: (UUID) -> Void = { _ in }
    var dismiss: (UUID) -> Void = { _ in }

    nonisolated static func == (a: FleetMoveCardView, b: FleetMoveCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            switch card.phase {
            case .queued:
                HStack(spacing: SH.Space.l) {
                    Text(card.title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { cancel(card.id) }.buttonStyle(.sh(.secondary, size: .s))
                }
            case .failed:
                HStack(alignment: .top, spacing: SH.Space.l) {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text(card.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                        if let detail = card.detail {
                            Text(detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Dismiss") { dismiss(card.id) }.buttonStyle(.sh(.secondary, size: .s))
                }
            case .moving:
                Text(card.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in
                    let color = step.mark == .later ? sh.textTertiary : step.mark == .current ? sh.textPrimary : sh.textSecondary
                    HStack(spacing: SH.Space.m) {
                        Text(step.mark == .done ? "✓" : step.mark == .current ? "●" : "○")
                            .frame(width: AppLayout.fleetMoveMarkWidth).foregroundStyle(color).accessibilityHidden(true)
                        Text(step.text).font(.sh(.ui, weight: .regular)).foregroundStyle(color)
                        if !step.meta.isEmpty {
                            Text(step.meta).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.text)\(step.meta.isEmpty ? "" : ", \(step.meta)"), \(step.mark == .done ? "done" : step.mark == .current ? "now" : "next")")
                }
            }
        }
        .padding(.horizontal, SH.Space.xxl)
        .padding(.vertical, card.phase == .moving ? SH.Space.l : SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// "Move to Mac" in a thread's menu: every Mac it can go to, the ones that can't take it greyed out with why in their help.
struct FleetMoveMenuItems: View {
    var vm: ShepherdViewModel
    let row: SidebarRowID

    var body: some View {
        if let header = vm.fleetMoveHeader(for: row), !header.busy {
            Menu("Move to Mac") {
                ForEach(header.menu.targets) { target in
                    Button(target.name) { vm.requestFleetMove(row, to: target) }
                        .disabled(!target.enabled)
                        .help(target.note)
                }
            }
        }
    }
}
