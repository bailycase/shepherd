import SwiftUI
import ShepherdCore
import ShepherdUI

/// Settings ▸ Tools: the MCP servers every agent can use, the extensions Shepherd bundles, and a way
/// into the slash commands.
struct ToolsSettings: View {
    var vm: ShepherdViewModel
    var store: MCPStore
    @Bindable var settings: AppSettings
    /// Opens Settings ▸ Slash commands.
    let manageSlashCommands: () -> Void

    var body: some View {
        MCPSettings(vm: vm, store: store, initiallyExpanded: nil, title: "Tools") {
            ExtensionsSettings(settings: settings)
            ExtensionsSettingsGroup(model: vm.yourPi, auth: vm.piAuth)
            SettingsGroup(title: "Slash commands") {
                SettingsDrillRow(title: "Commands in the / menu", subtitle: vm.slashCommands.presentation.summary,
                                 value: "Manage", action: manageSlashCommands)
            }
        }
        .shControlScale(.settings)
    }
}

/// The pi extensions Shepherd bundles, with a switch for each. Peer tools need no separate
/// permission setting.
struct ExtensionsSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsGroup(title: "Built in") {
            SettingsRow(title: "Terminals and agent tools", subtitle: "Panes, notifications, automations") {
                SettingsSwitch(label: "Terminals and agent tools", isOn: $settings.piPanesExtension)
            }
            SettingsRow(title: "Diff review") {
                SettingsSwitch(label: "Diff review tool", isOn: $settings.piReviewExtension)
            }
            SettingsRow(title: "MCP servers", subtitle: "Tool search for the servers above") {
                SettingsSwitch(label: "MCP servers", isOn: $settings.piMCPExtension)
            }
            SettingsRow(title: "Browser", subtitle: "Screenshots and clicks") {
                SettingsSwitch(label: "Browser tools", isOn: $settings.piBrowserExtension)
            }
            SettingsRow(title: "Subscription usage", subtitle: "Anthropic and OpenAI Codex limits in Sign-in") {
                SettingsSwitch(label: "Subscription usage", isOn: $settings.piUsageExtension)
            }
            if settings.designToolEnabled {
                SettingsRow(title: "Design references") {
                    SettingsSwitch(label: "Design references", isOn: $settings.piDesignReferences)
                }
            }
        }
    }
}
