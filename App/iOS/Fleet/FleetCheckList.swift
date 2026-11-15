import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Fleet ▸ Check on the phone and the iPad (FleetCheck's grid, in list form): what the fleet's work needs, row by row, and what each Mac has of it.
/// A device sees the findings and changes nothing but one thing: it may ask a Mac whose Shepherd is behind to update itself (the Shepherd row's Update,
/// an action on that Mac like starting a thread there); fixing the rest is the Mac's page. Plain values in (`FleetCheckPage`, the same the Mac draws).
struct FleetCheckList: View {
    let check: FleetCheckPage
    var capitals = false
    /// What Update and Cancel do; nil while the Mac this page is read from can't be asked (an older Shepherd): the row then draws no Update.
    var updates: Updates?

    struct Updates {
        var start: (UUID, FleetUpdateWhen) -> Void
        var cancel: (UUID) -> Void
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            Text(check.summary).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
            if check.groups.isEmpty {
                Text("Nothing to compare yet. Each Mac looks at itself soon after it joins, and again every day.")
                    .font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
            }
            ForEach(check.groups) { group in
                FleetSectionLabel(title: group.name, capitals: capitals)
                SHListCard {
                    ForEach(group.rows) { row in
                        FleetCheckRowView(row: row, columns: check.columns, offers: row.id == "build" && updates != nil ? check.updateOffers : [], updates: updates).equatable()
                    }
                }
            }
            Text(check.footer).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
        }
    }
}

/// One thing the fleet needs: its name and why, then a line per Mac.
private struct FleetCheckRowView: View, Equatable {
    let row: FleetCheckRow
    let columns: [FleetCheckColumn]
    /// Update Shepherd on a Mac, for the Shepherd row of the Macs that are behind.
    let offers: [FleetUpdateOffer]
    let updates: FleetCheckList.Updates?

    nonisolated static func == (a: FleetCheckRowView, b: FleetCheckRowView) -> Bool { a.row == b.row && a.columns == b.columns && a.offers == b.offers }

    var body: some View {
        // One view per row, whatever it carries: the Shepherd row's Update rows sit under it, in the same element.
        VStack(alignment: .leading, spacing: 0) {
            content
            if let updates {
                ForEach(offers, id: \.mac) { offer in
                    FleetUpdateRow(offer: offer, updates: updates)
                }
            }
        }
    }

    private var content: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.name).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary)
                Text(row.why).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary)
            }
            ForEach(Array(zip(columns, row.cells).enumerated()), id: \.offset) { _, pair in
                let (column, cell) = pair
                HStack(spacing: SH.Space.m) {
                    FleetDot(color: cell.dotColor)
                    Text(column.name).font(.sh(.ui, weight: .regular)).foregroundStyle(column.isAsleep ? sh.textTertiary : sh.textSecondary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Text(cell.text).font(.sh(.ui, weight: .regular)).foregroundStyle(cell.textColor).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(zip(columns, row.cells).map { "\($0.name): \($1.text)" }.joined(separator: ", "))
    }
}

/// Update Shepherd on one Mac that is behind: what is ready, Update, and while the host carries it out the state it is in, with Cancel.
private struct FleetUpdateRow: View {
    let offer: FleetUpdateOffer
    let updates: FleetCheckList.Updates

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let running = offer.running {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    HStack(spacing: SH.Space.s) {
                        FleetDot(color: sh.running)
                        Text(running.state).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.running)
                    }
                    Text(running.note).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textSecondary)
                    if running.cancellable {
                        Button("Cancel") { updates.cancel(offer.mac) }
                            .buttonStyle(.sh(.secondary, size: .l))
                            .accessibilityLabel("Cancel updating \(offer.macName)")
                    }
                }
                .padding(SH.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sh.runningTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .accessibilityElement(children: .contain)
            } else {
                if offer.canStart {
                    Text(offer.headline).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                    Button(offer.buttonTitle) { updates.start(offer.mac, .idle) }
                        .buttonStyle(.sh(.primary, size: .l))
                }
                Text(offer.note).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary)
                if offer.canStart, let now = offer.nowTitle {
                    Button(now) { updates.start(offer.mac, .now) }.buttonStyle(.sh(.ghost, size: .l))
                }
                if let problem = offer.problem {
                    Text(problem).font(.sh(.caption, weight: .regular)).foregroundStyle(offer.failed ? sh.failed : sh.textSecondary)
                }
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension FleetCheckCell {
    /// The cell's words: lantern for what needs something, quiet for what isn't needed or comes from an asleep Mac.
    @MainActor var textColor: Color {
        let sh = Color.sh
        return switch tone {
        case .ok: sh.textPrimary
        case .warn: sh.lanternText
        case .fixing: sh.running
        case .none, .old: sh.textTertiary
        }
    }

    @MainActor var dotColor: Color {
        let sh = Color.sh
        return switch tone {
        case .ok: sh.done
        case .warn: sh.lantern
        case .fixing: sh.running
        case .none: sh.lineStrong
        case .old: sh.textTertiary
        }
    }
}
