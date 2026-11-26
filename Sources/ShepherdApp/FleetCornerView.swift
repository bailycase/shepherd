import SwiftUI
import ShepherdCore
import ShepherdRemote
import ShepherdUI

// The sidebar's Fleet corner (FleetCornerFull, FleetCornerMin, FleetCornerMany, FleetCornerManyMin), the footer of both sidebar styles: a header with
// how many Macs are awake, a row per Mac that matters now, and a minimized line. Plain values in (`FleetCorner`); what a tap does is the caller's.

struct FleetCornerView: View, Equatable {
    let corner: FleetCorner
    let minimized: Bool
    /// The Fleet page is on screen, and the Mac it was opened on.
    let onPage: Bool
    let focusedMac: UUID?
    /// A Mac's row (its id), or the header and the folded row (nil): the Fleet page.
    let open: (UUID?) -> Void
    let setMinimized: (Bool) -> Void
    let settings: () -> Void
    /// The version Sparkle found, while it waits: `SHUpdateButton` takes the gear's place (UpdateFooterStates).
    var updateVersion: String? = nil
    var update: () -> Void = {}

    nonisolated static func == (a: FleetCornerView, b: FleetCornerView) -> Bool {
        a.corner == b.corner && a.minimized == b.minimized && a.onPage == b.onPage && a.focusedMac == b.focusedMac
            && a.updateVersion == b.updateVersion
    }

    var body: some View {
        Group {
            if minimized {
                minimizedLine
            } else {
                // The boards' `.flt`: the header, a row per Mac that matters now, and the rest folded.
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(corner.rows) { row in
                        MacRow(row: row, selected: onPage && focusedMac == row.id) { open(row.id) }
                    }
                    if let more = corner.more { moreRow(more) }
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.top, SH.Space.s)
                .padding(.bottom, SH.Space.m)
                .overlay(alignment: .top) { SHHairline() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.disclosure, value: minimized)
    }

    // MARK: Full

    private var header: some View {
        HStack(spacing: SH.Space.xs) {
            Button { open(nil) } label: {
                HStack(spacing: SH.Space.m) {
                    Text("Fleet").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                    Text(corner.headline)
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(corner.accessibilityLabel)
            .accessibilityHint("Opens the Fleet page")
            minimizeButton
            settingsButton
        }
        .padding(.leading, SH.Space.m)
        .frame(height: AppLayout.fleetCornerHeaderHeight)
        .background(onPage && focusedMac == nil ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
    }

    private func moreRow(_ more: FleetCorner.More) -> some View {
        Button { open(nil) } label: {
            HStack(spacing: SH.Space.s) {
                Text(more.text).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.sh(.micro, weight: .semibold)).foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: AppLayout.fleetCornerRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(more.text) Macs")
        .accessibilityHint("Opens the Fleet page")
    }

    // MARK: Minimized

    /// The boards' `.foot`: the Mac glyph, how many are awake, Show Fleet and the gear, on one 44pt line.
    private var minimizedLine: some View {
        HStack(spacing: SH.Space.m) {
            Button { open(nil) } label: {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: SHSidebarMetrics.footerGlyph - 2))
                        .foregroundStyle(Color.sh.textSecondary)
                        .frame(width: SHSidebarMetrics.footerGlyph)
                        .accessibilityHidden(true)
                    Text(corner.summary).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fleet, \(corner.summary)\(corner.alert ? ", a Mac can't take work" : "")")
            .accessibilityHint("Opens the Fleet page")
            if corner.alert {
                SHStatusDot(.failed, size: AppLayout.fleetDotSize)
                    .accessibilityHidden(true)
            }
            HStack(spacing: SHSidebarMetrics.topBarButtonGap) {
                minimizeButton
                settingsButton
            }
        }
        .padding(.leading, SHSidebarMetrics.footerLeading)
        .padding(.trailing, SHSidebarMetrics.topBarTrailing)
        .frame(height: SHSidebarMetrics.footerHeight)
        // On the Fleet page the line is a selected pill, inset 6pt at its sides and bottom (the boards' `.foot.on`).
        .background {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(onPage && focusedMac == nil ? Color.sh.bgSelected : .clear)
                .padding(.horizontal, SH.Space.s)
                .padding(.bottom, SH.Space.s)
        }
    }

    // MARK: Parts

    private var minimizeButton: some View {
        Button { withSHAnimation(.disclosure) { setMinimized(!minimized) } } label: {
            SHTurningChevron(isOpen: !minimized, closed: .up, open: .down)
        }
        .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar, tint: .sh.textTertiary))
        .shHelp(minimized ? "Show Fleet" : "Minimize Fleet")
        .accessibilityLabel(minimized ? "Show Fleet" : "Minimize Fleet")
    }

    @ViewBuilder private var settingsButton: some View {
        if let updateVersion {
            SHUpdateButton(version: updateVersion, action: update)
        } else {
            Button(action: settings) { Image(systemName: "gearshape") }
                .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
                .shHelp("Fleet settings")
                .accessibilityLabel("Fleet settings")
        }
    }
}

/// A Mac of the corner (the boards' `.flr`): its dot, its name, and its state at the end.
private struct MacRow: View {
    let row: FleetCorner.Row
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: AppLayout.fleetCornerRowGap) {
                dot
                Text(row.name)
                    .font(.sh(.ui))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.xs)
                Text(row.state)
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .shContentTransition(.crossFade)
                    .shAnimation(.content, value: row.state)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: AppLayout.fleetCornerRowHeight)
            .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens it on the Fleet page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The boards' `.gd`: `textSecondary` awake, hollow asleep, red when it can't take work.
    @ViewBuilder private var dot: some View {
        let size = AppLayout.fleetCornerDot
        switch row.dot {
        case .awake, .connecting: Circle().fill(Color.sh.textSecondary).frame(width: size, height: size)
        case .blocked: Circle().fill(Color.sh.failed).frame(width: size, height: size)
        case .asleep:
            Circle().strokeBorder(Color.sh.textTertiary, lineWidth: AppLayout.fleetCornerDotStroke)
                .frame(width: size, height: size)
        }
    }
}
