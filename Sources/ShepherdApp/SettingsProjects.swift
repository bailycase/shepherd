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
        .shControlScale(.settings)
        .task(id: vm.projectsSources) { await model.load(vm.projectsSources) }
        .sheet(item: $addingChild) { model in
            ChildProjectSheet(model: model, dismiss: { addingChild = nil })
        }
        .sheet(item: $adding) { adding in
            let host = adding.host
            RemoteDirectoryPicker(title: "Add space", actionTitle: "Add space", hostName: host.name,
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
            HStack(alignment: .center, spacing: SH.Space.xl) {
                SettingsHeader(title: "Spaces", explanation: "Organize spaces without moving folders. Settings still follow folder ancestry.",
                               titleSize: AppLayout.projectsTitleSize, explanationSize: AppLayout.projectsExplanationSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                add
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.xl) { filter; hosts; Spacer(minLength: 0); count }
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    HStack(spacing: SH.Space.xl) { filter; Spacer(minLength: 0); count }
                    ScrollView(.horizontal) { hosts }.scrollIndicators(.hidden)
                }
            }
            if let error = model.error { SettingsNote(text: error) }
            table
            Text("Space grouping changes only Shepherd. Instructions and settings follow folders on disk.")
                .shText(size: AppLayout.projectsHostSize, lineHeight: AppLayout.projectsFooterLineHeight)
                .foregroundStyle(Color.sh.textSecondary)
                .frame(maxWidth: AppLayout.projectsTextWidth, alignment: .leading)
        }
    }

    private var filter: some View {
        SHSearchField("Filter spaces", text: $model.filter)
            .frame(width: AppLayout.projectsFilterWidth)
    }

    private var hosts: some View {
        SHSegmentedPicker("Space hosts", selection: $model.host, options: model.hostOptions)
    }

    private var count: some View {
        Text(model.countText)
            .font(.shSans(AppLayout.projectsHostSize))
            .foregroundStyle(Color.sh.textSecondary)
            .fixedSize()
    }

    private var add: some View {
        Button("Add space", systemImage: "plus") { adding = model.addHost.map { AddingProject(host: $0) } }
            .buttonStyle(.sh(.primary))
            .disabled(model.addHost == nil || model.addHost?.unavailable != nil)
    }

    private var table: some View {
        VStack(spacing: 0) {
            ProjectColumns {
                Text("SPACE"); Text("HOST"); Text("CONFIGURATION"); Color.clear
            }
            .font(.shMono(AppLayout.projectsHeaderSize))
            .foregroundStyle(Color.sh.textTertiary)
            .frame(height: AppLayout.projectsHeaderHeight)
            .background(Color.sh.bgSunken)
            SHHairline()
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
                                       }, remove: row.host.id == "local" && row.project.projectID != nil
                                           ? { vm.spaceDeleteTarget = row.project.projectID } : nil,
                                       rename: row.host.id == "local" && row.project.projectID != nil
                                           ? { vm.spaceRenameTarget = row.project.projectID } : nil)
                        if row.id != model.visible.last?.id { SHHairline() }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spaces and subspaces")
            if model.visible.isEmpty {
                Text(model.loading ? "Loading spaces…" : model.rows.isEmpty ? "No spaces yet. Add a folder to get started." : "No spaces match your filter.")
                    .font(.sh(.body)).foregroundStyle(Color.sh.textTertiary)
                    .padding(SH.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
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
        HStack(spacing: SH.Space.xl) {
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
        .padding(.horizontal, SH.Space.xl)
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
    var remove: (() -> Void)? = nil
    var rename: (() -> Void)? = nil

    var body: some View {
        let _ = SHRenderProbe.tick("settings.project.row")
        ProjectColumns {
            HStack(spacing: SH.Space.m) {
                if row.children > 0 {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.shSans(AppLayout.projectsChevronSize))
                            .foregroundStyle(Color.sh.textSecondary)
                            .frame(width: AppLayout.projectsToggleWidth, height: AppLayout.projectsToggleHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.shRow())
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(row.project.name)")
                } else {
                    Color.clear.frame(width: AppLayout.projectsToggleWidth, height: 1)
                }
                Button(action: open) { identity }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.isSubproject ? "Open \(row.project.name) under \(row.parentName!)" : "Open \(row.project.name)")
                    .accessibilityHint(row.unavailable ?? row.project.displayPath)
                    .accessibilityActions {
                        if let rename { Button("Rename Space…", action: rename) }
                        if let remove { Button("Remove Space…", role: .destructive, action: remove) }
                    }
            }
            .padding(.leading, CGFloat(row.ancestorIDs.count) * SH.Space.xxl)
            Text(row.host.name).font(.shSans(AppLayout.projectsHostSize)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            configuration
            action
        }
        .padding(.vertical, SH.Space.l)
        .frame(minHeight: AppLayout.projectsRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(row.unavailable ?? "\(row.project.directory)\n\(row.configuration)")
        .contextMenu {
            if let rename { Button("Rename Space…", action: rename) }
            if let remove { Button("Remove Space…", role: .destructive, action: remove) }
        }
    }

    private var identity: some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "folder")
                .font(.shSans(AppLayout.projectsFolderSize))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.projectsFolderFrame, height: AppLayout.projectsFolderFrame)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                HStack(spacing: SH.Space.m) {
                    Text(row.project.name).font(.shSans(AppLayout.projectsNameSize, .medium)).foregroundStyle(Color.sh.textPrimary)
                    if row.children > 0 {
                        Text(row.children == 1 ? "1 subspace" : "\(row.children) subspaces")
                            .font(.shSans(AppLayout.projectsPathSize))
                            .foregroundStyle(Color.sh.textSecondary)
                            .padding(.horizontal, SH.Space.s)
                            .padding(.vertical, SH.Space.xxs)
                            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                            .fixedSize()
                    }
                }
                Text(row.project.displayPath).font(.shMono(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.textTertiary)
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
        return VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(label).font(.shSans(AppLayout.projectsHostSize))
                .foregroundStyle(row.unavailable != nil ? Color.sh.textTertiary : Color.sh.textSecondary)
            if let parent = row.project.inheritedFromName ?? row.parentName, !row.project.inheritedMCP.isEmpty, row.unavailable == nil {
                Text("From \(parent)").font(.shMono(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.textTertiary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var action: some View {
        if row.isSubproject {
            Button("Open space", action: open)
                .buttonStyle(.sh(.ghost, size: .s))
        } else {
            Button("Add subspace", systemImage: "plus", action: addSubproject)
                .buttonStyle(.sh(.ghost, size: .s))
                .disabled(row.unavailable != nil)
                .accessibilityLabel("Add subspace to \(row.project.name)")
        }
    }
}
