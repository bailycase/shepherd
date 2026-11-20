import SwiftUI

/// What was spent today (Fleet page, iPhone and iPad Home): the day's total in a line, and what each model added under it.
/// Strings in, so it knows nothing of how spend is counted; the caller says "est." where the cost is an estimate, and formats
/// the rows once, not per draw.
public struct SHSpendSummary<Row: Identifiable & Equatable>: View, Equatable {
    let title: String
    let total: String
    let rows: [Row]
    let name: KeyPath<Row, String>
    let value: KeyPath<Row, String>

    /// `rows` are drawn as they come; `name` and `value` say which strings of a row to show.
    public init(_ title: String, total: String, rows: [Row], name: KeyPath<Row, String>, value: KeyPath<Row, String>) {
        self.title = title
        self.total = total
        self.rows = rows
        self.name = name
        self.value = value
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                Text(total).font(.sh(.mono)).foregroundStyle(sh.textSecondary).monospacedDigit().lineLimit(1)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(row[keyPath: name]).font(.sh(.caption)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: SH.Space.m)
                    Text(row[keyPath: value]).font(.sh(.mono)).foregroundStyle(sh.textTertiary).monospacedDigit().lineLimit(1)
                }
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHListMetrics.cardRadius, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .combine)
    }
}
