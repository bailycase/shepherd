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
        SpacePageFrame {
            SpacePageHeader(title: "Spaces")
            SpaceSection(title: "", footnote: model.error ?? "Grouping changes only Shepherd. Instructions and settings follow folders on disk.", lazy: true,
                         showsHeader: !model.rows.isEmpty && model.addHost != nil && model.addHost?.unavailable == nil) {
                if !model.rows.isEmpty, model.addHost != nil, model.addHost?.unavailable == nil {
                    Button("Add space") { adding = model.addHost.map { vm.addSpaceModel(host: $0) } }.buttonStyle(SpaceLinkStyle())
                }
            } content: {
                if !model.rows.isEmpty {
                    HStack(spacing: SH.Space.l) {
                        SpaceSearchField(prompt: "Filter spaces", text: $model.filter)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceFilterHeight)
                }
                if model.visible.isEmpty {
                    SpaceEmpty(title: model.loading ? "Loading spaces…" : model.rows.isEmpty ? "No spaces yet" : "No spaces match",
                               message: model.rows.isEmpty && !model.loading ? "Add a folder to get started." : nil) {
                        if model.rows.isEmpty, !model.loading, model.addHost != nil, model.addHost?.unavailable == nil {
                            Button("Add space") { adding = model.addHost.map { vm.addSpaceModel(host: $0) } }.buttonStyle(SpaceLinkStyle(tone: .strong))
                        }
                    }
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
        Button(action: open) {
            HStack(spacing: AppLayout.spaceRowGap) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.project.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    Text(row.unavailable ?? row.project.displayPath).font(.shMono(AppLayout.spaceDetailSize))
                        .foregroundStyle(row.unavailable == nil ? Color.sh.textTertiary : Color.sh.lanternText).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(row.host.name).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.shSans(SHSettingsControlMetrics.popupChevronSize, .semibold))
                    .foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            }
            .padding(.leading, AppLayout.spaceRowSides + (row.ancestorIDs.isEmpty ? 0 : AppLayout.spaceRowIndent))
            .padding(.trailing, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isSubproject ? "Open \(row.project.name) under \(row.parentName ?? "")" : "Open \(row.project.name)")
        .contextMenu { actions }
        .accessibilityActions { actions }
    }
}
