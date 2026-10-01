import SwiftUI
import ShepherdUI

/// Settings ▸ Pi ▸ Slash commands: the commands pi lists for the `/` menu on this Mac, grouped by
/// where each comes from, a switch on each. Off hides the command from the menu of every thread
/// here, in every client, and from nothing else: typing it still runs it. The groups come from the
/// model (derived once per change); the rows are lazy, so a long list builds what is on screen.
struct SlashCommandsSettings: View {
    let model: SlashCommandsModel
    @Bindable var settings: AppSettings

    var body: some View {
        let presentation = model.presentation
        SettingsPage(title: "Slash commands",
                     explanation: "The commands pi lists in the `/` menu of your agents, from its extensions, prompt templates and skills. Turn one off to hide it from the menu.") {
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
                        SettingsGroup(title: group.title, footnote: group.source == presentation.groups.last?.source ? Self.footnote : nil) {
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

    static let footnote = "Applies to the agents on this Mac, in every client that views them, the iPhone and iPad included. An off command is only hidden from the menu: typing its name still runs it. A command lists here once an agent's pi has reported it."

    /// No commands to draw: pi has listed none yet, or the search leaves none.
    @ViewBuilder private func emptyState(_ presentation: SlashCommandsPresentation) -> some View {
        SettingsGroup(title: "Commands", footnote: Self.footnote) {
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
        if row.unlisted { return "Hidden. No agent's pi lists it right now." }
        if !row.isOn { return "Hidden from the / menu. Typing it still runs it." }
        return row.description
    }
}

/// The words a row says about its switch.
enum SlashCommandWords {
    /// The row's tooltip.
    static func help(_ name: String, isOn: Bool) -> String {
        isOn ? "Listed in the / menu. Turn off to hide /\(name) from it; typing it still works."
             : "Hidden from the / menu. Typing /\(name) still runs it."
    }
}
