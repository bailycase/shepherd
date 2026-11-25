import AppKit
import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Tools ▸ Extensions: the pi extensions Shepherd's pi loads, added here from a file,
/// a folder or a Git repository, or copied from the user's own pi. Each has its switch; a provider
/// one registers appears in Settings ▸ Models' Sign-in. Every agent loads the ones that are on.
struct ExtensionsSettingsGroup: View {
    let model: YourPiModel
    /// What each loaded extension registered (`PiAuthStore.extensionInventory`); nil in previews without one.
    var auth: PiAuthStore? = nil
    /// Its `id` on the Tools page, for `settingsScrollTarget`.
    static let scrollID = "settings.extensions"
    /// One row's `id`, for `settingsScrollTarget` (Sign-in's Show the extension).
    static func rowScrollID(_ destination: String) -> String { "settings.extension:\(destination)" }
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
                ExtensionRow(item: item, support: auth?.extensionInventory[item.copy.destination].map {
                                 PiExtensionSupport.make($0, scanned: item.terminalOnly)
                             }, providerNames: auth?.providerNames ?? [:],
                             problem: model.problems[YourPiModel.extensionRowID(item.copy.destination)],
                             busy: model.busy.contains(YourPiModel.extensionRowID(item.copy.destination)),
                             setOn: { on in Task { await model.setExtension(item.copy.destination, on: on) } },
                             remove: { Task { await model.removeExtension(item.copy.destination) } })
                .id(Self.rowScrollID(item.copy.destination))
            }
        }
        .id(Self.scrollID)
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
        .task {
            await model.refresh()
            // Loads the switched-on extensions as Sign-in does: what each adds, and what Shepherd can't show.
            await auth?.refreshProviders()
        }
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

/// One extension: its name, what it adds and how far it works in Shepherd (or why it didn't load),
/// where it came from, its switch, and Remove.
private struct ExtensionRow: View {
    let item: YourPiExtensionRow
    let support: PiExtensionSupport?
    let providerNames: [String: String]
    let problem: String?
    let busy: Bool
    let setOn: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        let state = ExtensionsText.state(item, support: support)
        SettingsRow(title: item.copy.name, subtitle: item.failure ?? ExtensionsText.subtitle(item, support: support, names: providerNames),
                    problem: problem, dot: state == .partly ? .warn : state == .failed ? .bad : nil) {
            HStack(spacing: SH.Space.s) {
                if let state {
                    SHTag(state.word, foreground: state == .works ? Color.sh.done : state == .partly ? Color.sh.lanternText : Color.sh.failed)
                        .help(ExtensionsText.help(item, support: support))
                }
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
    /// How far an extension works in Shepherd, once pi has loaded it (or failed to).
    enum State: Equatable {
        case works, partly, failed
        var word: String {
            switch self {
            case .works: "Works"
            case .partly: "Partly"
            case .failed: "Didn’t load"
            }
        }
    }

    static func state(_ item: YourPiExtensionRow, support: PiExtensionSupport?) -> State? {
        if item.failure != nil { return .failed }
        guard item.on, let support else { return nil }
        return support.level == .works ? .works : .partly
    }

    /// "Adds Acme sign-in, /acme-usage · Not shown in Shepherd: shortcut ctrl+x · Added from …";
    /// before pi has loaded it, where it came from alone.
    static func subtitle(_ item: YourPiExtensionRow, support: PiExtensionSupport?, names: [String: String] = [:]) -> String {
        var parts: [String] = []
        if let support, item.on {
            let adds = support.providers.map { "\(names[$0] ?? PiSignInCatalog.name($0)) sign-in" } + support.adds
            if !adds.isEmpty { parts.append("Adds " + adds.joined(separator: ", ")) }
            if let missing = notShown(support) { parts.append(missing) }
        }
        return (parts + [origin(item)]).joined(separator: " · ")
    }

    /// "Not shown in Shepherd: shortcut ctrl+x, footer or header"; nil when it all shows.
    static func notShown(_ support: PiExtensionSupport) -> String? {
        let all = support.notShown + support.mayNotShow
        return all.isEmpty ? nil : "Not shown in Shepherd: " + all.joined(separator: ", ")
    }

    /// The tag's tooltip: what can't show, exact and guessed apart.
    static func help(_ item: YourPiExtensionRow, support: PiExtensionSupport?) -> String {
        if let failure = item.failure { return failure }
        guard let support else { return "" }
        var lines: [String] = []
        if !support.notShown.isEmpty { lines.append("Registered, but Shepherd can’t show: " + support.notShown.joined(separator: ", ") + ".") }
        if !support.mayNotShow.isEmpty { lines.append("Its code uses terminal UI Shepherd may not show: " + support.mayNotShow.joined(separator: ", ") + ".") }
        return lines.isEmpty ? "Everything it registered works in Shepherd." : lines.joined(separator: "\n")
    }

    /// "Added from ~/code/acme-login · Signs in to Acme", "From your pi · extensions/x.ts".
    static func origin(_ item: YourPiExtensionRow) -> String {
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
