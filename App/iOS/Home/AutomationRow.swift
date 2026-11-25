import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// An automation run as the iPad sidebar lists it: read-only here;
/// the Automations screen (automations track) is where they are managed.
struct AutomationRow: View, Equatable {
    let row: FleetAutomationRow
    var selected = false

    var body: some View {
        // iPadSidebar: the run's name and its state in a word.
        SHListRow(row.name, trailing: .meta(row.stateWord.sentenceCased), chevron: false, selected: selected,
                  dimmed: row.offline || !row.enabled, compact: true)
            .accessibilityHint(row.run == nil ? "" : "Opens its run")
    }
}
