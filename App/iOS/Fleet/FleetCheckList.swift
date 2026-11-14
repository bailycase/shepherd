import SwiftUI
import ShepherdRemote
import ShepherdUI

/// Fleet ▸ Check on the phone and the iPad (FleetCheck's grid, in list form): what the fleet's work needs, row by row, and what each Mac has of it.
/// Read only: a device sees the findings and changes nothing; fixing is the Mac's page. Plain values in (`FleetCheckPage`, the same the Mac draws).
struct FleetCheckList: View {
    let check: FleetCheckPage
    var capitals = false

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            Text(check.summary).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
            if check.groups.isEmpty {
                Text("Nothing to compare yet. Each Mac looks at itself soon after it joins, and again every day.")
                    .shText(.caption).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
            }
            ForEach(check.groups) { group in
                FleetSectionLabel(title: group.name, capitals: capitals)
                SHListCard {
                    ForEach(group.rows) { row in FleetCheckRowView(row: row, columns: check.columns).equatable() }
                }
            }
            Text(check.footer).shText(.caption).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
        }
    }
}

/// One thing the fleet needs: its name and why, then a line per Mac.
private struct FleetCheckRowView: View, Equatable {
    let row: FleetCheckRow
    let columns: [FleetCheckColumn]

    nonisolated static func == (a: FleetCheckRowView, b: FleetCheckRowView) -> Bool { a.row == b.row && a.columns == b.columns }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
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
