import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The pages of Settings that gather what the phone kept apart (iPhone and iPad boards): each names
// and groups its sections as the Mac's page of the same name does.

/// Settings ▸ Models: sign-in, then what new threads and small jobs use.
struct ModelsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        SettingsPageScaffold("Models", store: store) {
            ProviderSections(store: store)
            ModelDefaultsSections(store: store)
        }
    }
}

/// Settings ▸ Agents: the queue, the threads a thread starts, context, and subagents.
struct AgentsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        SettingsPageScaffold("Agents", store: store) {
            AgentSettingsSections(store: store)
        }
    }
}

/// Settings ▸ Tools: MCP servers, then the extensions and slash commands.
struct ToolsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        SettingsPageScaffold("Tools", store: store) {
            MCPSections(store: store)
            ExtensionSections(store: store)
        }
    }
}

/// The last row of Agents' Subagents card: the profiles' names and count; opens them.
struct SubagentProfilesRow: View {
    let store: SettingsStore
    let host: SettingsHost
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let config = store.hostConfig
        if config.canRead(host) {
            let profiles = config.profiles[host.id]
            Button { navigator.open(.settings(.subagents)) } label: {
                SettingsNavRow("Profiles", note: profiles.map { $0.map(\.name).joined(separator: ", ") },
                               value: profiles.map { String($0.count) })
            }
            .buttonStyle(.shRow(radius: 0))
            .task(id: store.refreshes) { await config.refresh(.subagents, on: host) }
        }
    }
}
