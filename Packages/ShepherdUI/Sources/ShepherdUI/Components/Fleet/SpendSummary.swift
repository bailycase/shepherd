import SwiftUI

/// What was spent today (Fleet page, iPhone and iPad Home): the day's total in a line, and what each model added under it.
/// Plain strings in, so it knows nothing of how spend is counted; the caller says "est." where the cost is an estimate.
public struct SHSpendSummary: View, Equatable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let value: String

        public init(id: String, name: String, value: String) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    let title: String
    let total: String
    let rows: [Row]

    public init(_ title: String, total: String, rows: [Row] = []) {
        self.title = title
        self.total = total
        self.rows = rows
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
                    Text(row.name).font(.sh(.caption)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: SH.Space.m)
                    Text(row.value).font(.sh(.mono)).foregroundStyle(sh.textTertiary).monospacedDigit().lineLimit(1)
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
