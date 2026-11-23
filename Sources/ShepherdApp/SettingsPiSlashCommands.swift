import SwiftUI
import ShepherdUI

/// Settings ▸ Slash commands (SettingsPiSlashCommands): the commands pi lists on this Mac, grouped
/// by where each comes from, a switch on each. Off disables the command in every thread here, in
/// every client: it leaves the `/` menu, and typing it is refused. The groups come from the model
/// (derived once per change); the rows are lazy, so a long list builds what is on screen.
struct SlashCommandsSettings: View {
    enum Filter: Hashable { case all, on, off }

    let model: SlashCommandsModel
    @Bindable var settings: AppSettings
    @State private var filter: Filter = .all

    var body: some View {
        let presentation = model.presentation
        let all = presentation.groups.flatMap(\.rows)
        SettingsPage(title: "Slash commands") {
            SettingsGroup(title: "") {
                SettingsFilterRow(label: "Show", selection: $filter, options: [
                    (.all, "All \(presentation.total)"),
                    (.on, "On \(presentation.total - presentation.hidden)"),
                    (.off, "Off \(presentation.hidden)"),
                ])
            }
            if all.isEmpty {
                SettingsGroup(title: "Commands") {
                    SettingsRow(title: "No commands yet", subtitle: "pi lists its commands when an agent starts, so they appear once one is running.") { EmptyView() }
                }
            }
            ForEach(presentation.groups) { group in
                let rows = group.rows.filter { filter == .all || (filter == .on) == $0.isOn }
                if !rows.isEmpty {
                    SettingsGroup(title: group.title,
                                  footnote: group.id == presentation.groups.last?.id ? "Off removes a command from the / menu and refuses it if typed." : nil,
                                  lazy: true) {
                        ForEach(rows) { row in
                            SlashCommandListRow(row: row) { settings.setSlashCommand(row.name, on: $0) }
                                .equatable()
                        }
                    }
                }
            }
        }
        .onChange(of: settings.hiddenSlashCommands, initial: true) { _, names in model.setHidden(names) }
    }
}

/// One command: compares by what it draws, so a switch redraws its own row and no other.
private struct SlashCommandListRow: View, Equatable {
    let row: SlashCommandRow
    let set: (Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row }

    var body: some View {
        let _ = SHRenderProbe.tick("slashCommands.row")
        SettingsRow(title: "/" + row.name, subtitle: row.description ?? row.arguments, mono: true) {
            SettingsSwitch(label: "/" + row.name, isOn: Binding(get: { row.isOn }, set: set))
        }
        .help(SlashCommandWords.help(row.name, isOn: row.isOn))
    }
}

/// The words a row says about its switch.
enum SlashCommandWords {
    /// The row's tooltip.
    static func help(_ name: String, isOn: Bool) -> String {
        isOn ? "Turn off to disable /\(name) in every thread, typed or picked from the / menu."
             : "Disabled. /\(name) can't be invoked until you turn it back on."
    }

    /// An off row's line under its name.
    static let disabled = "Disabled. Cannot be invoked until re-enabled."
}
