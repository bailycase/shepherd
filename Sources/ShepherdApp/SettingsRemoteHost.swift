import SwiftUI
import ShepherdUI
import ShepherdRemote

// What is left of Settings' host picker. A fleet keeps every setting, instruction, MCP server, hook,
// subagent profile and space the same on every Mac, so no page of Settings is per host any more and
// the page for a remote host is gone. Skills still chooses a host while it keeps a copy per host (slice
// 2b-i moves it to the fleet's one copy and deletes this file with `settingsHostID`).

extension ShepherdViewModel {
    /// The remote hosts as Skills' picker sees them now.
    var settingsHosts: [SettingsHost] {
        remoteHosts.connections.map { connection in
            SettingsHost(id: connection.id, name: connection.config.name, client: connection.settingsClient,
                         capabilities: connection.capabilities)
        }
    }

    /// The remote host Skills shows; nil for this Mac (or a host since removed).
    var remoteSettingsHost: SettingsHost? {
        settingsHostID.flatMap { id in settingsHosts.first { $0.id == id } }
    }
}

/// "Host: This Mac ▾" over Skills, when there are remote hosts and it is per host.
struct SettingsHostPicker: View {
    var vm: ShepherdViewModel

    var body: some View {
        let hosts = vm.settingsHosts
        HStack(spacing: SH.Space.m) {
            Text("Host")
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(Color.sh.textSecondary)
            SHPopupMenu(vm.remoteSettingsHost?.name ?? "This Mac", minWidth: AppLayout.settingsPopupWidth) {
                Button("This Mac") { vm.settingsHostID = nil }
                Divider()
                ForEach(hosts) { host in
                    Button(host.isConnected ? host.name : "\(host.name) · offline") { vm.settingsHostID = host.id }
                }
            }
            .accessibilityLabel("Settings host")
            Spacer(minLength: 0)
        }
    }
}
