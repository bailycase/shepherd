import Foundation
import Observation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import ShepherdRemote

/// Add space (ProjectAdd board): a name, an optional parent space, and the space's folder. The
/// parent is Shepherd's explicit organization (`Space.parentID`), so the folder can be anywhere
/// and nothing moves.
@MainActor @Observable
final class AddSpaceModel: Identifiable {
    struct Parent: Equatable, Identifiable { var id: SpaceID; var name: String }

    let id = UUID()
    let hosts: [ProjectsHost]
    @ObservationIgnored private let rows: [ProjectsRow]
    @ObservationIgnored private let add: @MainActor (AddSpaceModel) async throws -> Void
    var name = ""
    var path = ""
    var hostID: String { didSet { if hostID != oldValue { parentID = nil; error = nil } } }
    var parentID: SpaceID? { didSet { error = nil } }
    var browsing = false
    private(set) var busy = false
    var error: String?

    init(hosts: [ProjectsHost], rows: [ProjectsRow], hostID: String, parentID: SpaceID? = nil,
         add: @escaping @MainActor (AddSpaceModel) async throws -> Void) {
        self.hosts = hosts; self.rows = rows; self.hostID = hostID; self.parentID = parentID; self.add = add
    }

    var host: ProjectsHost? { hosts.first { $0.id == hostID } }
    /// This Mac, and another host with `projectParentCapability`, record a parent and a name.
    var offersParents: Bool { hostID == "local" || host?.supportsParent == true }
    var parents: [Parent] {
        guard offersParents else { return [] }
        return rows.filter { $0.host.id == hostID }.compactMap { row in row.project.projectID.map { Parent(id: $0, name: row.project.name) } }
    }
    var parentName: String? { parents.first { $0.id == parentID }?.name }
    /// Whether the folder is inside the parent's: only then does the child inherit, as configuration
    /// never crosses unrelated folders. Nil without a parent or a folder.
    var inheritsFromParent: Bool? {
        guard let parentID, !path.trimmed.isEmpty,
              let parent = rows.first(where: { $0.host.id == hostID && $0.project.projectID == parentID })?.project.directory else { return nil }
        let folder = (path.trimmed as NSString).expandingTildeInPath
        return ProjectNesting.parent(of: folder, among: [parent]) != nil
    }
    var title: String { parentID == nil ? "Add space" : "Add child space" }
    var canSubmit: Bool { !busy && !name.trimmed.isEmpty && !path.trimmed.isEmpty && host?.unavailable == nil }
    var footer: String { busy ? "Adding…" : "No files are moved or credentials copied." }

    /// The board's checks, in its order; nil when the entries can be added.
    static func problem(name: String, path: String, hostID: String, parentID: SpaceID?, rows: [ProjectsRow]) -> String? {
        let name = name.trimmed, path = path.trimmed.trimmingTrailingSlashes
        if name.isEmpty || name.count > 80 || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\" }) {
            return "Enter a space name of up to 80 characters."
        }
        if !(path.hasPrefix("/") || path.hasPrefix("~/")) || path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            || path.split(separator: "/").contains("..") {
            return "Choose an absolute or home-relative folder path."
        }
        let expanded = (path as NSString).expandingTildeInPath
        if rows.contains(where: { $0.host.id == hostID && ($0.project.directory.trimmingTrailingSlashes == path || $0.project.directory.trimmingTrailingSlashes == expanded) }) {
            return "That folder is already a space on this host."
        }
        if let parentID, !rows.contains(where: { $0.host.id == hostID && $0.project.projectID == parentID }) {
            return "Choose a parent space on the same host."
        }
        return nil
    }

    func submit() async -> Bool {
        guard canSubmit else { return false }
        if let problem = Self.problem(name: name, path: path, hostID: hostID, parentID: parentID, rows: rows) { error = problem; return false }
        busy = true; error = nil
        defer { busy = false }
        do { try await add(self); return true }
        catch { self.error = "Could not add this space. Your entries are still here. \(error)"; return false }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmingTrailingSlashes: String {
        var value = self
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

struct AddSpaceSheet: View {
    @Bindable var model: AddSpaceModel
    let list: (ProjectsHost, String) async throws -> RemoteHostClient.DirListing
    let dismiss: () -> Void
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, path }

    var body: some View {
        SHDialog(model.title, width: AppLayout.spaceAddWidth) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                label("Space name")
                TextField("Space name", text: $model.name, prompt: Text("shepherd-landing"))
                    .shField(focused: focused == .name).focused($focused, equals: .name).accessibilityLabel("Space name")
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    label("Parent space")
                    SHPopupMenu(model.parentName ?? "None · root space") {
                        Button("None · root space") { model.parentID = nil }
                        ForEach(model.parents) { parent in Button(parent.name) { model.parentID = parent.id } }
                    }.accessibilityLabel("Parent space").disabled(!model.offersParents)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, SH.Space.m)
                hint("Choose None to create a root space.")
                label("Space folder").padding(.top, SH.Space.m)
                TextField("Space folder", text: $model.path, prompt: Text("~/code/shepherd-landing"))
                    .shField(focused: focused == .path, mono: true).focused($focused, equals: .path).accessibilityLabel("Space folder")
                HStack(spacing: SH.Space.l) {
                    Button("Choose a folder…") { model.browsing = true }.buttonStyle(.sh(.secondary)).disabled(model.host == nil)
                    hint("Or enter its path above.")
                }
                if let parent = model.parentName {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        label("Inherited from \(parent)")
                        if model.inheritsFromParent == false {
                            hint("Nothing: this folder isn’t inside \(parent)’s. The space is listed under \(parent) only. This does not move files.")
                        } else {
                            hint("Shared MCP servers, skills, slash commands and extensions, and the startup model and thinking. Child overrides stay separate.")
                            hint("A folder inside \(parent)’s inherits; one elsewhere on \(model.host?.name ?? "this host") is only listed under it. This does not move files.")
                        }
                    }.padding(.top, SH.Space.m)
                }
                if let error = model.error {
                    Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isStaticText)
                }
            }.padding(.horizontal, SHDialogMetrics.inset).padding(.vertical, SH.Space.l)
        } status: {
            hint(model.footer)
        } actions: {
            Button("Cancel", action: dismiss).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(model.title) { Task { if await model.submit() { dismiss() } } }
                .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
        }
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
        .onAppear { focused = .name }
        .sheet(isPresented: $model.browsing) {
            if let host = model.host {
                RemoteDirectoryPicker(title: "Choose space folder", actionTitle: "Choose", hostName: host.name,
                                      startPath: host.known.first.map { ($0.directory as NSString).deletingLastPathComponent } ?? "",
                                      list: { try await list(host, $0) },
                                      choose: { path in
                                          model.path = path
                                          if model.name.trimmingCharacters(in: .whitespaces).isEmpty { model.name = URL(fileURLWithPath: path).lastPathComponent }
                                          model.browsing = false
                                      },
                                      cancel: { model.browsing = false })
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}
