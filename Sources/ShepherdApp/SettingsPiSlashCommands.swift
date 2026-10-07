import SwiftUI
import ShepherdUI

/// Settings ▸ Slash commands (SettingsPiSlashCommands): the commands pi lists on this Mac, grouped
/// by where each comes from, a switch on each. Off disables the command in every thread here, in
/// every client: it leaves the `/` menu, and typing it is refused. The groups come from the model
/// (derived once per change); the rows are lazy, so a long list builds what is on screen.
struct SlashCommandsSettings: View {
    let model: SlashCommandsModel
    @Bindable var settings: AppSettings

    var body: some View {
        let presentation = model.presentation
        SettingsPage(title: "Slash commands",
                     explanation: "Commands supplied by extensions, prompt templates and skills. Turn one off to disable it entirely, including when typed directly.") {
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                HStack(spacing: NW.Space.xl) {
                    NWSearchField("Search commands", text: Binding(get: { model.query }, set: { model.query = $0 }))
                        .frame(width: AppLayout.slashSearchWidth)
                    Spacer(minLength: NW.Space.l)
                    Text(presentation.summary)
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textTertiary)
                        .lineLimit(1)
                        .accessibilityLabel("Commands: \(presentation.summary)")
                }
                if presentation.groups.isEmpty {
                    emptyState(presentation)
                } else {
                    ForEach(presentation.groups) { group in
                        SettingsGroup(title: group.title) {
                            // One lazy list in the group's card: its rows are built as they scroll in.
                            LazyVStack(spacing: 0) {
                                ForEach(group.rows) { row in
                                    SlashCommandListRow(row: row, first: row.id == group.rows.first?.id) {
                                        settings.setSlashCommand(row.name, on: $0)
                                    }
                                    .equatable()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: settings.hiddenSlashCommands, initial: true) { _, names in model.setHidden(names) }
    }

    /// No commands to draw: pi has listed none yet, or the search leaves none.
    @ViewBuilder private func emptyState(_ presentation: SlashCommandsPresentation) -> some View {
        SettingsGroup(title: "Commands") {
            SettingsActionRow(leading: {
                Text(presentation.total == 0
                     ? "No commands yet. pi reports its commands when an agent starts, so they list here once one is running."
                     : "No command matches “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(.nw(.body))
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }, actions: { EmptyView() })
        }
    }
}

/// One command: its name in mono with what it takes after it, its description under, and its
/// switch. Compares by what it draws, so a switch redraws its own row and no other.
private struct SlashCommandListRow: View, Equatable {
    let row: SlashCommandRow
    let first: Bool
    let set: (Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.first == b.first }

    var body: some View {
        let _ = NWRenderProbe.tick("slashCommands.row")
        let nw = Color.nw
        HStack(alignment: .center, spacing: NW.Space.xxl) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                HStack(spacing: NW.Space.m) {
                    Text("/" + row.name)
                        .font(.nwMono(AppLayout.skillsNameSize, .semibold))
                        .foregroundStyle(row.isOn ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                    if let arguments = row.arguments {
                        Text(arguments)
                            .font(.nwMono(AppLayout.skillsMetaSize))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(1)
                    }
                }
                if let line = detail {
                    Text(line)
                        .font(.nwSans(AppLayout.skillsSummarySize))
                        .foregroundStyle(row.isOn ? nw.textSecondary : nw.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(label: "/" + row.name, isOn: Binding(get: { row.isOn }, set: set))
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NW.Space.xl)
        .frame(minHeight: AppLayout.slashRowMinHeight)
        .overlay(alignment: .top) { if !first { NWHairline() } }
        .help(SlashCommandWords.help(row.name, isOn: row.isOn))
        .accessibilityElement(children: .contain)
    }

    /// Its description; once off, what off means, since the description would not say.
    private var detail: String? {
        row.isOn ? row.description : SlashCommandWords.disabled
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
