import SwiftUI
import ShepherdUI
import ShepherdCore

/// Home's header: what every host's threads spent today, and what each model added (`FleetModel.spendToday`). Nothing while nothing was spent.
struct SpendToday: View {
    let spend: SpendRollup

    var body: some View {
        if let total = SpendFormat.line(spend) {
            SHSpendSummary("Spent today", total: total, rows: spend.models.map { .init(id: $0.id, name: $0.name, value: $0.text) })
        }
    }
}
