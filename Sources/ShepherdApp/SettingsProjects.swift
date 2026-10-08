import SwiftUI
import ShepherdUI
import ShepherdProtocol

struct ProjectsSettings: View {
    let vm: ShepherdViewModel
    @Bindable var model: ProjectsModel
    /// Add project, or Add subproject with the parent's folder the picker opens in (so the folder
    /// chosen lands inside it). One value, so the sheet never opens without its folder.
    @State private var adding: AddingProject?
    @State private var addingChild: ChildProjectModel?

    private struct AddingProject: Identifiable {
        let host: ProjectsHost
        var under: String?
        var id: String { host.id + "\n" + (under ?? "") }
    }

    var body: some View {
        Group {
            if let project = model.selected {
                ProjectSettingsDetail(model: model, project: project, cookies: vm.projectCookies, cookieScope: vm.cookieScope(for: project))
            } else {
                ScrollView(.vertical) {
                    index
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("SettingsPageContent")
                        .padding(.horizontal, AppLayout.settingsWideSides)
                        .padding(.top, AppLayout.settingsTop)
                        .padding(.bottom, AppLayout.settingsBottom)
                }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .nwControlScale(.settings)
        .task(id: vm.projectsSources) { await model.load(vm.projectsSources) }
        .sheet(item: $addingChild) { model in
            ChildProjectSheet(model: model, dismiss: { addingChild = nil })
        }
        .sheet(item: $adding) { adding in
            let host = adding.host
            RemoteDirectoryPicker(title: "Add project", actionTitle: "Add project", hostName: host.name,
                                  startPath: adding.under ?? host.known.first?.directory ?? "", list: { path in
                if host.id == "local" { return try await LocalDirectoryLister.load(path: path) }
                guard vm.remoteHosts.connections.first(where: { $0.id.uuidString == host.id })?.endpointID == host.endpointID else {
                    throw ProjectFileError("host_changed", "The host address changed. Close the picker and choose the host again.")
                }
                return try await vm.remoteHosts.listDir(hostID: UUID(uuidString: host.id)!, path: path)
            }, choose: { path in
                self.adding = nil
                Task {
                    do { try await vm.addSettingsProject(path: path, host: host) }
                    catch { model.error = String(describing: error) }
                }
            }, cancel: { self.adding = nil })
        }
    }

    private var index: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectsSpacing) {
            HStack(alignment: .center, spacing: NW.Space.xl) {
                SettingsHeader(title: "Projects", explanation: "Shared settings at the parent, project-specific changes below it.",
                               titleSize: AppLayout.projectsTitleSize, explanationSize: AppLayout.projectsExplanationSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                add
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NW.Space.xl) { filter; hosts; Spacer(minLength: 0); count }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    HStack(spacing: NW.Space.xl) { filter; Spacer(minLength: 0); count }
                    ScrollView(.horizontal) { hosts }.scrollIndicators(.hidden)
                }
            }
            if let error = model.error { SettingsNote(text: error) }
            table
            Text("Global defaults → parent project → subproject. Overrides change only their project.")
                .nwText(size: AppLayout.projectsHostSize, lineHeight: AppLayout.projectsFooterLineHeight)
                .foregroundStyle(Color.nw.textSecondary)
                .frame(maxWidth: AppLayout.projectsTextWidth, alignment: .leading)
        }
    }

    private var filter: some View {
        NWSearchField("Filter projects", text: $model.filter)
            .frame(width: AppLayout.projectsFilterWidth)
    }

    private var hosts: some View {
        NWSegmentedPicker("Project hosts", selection: $model.host, options: model.hostOptions)
    }

    private var count: some View {
        Text(model.countText)
            .font(.nwSans(AppLayout.projectsHostSize))
            .foregroundStyle(Color.nw.textSecondary)
            .fixedSize()
    }

    private var add: some View {
        Button("Add project", systemImage: "plus") { adding = model.addHost.map { AddingProject(host: $0) } }
            .buttonStyle(.nw(.primary))
            .disabled(model.addHost == nil || model.addHost?.unavailable != nil)
    }

    private var table: some View {
        VStack(spacing: 0) {
            ProjectColumns {
                Text("PROJECT"); Text("HOST"); Text("CONFIGURATION"); Color.clear
            }
            .font(.nwMono(AppLayout.projectsHeaderSize))
            .foregroundStyle(Color.nw.textTertiary)
            .frame(height: AppLayout.projectsHeaderHeight)
            .background(Color.nw.bgSunken)
            NWHairline()
            LazyVStack(spacing: 0) {
                ForEach(model.visible) { row in
                    VStack(spacing: 0) {
                        ProjectTreeRow(row: row, expanded: !model.collapsed.contains(row.id),
                                       open: { Task { await model.open(row) } },
                                       toggle: { model.collapsed.formSymmetricDifference([row.id]) },
                                       addSubproject: {
                                           if row.host.id == "local" {
                                               addingChild = vm.childProjectModel(path: row.project.directory, name: row.project.name)
                                           } else {
                                               adding = AddingProject(host: row.host, under: row.project.directory)
                                           }
                                       })
                        if row.id != model.visible.last?.id { NWHairline() }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Projects and subprojects")
            if model.visible.isEmpty {
                Text(model.loading ? "Loading projects…" : model.rows.isEmpty ? "No projects yet. Add a folder to get started." : "No projects match your filter.")
                    .font(.nw(.body)).foregroundStyle(Color.nw.textTertiary)
                    .padding(NW.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ProjectsTable")
    }
}

/// The board's columns: the project takes what is left (never under 200pt, where the
/// configuration gives way first); host 120, configuration 230, the action 152; 16pt apart and 16pt
/// in. Host and action grow with the text size, the same on every row, so the columns stay aligned.
private struct ProjectColumns<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let scale = ThemeStore.shared.textScale
        HStack(spacing: NW.Space.xl) {
            Group(subviews: content) { columns in
                ForEach(columns.indices, id: \.self) { index in
                    switch index {
                    case 0:
                        columns[index].frame(minWidth: AppLayout.projectsNameMinWidth, maxWidth: .infinity, alignment: .leading)
                    case 1:
                        columns[index].frame(width: AppLayout.projectsHostWidth * scale, alignment: .leading)
                    case 2:
                        columns[index].frame(minWidth: AppLayout.projectsSummaryMinWidth, idealWidth: AppLayout.projectsSummaryWidth,
                                             maxWidth: AppLayout.projectsSummaryWidth, alignment: .leading)
                            .layoutPriority(1)
                    default:
                        columns[index].frame(width: AppLayout.projectsActionWidth * scale, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One project in the tree (SettingsProjects, parents and subprojects): a parent's disclosure, the
/// folder, the name with a parent's "2 subprojects", the path; its host; its configuration, a
/// subproject's with "From <parent>" under it; and Add subproject on a top-level row, Open project
/// on a subproject. The row opens the project.
private struct ProjectTreeRow: View {
    let row: ProjectsRow
    let expanded: Bool
    let open: () -> Void
    let toggle: () -> Void
    let addSubproject: () -> Void

    var body: some View {
        let _ = NWRenderProbe.tick("settings.project.row")
        ProjectColumns {
            HStack(spacing: NW.Space.m) {
                if row.children > 0 {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.nwSans(AppLayout.projectsChevronSize))
                            .foregroundStyle(Color.nw.textSecondary)
                            .frame(width: AppLayout.projectsToggleWidth, height: AppLayout.projectsToggleHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.nwRow())
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(row.project.name)")
                } else {
                    Color.clear.frame(width: AppLayout.projectsToggleWidth, height: 1)
                }
                Button(action: open) { identity }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.isSubproject ? "Open \(row.project.name) under \(row.parentName!)" : "Open \(row.project.name)")
                    .accessibilityHint(row.unavailable ?? row.project.displayPath)
            }
            .padding(.leading, row.isSubproject ? NW.Space.xxl : 0)
            Text(row.host.name).font(.nwSans(AppLayout.projectsHostSize)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            configuration
            action
        }
        .padding(.vertical, NW.Space.l)
        .frame(minHeight: AppLayout.projectsRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(row.unavailable ?? "\(row.project.directory)\n\(row.configuration)")
    }

    private var identity: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "folder")
                .font(.nwSans(AppLayout.projectsFolderSize))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: AppLayout.projectsFolderFrame, height: AppLayout.projectsFolderFrame)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                HStack(spacing: NW.Space.m) {
                    Text(row.project.name).font(.nwSans(AppLayout.projectsNameSize, .medium)).foregroundStyle(Color.nw.textPrimary)
                    if row.children > 0 {
                        Text(row.children == 1 ? "1 subproject" : "\(row.children) subprojects")
                            .font(.nwSans(AppLayout.projectsPathSize))
                            .foregroundStyle(Color.nw.textSecondary)
                            .padding(.horizontal, NW.Space.s)
                            .padding(.vertical, NW.Space.xxs)
                            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                            .fixedSize()
                    }
                }
                Text(row.project.displayPath).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textTertiary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var configuration: some View {
        let label: String
        if row.unavailable == nil { label = row.configuration }
        else if row.host.unavailable == nil { label = "directory unavailable" }
        else { label = "host unavailable" }
        return VStack(alignment: .leading, spacing: NW.Space.xs) {
            Text(label).font(.nwSans(AppLayout.projectsHostSize))
                .foregroundStyle(row.unavailable != nil ? Color.nw.textTertiary : Color.nw.textSecondary)
            if let parent = row.parentName, !row.project.inheritedMCP.isEmpty, row.unavailable == nil {
                Text("From \(parent)").font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var action: some View {
        if row.isSubproject {
            Button("Open project", action: open)
                .buttonStyle(.nw(.ghost, size: .s))
        } else {
            Button("Add subproject", systemImage: "plus", action: addSubproject)
                .buttonStyle(.nw(.ghost, size: .s))
                .disabled(row.unavailable != nil)
                .accessibilityLabel("Add subproject to \(row.project.name)")
        }
    }
}
