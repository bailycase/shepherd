import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A paired host's page: its connection, its name (the only thing to edit), its address and port as
/// paired, and Forget. Adding a host is `HostPairScreen`: a code, never an address or a token. Updating Shepherd on a Mac is
/// Fleet ▸ Check's (`FleetCheckList`), where the Mac's build is compared with the fleet's.
struct HostEditorScreen: View {
    let hostID: UUID?

    var body: some View {
        if let hostID {
            HostPage(hostID: hostID)
        } else {
            HostPairScreen()
        }
    }
}

private struct HostPage: View {
    let hostID: UUID
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.mobileApp) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let host = hosts.host(hostID) {
                Section {
                    LabeledContent("Connection") {
                        SHStatusPill(host.phase.isConnected ? .done : host.phase == .connecting ? .running : .failed,
                                     label: host.phase.word)
                    }
                    if let failure = host.phase.failure {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(failure.message(host: host.name)).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                            Text(failure.detail).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                    if host.phase.failure?.kind == .sharedTokenRetired {
                        Button("Add a Mac", systemImage: "plus") { navigator.present(.settings(.host(nil))) }
                    } else if !host.phase.isConnected {
                        Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(host.id) }
                    }
                    if host.phase.isConnected, host.supports(RemoteProtocol.hostSettingsBackgroundServiceCapability),
                       let line = HostSettingsPresentation.backgroundService(settings(of: host.id), host: host.name) {
                        Text(line).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    }
                }
                Section {
                    LabeledContent("Name") {
                        TextField("My Mac", text: $name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Address") {
                        Text("\(host.record.address):\(String(host.record.port))")
                            .font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                    }
                } footer: {
                    Text("Paired with a code. If a Mac revokes this device, add that Mac again with a new code.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                Section {
                    Button("Forget host", role: .destructive) { confirmingForget = true }
                }
            }
        }
        .listRowBackground(Color.sh.bgRaised)
        .font(.sh(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented from Home or More, the page is a sheet's root and needs its own way out.
            if navigator.presented?.route == .settings(.host(hostID)) {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .alert("Could not save the host", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Forget this host and delete its token?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget host", role: .destructive, action: forget)
        }
        .onAppear { name = hosts.host(hostID)?.record.name ?? "" }
        .task { await SettingsStore.of(hosts).watch() }
    }

    /// The host's settings, once Settings has read them.
    private func settings(of id: UUID) -> HostSettings? {
        let store = SettingsStore.of(hosts)
        return store.hosts.first { $0.id == id }.flatMap(store.hostSettings.settings(of:))
    }

    private func save() {
        guard let host = hosts.host(hostID) else { return dismiss() }
        do {
            let entry = try RemoteHostEntry(name: name, address: host.record.address, port: String(host.record.port), token: nil)
            try hosts.edit(hostID, entry)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forget() {
        Task {
            do {
                try await app?.forget(host: hostID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
