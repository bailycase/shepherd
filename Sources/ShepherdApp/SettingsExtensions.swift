import SwiftUI
import ShepherdCore
import ShepherdUI

/// Settings ▸ Extensions (SettingsExtensions, SettingsPiDesignReferences): the pi extensions Shepherd
/// bundles, with a switch for each. Peer tools need no separate permission setting.
struct ExtensionsSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(title: "Extensions", explanation: "Control the extensions included with Shepherd.") {
            SettingsGroup(title: "Bundled extensions",
                          footnote: "Applies to agents launched on this Mac, including automations and remote agents. Running agents keep their extensions until restarted. Status and session tracking are always on.") {
                SettingsRow(title: "Terminals and agent tools",
                            subtitle: "Let agents open and drive terminals, message or spawn agents, manage automations and send notifications.") {
                    SettingsSwitch(label: "Terminals and agent tools", isOn: $settings.piPanesExtension)
                }
                SettingsRow(title: "Diff review tool", subtitle: "Let agents open the review pane with `review_diff`.") {
                    SettingsSwitch(label: "Diff review tool", isOn: $settings.piReviewExtension)
                }
                SettingsRow(title: "MCP servers", subtitle: "Let agents use the servers in Settings ▸ MCP servers, with tool search.") {
                    SettingsSwitch(label: "MCP servers", isOn: $settings.piMCPExtension)
                }
                SettingsRow(title: "Browser tools",
                            subtitle: "Let agents open pages in their thread's Browser, read and click through them, and take screenshots.") {
                    SettingsSwitch(label: "Browser tools", isOn: $settings.piBrowserExtension)
                }
                if settings.designToolEnabled {
                    SettingsRow(title: "Design references",
                                subtitle: "Let a thread read the design pieces you hand it with `design_get`. Only a thread you sent one to gets the tool.") {
                        SettingsSwitch(label: "Design references", isOn: $settings.piDesignReferences)
                    }
                }
            }
        }
    }
}
