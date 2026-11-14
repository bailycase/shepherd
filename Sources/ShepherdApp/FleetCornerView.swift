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

    nonisolated static func == (a: FleetCornerView, b: FleetCornerView) -> Bool {
        a.corner == b.corner && a.minimized == b.minimized && a.onPage == b.onPage && a.focusedMac == b.focusedMac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if minimized { minimizedLine } else { header }
            if !minimized {
                ForEach(corner.rows) { row in
                    MacRow(row: row, selected: onPage && focusedMac == row.id) { open(row.id) }
                }
                if let more = corner.more { moreRow(more) }
            }
        }
        .padding(.horizontal, SH.Space.s)
        .padding(.top, SH.Space.s)
        .padding(.bottom, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { SHHairline() }
        .shAnimation(.disclosure, value: minimized)
    }

    // MARK: Full

    private var header: some View {
        HStack(spacing: SH.Space.xs) {
            Button { open(nil) } label: {
                HStack(spacing: SH.Space.s) {
                    glyph(.sh(.ui, weight: .regular))
                    Text("Fleet").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                    Text(corner.headline)
                        .font(.sh(.micro, weight: .regular))
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
        .padding(.leading, SH.Space.s)
        .padding(.trailing, SH.Space.xxs)
        .frame(height: AppLayout.fleetCornerHeaderHeight)
        .background(onPage && focusedMac == nil ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
    }

    private func moreRow(_ more: FleetCorner.More) -> some View {
        Button { open(nil) } label: {
            HStack(spacing: SH.Space.s) {
                Circle().strokeBorder(Color.sh.lineStrong, lineWidth: AppLayout.fleetCornerDotStroke)
                    .frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                Text(more.text).font(.sh(.caption, weight: .regular)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.sh(.micro, weight: .semibold)).foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SH.Space.s)
            .frame(height: AppLayout.fleetCornerRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(more.text) Macs")
        .accessibilityHint("Opens the Fleet page")
    }

    // MARK: Minimized

    private var minimizedLine: some View {
        HStack(spacing: SH.Space.xs) {
            Button { open(nil) } label: {
                HStack(spacing: SH.Space.m) {
                    glyph(.sh(.title, weight: .regular))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Fleet").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        Text(corner.summary).font(.sh(.caption, weight: .regular)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    }
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
            minimizeButton
            settingsButton
        }
        .padding(.leading, SH.Space.s)
        .padding(.trailing, SH.Space.xxs)
        .frame(minHeight: AppLayout.fleetCornerMinHeight)
        .background(onPage && focusedMac == nil ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
    }

    // MARK: Parts

    private func glyph(_ font: Font) -> some View {
        Image(systemName: "display")
            .font(font)
            .foregroundStyle(Color.sh.textPrimary)
            .frame(width: AppLayout.fleetFooterGlyph)
            .accessibilityHidden(true)
    }

    private var minimizeButton: some View {
        Button { withSHAnimation(.disclosure) { setMinimized(!minimized) } } label: {
            SHTurningChevron(isOpen: !minimized, closed: .up, open: .down)
        }
        .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
        .shHelp(minimized ? "Show Fleet" : "Minimize Fleet")
        .accessibilityLabel(minimized ? "Show Fleet" : "Minimize Fleet")
    }

    private var settingsButton: some View {
        Button(action: settings) { Image(systemName: "gearshape") }
            .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
            .shHelp("Fleet settings")
            .accessibilityLabel("Fleet settings")
    }
}

/// A Mac of the corner: its dot, name in mono, room gauge and state.
private struct MacRow: View {
    let row: FleetCorner.Row
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SH.Space.s) {
                dot
                Text(row.name)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .frame(width: AppLayout.fleetCornerNameWidth, alignment: .leading)
                FleetGauge(fraction: row.load, color: row.gauge.fillColor, height: AppLayout.fleetMetricBarHeight)
                    .frame(width: AppLayout.fleetCornerGaugeWidth)
                Spacer(minLength: SH.Space.xs)
                Text(row.state)
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .shContentTransition(.crossFade)
                    .shAnimation(.content, value: row.state)
            }
            .padding(.horizontal, SH.Space.s)
            .frame(height: AppLayout.fleetCornerRowHeight)
            .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens it on the Fleet page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var dot: some View {
        switch row.dot {
        case .awake: SHStatusDot(.done, size: AppLayout.fleetDotSize)
        case .connecting: SHStatusDot(.running, size: AppLayout.fleetDotSize)
        case .blocked: SHStatusDot(.failed, size: AppLayout.fleetDotSize)
        case .asleep:
            Circle().strokeBorder(Color.sh.textTertiary, lineWidth: AppLayout.fleetCornerDotStroke)
                .frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
        }
    }
}
