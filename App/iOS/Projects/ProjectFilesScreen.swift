import SwiftUI
import UIKit
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The Project's files on its owner, one directory at a time (`files.v1`). A folder pushes the next;
/// a file previews as data under the list (text, PNG or JPEG). Nothing is opened, run or saved here.
struct ProjectFilesScreen: View {
    let ref: LogicalProjectRef
    let path: String
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @State private var listing: LogicalProjectFileListing?
    @State private var problem: String?
    @State private var preview: Preview?

    enum Preview: Equatable {
        case text(name: String, String)
        case image(name: String, Data)
        case problem(name: String, String)
    }

    var body: some View {
        List {
            if let problem {
                Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
            } else if let listing {
                if listing.entries.isEmpty {
                    Text("Nothing here yet. Files the project's threads publish show here.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                ForEach(listing.entries, id: \.relativePath) { entry in
                    Button { open(entry) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                Text(entry.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                                if entry.kind == .file {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: entry.kind == .folder ? "folder" : "doc").foregroundStyle(Color.sh.textSecondary)
                        }
                    }
                }
                if listing.truncated {
                    Text("Showing the first \(LogicalProjectFileListing.maximumEntries) entries; this isn't the whole folder.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            } else {
                ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
            }
            if let preview { Section { previewView(preview) } }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(path.isEmpty ? "Files" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projects.host(ref)?.session) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            listing = try await projects.model.files(ref, path: path)
            problem = nil
        } catch {
            problem = LogicalProjectsModel.filesMessage(error)
        }
    }

    private func open(_ entry: LogicalProjectFileEntry) {
        if entry.kind == .folder { navigator.open(.projects(.files(ref, path: entry.relativePath))); return }
        Task {
            do {
                let file = try await projects.model.read(ref, path: entry.relativePath)
                if file.mimeType.hasPrefix("image/") {
                    preview = .image(name: entry.name, file.data)
                } else if let text = String(data: file.data, encoding: .utf8) {
                    preview = .text(name: entry.name, text)
                } else {
                    preview = .problem(name: entry.name, "This file can't be previewed. Previews show text and PNG or JPEG images.")
                }
            } catch {
                preview = .problem(name: entry.name, LogicalProjectsModel.filesMessage(error))
            }
        }
    }

    @ViewBuilder private func previewView(_ preview: Preview) -> some View {
        switch preview {
        case .text(let name, let text):
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text(name).font(.sh(.ui, weight: .semibold))
                Text(text).font(.sh(.mono)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let name, let data):
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text(name).font(.sh(.ui, weight: .semibold))
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(name)
                } else {
                    Text("This image can't be read.").font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                }
            }
        case .problem(let name, let message):
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name).font(.sh(.ui, weight: .semibold))
                Text(message).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
            }
        }
    }
}

/// New thread for the Project (the Mac's AssignProjectTaskSheet): a title, what to do, and one of the
/// Project's own linked Spaces on its owner. One operation identity per sheet, so a retry never
/// starts a second thread. It runs on the owner (the host choice stays on the Mac).
struct AssignProjectTaskScreen: View {
    let ref: LogicalProjectRef
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @State private var title = ""
    @State private var prompt = ""
    @State private var space: SpaceID?
    @State private var operation = UUID()
    @State private var assigning = false
    @State private var error: String?

    var body: some View {
        let project = projects.model.project(ref)
        let owned = projects.host(ref)?.state.spaces ?? []
        let spaces = (project?.linkedSpaces ?? []).filter { $0.destination == .local }
            .compactMap { link in owned.first { $0.id == link.spaceID } }
        let ready = !assigning && projects.canRun(ref) && space != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Form {
            Section("Title") {
                TextField("Title", text: $title).font(.sh(.ui)).accessibilityLabel("Thread title")
            }
            Section("What to do") {
                TextEditor(text: $prompt).font(.sh(.body))
                    .frame(minHeight: MobileLayout.projectPromptMinHeight)
                    .accessibilityLabel("What to do")
            }
            Section {
                if spaces.isEmpty {
                    Text("Link a space in Project settings first.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                } else {
                    Picker("Space", selection: $space) {
                        if space == nil { Text("Choose…").tag(SpaceID?.none) }
                        ForEach(spaces) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } header: { Text("Where it runs") } footer: { Text("On \(projects.host(ref)?.name ?? "the project's host").") }
            if let error {
                Section { Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { navigator.dismissPresented() } }
            ToolbarItem(placement: .confirmationAction) {
                if assigning { ProgressView().progressViewStyle(SHSpinnerStyle()) } else {
                    Button("Start thread") { assign() }.disabled(!ready)
                }
            }
        }
        .onAppear { if space == nil, spaces.count == 1 { space = spaces[0].id } }
    }

    private func assign() {
        guard let space else { return }
        assigning = true
        error = nil
        let request = ProjectRuntimeRequest.assign(operationID: operation, spaceID: space,
                                                   title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            let ok = await projects.model.run(ref, request)
            assigning = false
            if ok { navigator.dismissPresented() } else { error = projects.model.failure?.message ?? "The thread was not started." }
        }
    }
}
