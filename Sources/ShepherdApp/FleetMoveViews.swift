import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdSidebar

// Moving a thread to another Mac (FleetMove board): the card a move draws above the conversation, and "Move to Mac" in a thread's menu. Plain values in (`FleetMovePresentation`); what a pick does is the caller's.

/// The card a move draws above the conversation (FleetMoving): its steps while it goes, one line while it waits for the turn to end, or why it
/// stopped. Raised in the conversation's column, not a band across the window.
struct FleetMoveCardView: View, Equatable {
    let card: FleetMoveCard
    var cancel: (UUID) -> Void = { _ in }
    var dismiss: (UUID) -> Void = { _ in }

    nonisolated static func == (a: FleetMoveCardView, b: FleetMoveCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.l) {
                Text(card.title)
                    .font(.sh(.ui, weight: card.phase == .queued ? .regular : .semibold))
                    .foregroundStyle(card.phase == .queued ? sh.textSecondary : sh.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if card.canCancel {
                    Button("Cancel") { cancel(card.id) }.buttonStyle(.shTextAction)
                        .padding(.vertical, -SH.Space.xs)
                } else if card.phase == .failed {
                    Button("Dismiss") { dismiss(card.id) }.buttonStyle(.shTextAction)
                        .padding(.vertical, -SH.Space.xs)
                }
            }
            switch card.phase {
            case .queued:
                EmptyView()
            case .failed:
                if let detail = card.detail {
                    Text(detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            case .moving:
                Text(FleetMoveMenu.footnote)
                    .font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary)
                    .lineSpacing(AppLayout.fleetProseSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SH.Space.s)
                ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in
                    let later = step.mark == .later
                    HStack(spacing: SH.Space.m) {
                        Text(step.text).font(.sh(.ui, weight: .regular)).foregroundStyle(later ? sh.textTertiary : sh.textPrimary)
                        if !step.meta.isEmpty {
                            Text(step.meta).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: SH.Space.m)
                        Text(step.mark == .done ? "Done" : step.mark == .current ? "Now" : "Next")
                            .font(.sh(.caption, weight: step.mark == .current ? .medium : .regular))
                            .foregroundStyle(step.mark == .current ? sh.textPrimary : sh.textTertiary)
                    }
                    .frame(minHeight: AppLayout.fleetMoveStepHeight)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.text)\(step.meta.isEmpty ? "" : ", \(step.meta)"), \(step.mark == .done ? "done" : step.mark == .current ? "now" : "next")")
                }
            }
        }
        .padding(AppLayout.fleetMoveCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SH.Space.xxl)
        .padding(.top, SH.Space.l)
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

/// The menu behind "on mini ⌄" in a thread's title (GXRemote): where the thread runs, a row to move it to each other Mac of the fleet (the
/// ones that can't take it greyed out with why), and the thread that sent it. Plain values in; what a row does is the caller's.
struct RemoteThreadMenu: View {
    let host: String
    /// "Moved from This Mac · 14:02", after a move.
    var movedFrom: String?
    var online = true
    /// The Macs it could move to; empty where it can't move (no fleet, a host that can't, a thread that isn't an ordinary one).
    var targets: [FleetMoveMenu.Target] = []
    /// A move of this thread is going or waits.
    var busy = false
    var sender: String?
    var openSender: (() -> Void)?
    let moveTo: (FleetMoveMenu.Target) -> Void
    let close: () -> Void

    var body: some View {
        SHPopMenu(width: AppLayout.remoteMenuWidth) {
            SHPopMenuHeader(online ? "Running on \(host)" : "Running on \(host) · offline")
            if let movedFrom { SHPopMenuHeader(movedFrom) }
            ForEach(targets) { target in
                SHPopMenuRow("Move to \(target.name)", trailing: target.enabled ? nil : target.note, enabled: target.enabled && !busy) {
                    close()
                    moveTo(target)
                }
                .help(target.enabled ? "\(target.note). \(FleetMoveMenu.footnote)" : target.note)
                .accessibilityLabel(target.accessibilityLabel)
            }
            if let sender {
                if !targets.isEmpty { SHPopMenuSeparator() }
                SHPopMenuRow(sender, prefix: "Sent by", chevron: true, enabled: openSender != nil) {
                    close()
                    openSender?()
                }
                .help(openSender == nil ? "That thread isn’t on a Mac this one can see" : "Open \(sender)")
            }
        }
    }
}
