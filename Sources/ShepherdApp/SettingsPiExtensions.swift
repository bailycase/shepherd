import AppKit
import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Tools ▸ Extensions: the pi extensions Shepherd's pi loads, added here from a file,
/// a folder or a Git repository, or copied from the user's own pi. Each has its switch; a provider
/// one registers appears in Settings ▸ Models' Sign-in. Every agent loads the ones that are on.
struct ExtensionsSettingsGroup: View {
    let model: YourPiModel
    @State private var addingGit = false
    @State private var gitURL = ""

    var body: some View {
        let extensions = model.survey?.extensions ?? []
        SettingsGroup(title: "Extensions",
                      footnote: "Extensions run with your account’s access. Providers they add appear in Models ▸ Sign-in; agents load them when they start or on /reload.",
                      links: [SettingsLink("Add…", menu: [
                          SettingsLink("File or folder…") { chooseFile() },
                          SettingsLink("From a Git repository…") { gitURL = ""; addingGit = true },
                      ])]) {
            if let problem = model.problems[YourPiModel.addExtensionRow] {
                SettingsRow(title: "Couldn’t add the extension", problem: problem) { EmptyView() }
            }
            if model.busy.contains(YourPiModel.addExtensionRow) {
                SettingsRow(title: "Adding…") { ProgressView().controlSize(.small) }
            }
            if extensions.isEmpty, !model.busy.contains(YourPiModel.addExtensionRow) {
                SettingsRow(title: "No extensions", subtitle: "Add a file, folder or Git repository that registers a provider or other tools.") { EmptyView() }
            }
            ForEach(extensions) { item in
                ExtensionRow(item: item, problem: model.problems[YourPiModel.extensionRowID(item.copy.destination)],
                             busy: model.busy.contains(YourPiModel.extensionRowID(item.copy.destination)),
                             setOn: { on in Task { await model.setExtension(item.copy.destination, on: on) } },
                             remove: { Task { await model.removeExtension(item.copy.destination) } })
            }
        }
        .alert("Add from a Git repository", isPresented: $addingGit) {
            TextField("https://github.com/acme/pi-login", text: $gitURL)
            Button("Add") {
                let url = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                Task { await model.addExtension(.git(url)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shepherd clones it with your Git sign-in and switches it on. Its npm dependencies must be committed with it.")
        }
        .task { await model.refresh() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a .ts or .js file, or a folder with a package.json, index.ts or index.js."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addExtension(.path(url)) }
    }
}

/// One extension: its name, where it came from (or why it didn't load), its switch, and Remove.
private struct ExtensionRow: View {
    let item: YourPiExtensionRow
    let problem: String?
    let busy: Bool
    let setOn: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        SettingsRow(title: item.copy.name, subtitle: item.failure ?? ExtensionsText.subtitle(item), problem: problem,
                    dot: item.failure != nil ? .warn : nil) {
            HStack(spacing: SH.Space.s) {
                SettingsSwitch(label: item.copy.name, isOn: Binding(get: { item.on }, set: setOn))
                    .disabled(busy)
                SHProviderMenuButton(for: item.copy.name) {
                    Button("Remove", role: .destructive, action: remove)
                }
                .disabled(busy)
            }
        }
        .contextMenu { Button("Remove", role: .destructive, action: remove) }
    }
}

enum ExtensionsText {
    /// "Added from ~/code/acme-login · Signs in to Acme", "From your pi · extensions/x.ts".
    static func subtitle(_ item: YourPiExtensionRow) -> String {
        let origin: String
        if YourPiImport.isAdded(item.copy.destination) {
            let source = item.copy.source.hasPrefix("/") ? (item.copy.source as NSString).abbreviatingWithTildeInPath : item.copy.source
            origin = source.isEmpty ? "Added" : "Added from \(source)"
        } else {
            let source = YourPiText.extensionPath(item)
            origin = source.isEmpty ? "From your pi" : "From your pi · \(source)"
        }
        return [origin, item.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
