import SwiftUI
import ShepherdUI
import ShepherdCore

/// Home's header: what every host's threads spent today, and what each model added (`FleetModel.spendToday`, derived once). Nothing
/// while nothing was spent.
struct SpendToday: View {
    let spend: SpendSummary?

    var body: some View {
        if let spend {
            SHSpendSummary("Spent today", total: spend.total, rows: spend.rows, name: \.name, value: \.value).equatable()
        }
    }
}
