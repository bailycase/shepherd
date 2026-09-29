import SwiftUI
import ShepherdSessions
import ShepherdUI

@MainActor @Observable
final class CLIProxyAPIModel {
    var server = ""
    var key = ""
    private(set) var snapshot: CLIProxyAPIStore.Snapshot?
    private(set) var busy = false
    private(set) var problem: String?
    @ObservationIgnored private let store: CLIProxyAPIStore?

    init(pi: PiSetup) { store = CLIProxyAPIStore(pi: pi) }

    init(preview: CLIProxyAPIStore.Snapshot?, problem: String? = nil) {
        store = nil
        snapshot = preview
        server = preview?.baseURL ?? ""
        self.problem = problem
    }

    func load() async {
        guard let store, !busy else { return }
        do {
            snapshot = try await store.snapshot()
            server = snapshot?.baseURL ?? ""
        } catch { problem = String(describing: error) }
    }

    enum Action { case connect, refresh, disable, forget }

    func perform(_ action: Action, auth: PiAuthStore) async {
        guard let store, !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            switch action {
            case .connect: snapshot = try await store.connect(server: server, key: key)
            case .refresh: snapshot = try await store.refresh()
            case .disable: snapshot = try await store.disable()
            case .forget:
                try await store.forget()
                snapshot = nil
            }
            key = ""
            server = snapshot?.baseURL ?? ""
            if snapshot?.enabled == true { _ = auth.landed(CLIProxyAPIStore.provider) }
            else { auth.pi.catalog.invalidate(); auth.onChanged?() }
        } catch { problem = String(describing: error) }
    }
}

struct CLIProxyAPISettings: View {
    @Bindable var model: CLIProxyAPIModel
    let auth: PiAuthStore
    @State private var confirmingForget = false

    var body: some View {
        SettingsGroup(title: "CLIProxyAPI", footnote: "Optional. Connect to a proxy you already run. Shepherd stores this connection privately on this Mac; your terminal pi and its cpa provider stay unchanged. Active turns finish before connection changes apply.") {
            SettingsRow(title: "Use CLIProxyAPI", subtitle: model.snapshot.map {
                $0.enabled ? "\($0.modelCount) models available in the model picker." : "Off. Your saved connection is kept."
            } ?? "Off. Enter your server and API key to connect.", problem: model.problem) {
                if model.snapshot?.enabled == true {
                    Button("Turn off") { perform(.disable) }.buttonStyle(.nw(.secondary))
                }
            }
            SettingsRow(title: "Server address", subtitle: "HTTPS is used when you enter a hostname. Include http:// only for a trusted network.") {
                SettingsTextField(label: "CLIProxyAPI server address", prompt: "https://proxy.example.com", text: $model.server, mono: true)
            }
            SettingsRow(title: "API key", subtitle: model.snapshot == nil ? "Your proxy's API key, not its management key." : "Leave empty to keep the key for this address.") {
                SettingsTextField(label: "CLIProxyAPI API key", prompt: model.snapshot == nil ? "API key" : "Saved key", text: $model.key, mono: true, secure: true)
            }
            SettingsActionRow {
                if model.busy {
                    Text("Checking connection…").font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                } else if let snapshot = model.snapshot {
                    Text("Models checked \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
            } actions: {
                if model.snapshot != nil {
                    Button("Forget…") { confirmingForget = true }.buttonStyle(.nw(.ghost))
                    if model.snapshot?.enabled == true {
                        Button("Refresh models") { perform(.refresh) }.buttonStyle(.nw(.secondary))
                    }
                }
                Button(model.snapshot?.enabled == true ? "Save connection" : "Connect") { perform(.connect) }
                    .buttonStyle(.nw(.primary))
                    .disabled(model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(model.busy)
        .confirmationDialog("Forget this CLIProxyAPI connection?", isPresented: $confirmingForget) {
            Button("Forget connection", role: .destructive) { perform(.forget) }
        } message: {
            Text("Removes the saved server, API key and model list from Shepherd. Your proxy and terminal pi are unchanged.")
        }
        .task { await model.load() }
    }

    private func perform(_ action: CLIProxyAPIModel.Action) {
        Task { await model.perform(action, auth: auth) }
    }
}
