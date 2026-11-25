import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Tools ▸ Extensions on the iPhone and the iPad: the pi extensions in the host's pi home
// (`hostExtensions.v1`), as the Mac's Settings ▸ Tools ▸ Extensions lists them. Each has its switch
// and Remove; one is added from a Git repository the host clones (no file picking here). A provider
// one registers appears in Models ▸ Sign-in, which reads again after each change.

/// The host's extensions with their switches, and Add from a Git repository. Draws nothing for a
/// host that doesn't serve them.
struct PiExtensionSections: View {
    let store: SettingsStore
    @State private var gitURL = ""
    /// The last change's failure, shown here rather than at the top of the page.
    @State private var problem: String?

    var body: some View {
        let config = store.hostConfig
        if let host = store.settingsHost, host.isConnected, config.servesExtensions(host) {
            let busy = config.busy.contains(host.id)
            SettingsSection("Extensions") {
                if let problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { self.problem = nil }.buttonStyle(.settingsPill)
                    }
                }
                if let items = config.extensions[host.id] {
                    if items.isEmpty {
                        SettingsFootnote("None yet. Add a Git repository that registers a provider or other tools.")
                    } else {
                        SettingsCard {
                            ForEach(items) { item in
                                HStack(spacing: SH.Space.s) {
                                    SettingsRow(item.name, subtitle: HostInventoryPresentation.extensionLine(item), subtitleMono: false,
                                              subtitleTone: item.failure != nil ? .failed : nil,
                                              leading: .state(AgentState(rawValue: HostInventoryPresentation.tone(item).rawValue) ?? .idle), chevron: false)
                                    HStack(spacing: SH.Space.s) {
                                        if let word = HostInventoryPresentation.supportWord(item) {
                                            SHTag(word, foreground: item.failure != nil ? Color.sh.failed
                                                  : item.support == .partly ? Color.sh.lanternText : Color.sh.done)
                                                .accessibilityHint(item.supportDetail ?? "")
                                        }
                                        Toggle("\(item.name) on", isOn: Binding(get: { item.on }, set: { on in
                                            run(.extensionSetEnabled(destination: item.id, on: on), on: host)
                                        }))
                                        .toggleStyle(.settingsSwitch)
                                        .labelsHidden()
                                        Menu {
                                            Button("Remove…", role: .destructive) { store.removingExtension = item }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .font(.sh(.ui))
                                                .foregroundStyle(Color.sh.textSecondary)
                                                .frame(minWidth: SHListMetrics.rowHeight, minHeight: SHListMetrics.rowHeight)
                                        }
                                        .accessibilityLabel("\(item.name) actions")
                                    }
                                    .disabled(busy)
                                    .padding(.trailing, SH.Space.l)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: SH.Space.l) {
                    Button("Add from Git…") { gitURL = ""; store.addingExtension = true }
                        .buttonStyle(.settingsPill)
                        .disabled(busy)
                    if busy { SHBusyLabel("Adding…") }
                }
                SettingsFootnote("Extensions run with your account’s access on \(host.name). Providers they add appear in Models ▸ Sign-in; agents load them when they start or on /reload.")
            }
            .task(id: Load(host: host.id, generation: store.refreshes)) { await config.refresh(.extensions, on: host) }
            .alert("Add from a Git repository", isPresented: Binding(get: { store.addingExtension }, set: { store.addingExtension = $0 })) {
                TextField("https://github.com/acme/pi-login", text: $gitURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let url = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty else { return }
                    run(.extensionAddGit(url: url), on: host)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("An https:// or ssh address. \(host.name) clones it with its Git sign-in and switches it on. Its npm dependencies must be committed with it.")
            }
            .confirmationDialog("Remove \(store.removingExtension?.name ?? "this extension") from \(host.name)?", isPresented: Binding(
                get: { store.removingExtension != nil }, set: { if !$0 { store.removingExtension = nil } }), titleVisibility: .visible,
                presenting: store.removingExtension) { item in
                Button("Remove", role: .destructive) { run(.extensionRemove(destination: item.id), on: host) }
            } message: { _ in
                Text("New threads start without it; running ones keep it until /reload.")
            }
        }
    }

    private struct Load: Equatable {
        var host: UUID
        var generation: Int
    }

    /// Sends a change; its failure shows here, not in the page's banner.
    private func run(_ request: RemoteHostConfigRequest, on host: SettingsHost) {
        let config = store.hostConfig
        Task {
            problem = nil
            if await config.perform(request, on: host) == nil {
                problem = config.problems[host.id]
                config.dismissProblem(on: host)
            }
        }
    }
}
