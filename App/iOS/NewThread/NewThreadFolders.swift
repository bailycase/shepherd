import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Add repo: browses the host's folders (`listDir`) and adds the chosen one as a space
/// (`addSpace`). The Mac's directory picker rules: hidden folders on request, a fuzzy filter,
/// and a bad start path falling back to the host's home.
@MainActor
@Observable
final class NewThreadFolderBrowser: Identifiable, Hashable {
    nonisolated let id = UUID()
    let hostName: String
    private(set) var path = ""
    private(set) var parent: String?
    private(set) var dirs: [String] = []
    private(set) var loading = true
    var errorText: String?
    private(set) var showHidden = false
    private(set) var filter = ""
    /// The listing as shown, derived when the folders, the filter or hidden change.
    private(set) var visible: [String] = []
    private(set) var adding = false

    @ObservationIgnored private let client: RemoteHostClient
    @ObservationIgnored private var request = UUID()

    init(hostName: String, client: RemoteHostClient) {
        self.hostName = hostName
        self.client = client
    }

    /// Lists `target` (empty: the host's home). Only the newest request lands.
    func load(_ target: String) {
        loading = true
        errorText = nil
        let request = UUID()
        self.request = request
        Task {
            do {
                let listing = try await client.listDir(path: target)
                guard self.request == request else { return }
                path = listing.path
                parent = listing.parent
                dirs = listing.dirs
                filter = ""
                loading = false
                refresh()
            } catch {
                guard self.request == request else { return }
                if path.isEmpty, !target.isEmpty {
                    load("")
                    return
                }
                errorText = NewThreadModel.message(error)
                loading = false
            }
        }
    }

    nonisolated static func == (lhs: NewThreadFolderBrowser, rhs: NewThreadFolderBrowser) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func open(_ name: String) { load(NewThreadFolders.child(name, of: path)) }

    func up() {
        if let parent { load(parent) }
    }

    func setFilter(_ value: String) {
        filter = value
        refresh()
    }

    func setShowHidden(_ on: Bool) {
        showHidden = on
        refresh()
    }

    func setAdding(_ on: Bool) { adding = on }

    private func refresh() {
        let next = NewThreadFolders.visible(dirs, filter: filter, showHidden: showHidden)
        if next != visible { visible = next }
    }
}

/// The folder browser's screen, pushed over Where it runs (or the iPad's repo popover).
struct NewThreadFolderScreen: View {
    let model: NewThreadModel
    let browser: NewThreadFolderBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if browser.parent != nil {
                    Button { browser.up() } label: {
                        Label("Parent folder", systemImage: "arrow.turn.left.up")
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(browser.visible, id: \.self) { name in
                    Button { browser.open(name) } label: {
                        HStack(spacing: NW.Space.l) {
                            Image(systemName: "folder")
                                .font(.nw(.ui))
                                .foregroundStyle(Color.nw.textSecondary)
                                .accessibilityHidden(true)
                            Text(name).font(.nwMono(NWChoiceRowMetrics.titleSize)).foregroundStyle(Color.nw.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.nw(.caption))
                                .foregroundStyle(Color.nw.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityHint("Opens the folder")
                }
                if !browser.loading, browser.visible.isEmpty {
                    Text(browser.filter.isEmpty ? "No folders here" : "No matching folders")
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textTertiary)
                        .frame(minHeight: MobileLayout.rowHeight)
                }
            } header: {
                Text(NewThreadRules.abbreviatedPath(browser.path))
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .textCase(nil)
                    .lineLimit(2)
                    .truncationMode(.head)
            } footer: {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    if let error = browser.errorText {
                        Text(error).nwText(.caption).foregroundStyle(Color.nw.failed)
                    }
                    Toggle("Show hidden folders", isOn: Binding(get: { browser.showHidden }, set: { browser.setShowHidden($0) }))
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textSecondary)
                        .tint(Color.nw.lantern)
                }
            }
            .listRowBackground(Color.nw.bgRaised)
        }
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .overlay {
            if browser.loading && browser.dirs.isEmpty { ProgressView().progressViewStyle(.nwSpinner) }
        }
        .searchable(text: Binding(get: { browser.filter }, set: { browser.setFilter($0) }), prompt: "Filter folders")
        .navigationTitle("Add repo on \(browser.hostName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(browser.adding ? "Adding…" : "Add") {
                    browser.setAdding(true)
                    Task {
                        let added = await model.addRepo(browser.path)
                        browser.setAdding(false)
                        if added { dismiss() }
                    }
                }
                .disabled(browser.path.isEmpty || browser.loading || browser.adding)
                .accessibilityHint("Adds \(browser.path) as a repo on \(browser.hostName)")
            }
        }
        .task { if browser.path.isEmpty { browser.load("") } }
    }
}
