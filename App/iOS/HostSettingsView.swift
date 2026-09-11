import SwiftUI

struct HostSettingsView: View {
    @ObservedObject var connection: HostConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var host = ""
    @State private var port = "7433"
    @State private var token = ""
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("My Mac", text: $name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Address") {
                        TextField("hostname or IP", text: $host)
                            .keyboardType(.URL).font(MobileTokens.mono).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("7433", text: $port)
                            .keyboardType(.numberPad).font(MobileTokens.mono).multilineTextAlignment(.trailing)
                    }
                    SecureField("Bearer token", text: $token)
                        .privacySensitive().font(MobileTokens.mono)
                } header: {
                    Text("MAC HOST").font(MobileTokens.caption)
                } footer: {
                    Text("Turn on Remote in Shepherd ▸ Settings on your Mac and copy its token. Keep Shepherd running there.")
                }
                Section {
                    Label("Trusted LAN or VPN only. There is no TLS, so the token and thread travel unencrypted. Never expose the port to the internet.", systemImage: "lock.open")
                    Label("The token stays in this device's Keychain; only name, address, and port are saved in preferences.", systemImage: "key")
                }
                .font(MobileTokens.caption)
                .foregroundStyle(tokens.secondary)
                .listRowBackground(tokens.sidebar)
                if connection.configuration != nil {
                    Section {
                        Button("Forget this host", role: .destructive) { confirmingForget = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(tokens.primary)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("Host Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(tokens.sidebar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try connection.save(name: name, host: host, port: port, token: token)
                            token = ""
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("could not save connection", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog("Forget this host and delete its saved token?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget Host", role: .destructive) {
                    do {
                        try connection.forget()
                        token = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .onAppear {
                name = connection.configuration?.name ?? ""
                host = connection.configuration?.host ?? ""
                port = connection.configuration.map { String($0.port) } ?? "7433"
                do { token = try HostTokenStore.read() ?? "" }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { token = "" }
        }
        .tint(tokens.accent)
    }
}
