import SwiftUI
import ShepherdUI
import ShepherdRemote

/// A host's form (home track): name, address, port and token; Forget for a saved host. The
/// token goes to the Keychain; a blank token field keeps the saved one.
struct HostEditorScreen: View {
    let hostID: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.mobileApp) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var address = ""
    @State private var port = String(RemoteHostRecord.defaultPort)
    @State private var token = ""
    @State private var hasToken = false
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let host = hostID.flatMap(hosts.host) {
                Section {
                    LabeledContent("Connection") {
                        NWStatusPill(host.phase.isConnected ? .done : host.phase == .connecting ? .running : .failed,
                                     label: host.phase.word)
                    }
                    if let failure = host.phase.failure {
                        VStack(alignment: .leading, spacing: NW.Space.xxs) {
                            Text(failure.message(host: host.name)).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                            Text(failure.detail).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                    if !host.phase.isConnected {
                        Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(host.id) }
                    }
                }
            }
            Section {
                LabeledContent("Name") {
                    TextField("My Mac", text: $name).multilineTextAlignment(.trailing)
                }
                LabeledContent("Address") {
                    TextField("hostname or IP", text: $address)
                        .keyboardType(.URL).font(.nw(.mono)).multilineTextAlignment(.trailing)
                }
                LabeledContent("Port") {
                    TextField(String(RemoteHostRecord.defaultPort), text: $port)
                        .keyboardType(.numberPad).font(.nw(.mono)).multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField(hasToken ? "Saved" : "Required", text: $token)
                        .privacySensitive().font(.nw(.mono)).multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Turn on Settings ▸ Remote ▸ Serve this Mac in Shepherd on the host and copy its token. Use a trusted LAN or VPN: there is no TLS.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            if hostID != nil {
                Section {
                    Button("Forget host", role: .destructive) { confirmingForget = true }
                }
            }
        }
        .listRowBackground(Color.nw.bgRaised)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.nw(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle(hostID == nil ? "Add host" : "Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented from Home or More, the form is a sheet's root and needs its own way out.
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
        .onAppear(perform: load)
        .onDisappear { token = "" }
    }

    private func load() {
        guard let id = hostID, let host = hosts.host(id) else { return }
        name = host.record.name
        address = host.record.address
        port = String(host.record.port)
        hasToken = (try? hosts.token(for: id))??.isEmpty == false
    }

    private func save() {
        do {
            let entry = try RemoteHostEntry(name: name, address: address, port: port, token: token, requireToken: hostID == nil || !hasToken)
            if let id = hostID { try hosts.edit(id, entry) } else { try hosts.add(entry) }
            token = ""
            dismiss()
        } catch let problem as RemoteHostEntry.Problem {
            error = problem.description
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forget() {
        guard let id = hostID else { return }
        do {
            try app?.forget(host: id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
