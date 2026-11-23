import SwiftUI
import ShepherdUI
import ShepherdProtocol

struct ProjectsSettings: View {
    let vm: ShepherdViewModel
    @Bindable var model: ProjectsModel
    /// Add project, or Add subproject with the parent's folder the picker opens in (so the folder
    /// chosen lands inside it). One value, so the sheet never opens without its folder.
    @State private var adding: AddSpaceModel?
    @State private var addingChild: ChildProjectModel?

    var body: some View {
        Group {
            if let project = model.selected {
                ProjectSettingsDetail(model: model, project: project, cookies: vm.projectCookies, cookieScope: vm.cookieScope(for: project),
                                      hooks: vm.hooks,
                                      openHooks: {
                                          vm.hooks.spaceFilter = nil
                                          vm.settingsSection = .hooks
                                      },
                                      rename: project.project.projectID != nil ? { vm.spaceRenameTarget = project.project.projectID } : nil,
                                      remove: project.project.projectID != nil ? { vm.requestSpaceDelete(project.project.projectID) } : nil)
            } else {
                list
            }
        }
        .shControlScale(.settings)
        .task(id: vm.projectsSources) { await model.load(vm.projectsSources) }
        .sheet(item: $addingChild) { model in
            ChildProjectSheet(model: model, dismiss: { addingChild = nil })
        }
        .sheet(item: $adding) { adding in
            AddSpaceSheet(model: adding, list: { _, path in try await LocalDirectoryLister.load(path: path) }, dismiss: { self.adding = nil })
        }
    }

    /// What a row offers besides opening: in its context menu and, the same, to VoiceOver.
    @ViewBuilder private func rowActions(_ row: ProjectsRow) -> some View {
        if row.children > 0 {
            Button(model.collapsed.contains(row.id) ? "Expand" : "Collapse") { model.collapsed.formSymmetricDifference([row.id]) }
        }
        if !row.isSubproject && row.unavailable == nil {
            Button("Add subspace…") { addingChild = vm.childProjectModel(path: row.project.directory, name: row.project.name) }
        }
        if row.project.projectID != nil {
            Button("Rename Space…") { vm.spaceRenameTarget = row.project.projectID }
            Button("Remove Space…", role: .destructive) { vm.requestSpaceDelete(row.project.projectID) }
        }
    }

    /// The spaces, children indented under their parents; a row opens the space.
    private var list: some View {
        SettingsPage(title: "Spaces") {
            SettingsGroup(title: "", footnote: model.error ?? "Grouping changes only Shepherd. Instructions and settings follow folders on disk.",
                          links: model.addHost == nil || model.addHost?.unavailable != nil ? [] : [
                              SettingsLink("Add space") { adding = model.addHost.map { vm.addSpaceModel(host: $0) } },
                          ], lazy: true) {
                if !model.rows.isEmpty {
                    SettingsSearchRow(prompt: "Filter spaces", text: $model.filter)
                }
                if model.visible.isEmpty {
                    SettingsRow(title: model.loading ? "Loading spaces…" : model.rows.isEmpty ? "No spaces yet" : "No spaces match",
                                subtitle: model.rows.isEmpty && !model.loading ? "Add a folder to get started" : nil) { EmptyView() }
                }
                ForEach(model.visible) { row in
                    SpaceListRow(row: row, collapsed: model.collapsed.contains(row.id), open: { Task { await model.open(row) } }) {
                        rowActions(row)
                    }
                    .equatable()
                }
            }
            .accessibilityIdentifier("ProjectsTable")
        }
    }
}

/// One space in the list. Compares by what it draws, so a change redraws its own row and no other.
private struct SpaceListRow<Actions: View>: View, Equatable {
    let row: ProjectsRow
    let collapsed: Bool
    let open: () -> Void
    @ViewBuilder let actions: Actions

    nonisolated static func == (a: SpaceListRow, b: SpaceListRow) -> Bool { a.row == b.row && a.collapsed == b.collapsed }

    var body: some View {
        let _ = SHRenderProbe.tick("settings.project.row")
        SettingsDrillRow(title: row.project.name, subtitle: row.unavailable ?? row.project.displayPath,
                         value: row.host.name, indented: !row.ancestorIDs.isEmpty,
                         accessibilityName: row.isSubproject ? "Open \(row.project.name) under \(row.parentName ?? "")" : "Open \(row.project.name)",
                         action: open)
            .contextMenu { actions }
            .accessibilityActions { actions }
    }
}
