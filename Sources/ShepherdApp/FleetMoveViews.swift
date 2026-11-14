import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Moving a thread to another Mac (FleetMove board): the header's host chip with its menu and its confirmation, the card a move draws above
// the conversation, and "moved from" after it. Plain values in (`FleetMovePresentation`); what a pick does is the caller's.

@MainActor private func moveTone(_ tone: FleetTone) -> Color {
    let sh = Color.sh
    return switch tone {
    case .good: sh.done
    case .warn: sh.lantern
    case .bad: sh.failed
    default: sh.textTertiary
    }
}

/// The header's chip: a dot and the Mac the thread runs on, a chevron, and the menu it opens ("Runs on / Move to").
struct FleetMoveChipView: View, Equatable {
    let header: FleetMoveHeader
    /// Whether a turn is running: a pick then asks first.
    var working = false
    /// What the confirmation says of what runs; read when it opens.
    var confirmFacts: (String) -> FleetMoveConfirm = { FleetMoveConfirm.make(running: nil, host: $0) }
    var move: (UUID, FleetMoveRequest.When) -> Void = { _, _ in }
    @State private var open = false
    @State private var asking: FleetMoveMenu.Target?

    nonisolated static func == (a: FleetMoveChipView, b: FleetMoveChipView) -> Bool { a.header == b.header && a.working == b.working }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Button { if !header.busy { open.toggle() } } label: {
                HStack(spacing: SH.Space.s) {
                    Circle().fill(moveTone(header.chip.tone)).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                    Text(header.chip.text).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    SHChipChevron()
                }
                .padding(.horizontal, SH.Space.m)
                .frame(height: AppLayout.fleetHeaderPillHeight)
                .background(open ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .shBorder(sh.lineStrong, radius: SH.Radius.s)
                .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
            }
            .buttonStyle(.plain)
            .disabled(header.busy)
            .help(header.busy ? "This thread is moving" : "Runs on \(header.chip.text). Move to another Mac")
            .accessibilityLabel(header.chip.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $open, arrowEdge: .bottom) { popover }
            if let movedFrom = header.chip.movedFrom {
                Text(movedFrom).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var popover: some View {
        if let target = asking {
            FleetMoveConfirmView(host: target.name, facts: confirmFacts(target.name),
                                 whenDone: { open = false; asking = nil; move(target.id, .whenDone) },
                                 now: { open = false; asking = nil; move(target.id, .now) })
                .onDisappear { asking = nil }
        } else {
            FleetMoveMenuView(menu: header.menu) { target in
                if working { asking = target } else { open = false; move(target.id, .now) }
            }
        }
    }
}

/// "Runs on" and "Move to": This Mac with its load, then every other Mac with its room bar and a note, and the footnote.
struct FleetMoveMenuView: View {
    let menu: FleetMoveMenu
    let pick: (FleetMoveMenu.Target) -> Void

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            caption("Runs on")
            HStack(spacing: SH.Space.m) {
                Circle().fill(moveTone(menu.here.tone)).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                Text(menu.here.name).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                Spacer(minLength: 0)
                Text(menu.here.detail).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
            .accessibilityElement(children: .combine)
            SHHairline().padding(.vertical, SH.Space.s)
            caption("Move to")
            ForEach(menu.targets) { target in
                Button { pick(target) } label: {
                    HStack(spacing: SH.Space.m) {
                        Circle().fill(moveTone(target.tone)).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(target.name).font(.sh(.ui, weight: .regular)).foregroundStyle(target.enabled ? sh.textPrimary : sh.textTertiary)
                            Text(target.note).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Capsule().fill(sh.lineSubtle)
                            .frame(width: AppLayout.fleetMoveBarWidth, height: AppLayout.fleetMoveBarHeight)
                            .overlay(alignment: .leading) {
                                Capsule().fill(sh.done)
                                    .frame(width: AppLayout.fleetMoveBarWidth * max(0, min(1, target.room)), height: AppLayout.fleetMoveBarHeight)
                            }
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.shRow())
                .disabled(!target.enabled)
                .opacity(target.enabled ? 1 : AppLayout.fleetAsleepOpacity)
                .accessibilityLabel(target.accessibilityLabel)
            }
            Text(FleetMoveMenu.footnote)
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.Space.l)
                .padding(.top, SH.Space.m)
                .padding(.bottom, SH.Space.s)
        }
        .padding(SH.Space.s)
        .frame(width: AppLayout.fleetMoveMenuWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move this thread")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.shMono(AppLayout.fleetTagFont, .medium)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.l)
            .padding(.top, SH.Space.s)
            .padding(.bottom, SH.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "It's running a command": Move when it's done, or Stop and move.
struct FleetMoveConfirmView: View {
    let host: String
    let facts: FleetMoveConfirm
    let whenDone: () -> Void
    let now: () -> Void

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            Text(facts.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
            Text(facts.message).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.m) {
                Spacer(minLength: 0)
                Button("Move when it’s done", action: whenDone).buttonStyle(.sh(.secondary, size: .s))
                Button("Stop and move", action: now).buttonStyle(.sh(.strong, size: .s))
            }
        }
        .padding(SH.Space.xl)
        .frame(width: AppLayout.fleetMoveMenuWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move while working")
    }
}

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
