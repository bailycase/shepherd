import SwiftUI
import ShepherdUI
import ShepherdProtocol

struct ProjectsSettings: View {
    let vm: ShepherdViewModel
    @Bindable var model: ProjectsModel
    @State private var adding: ProjectsHost?

    var body: some View {
        Group {
            if let project = model.selected {
                ProjectSettingsDetail(model: model, project: project)
            } else {
                index
            }
        }
        .nwControlScale(.settings)
        .task(id: vm.projectsSources) { await model.load(vm.projectsSources) }
        .sheet(item: $adding) { host in
            RemoteDirectoryPicker(title: "Add project", actionTitle: "Add project", hostName: host.name,
                                  startPath: host.known.first?.directory ?? "", list: { path in
                if host.id == "local" { return try await LocalDirectoryLister.load(path: path) }
                guard vm.remoteHosts.connections.first(where: { $0.id.uuidString == host.id })?.endpointID == host.endpointID else {
                    throw ProjectFileError("host_changed", "The host address changed. Close the picker and choose the host again.")
                }
                return try await vm.remoteHosts.listDir(hostID: UUID(uuidString: host.id)!, path: path)
            }, choose: { path in
                adding = nil
                Task {
                    do { try await vm.addSettingsProject(path: path, host: host) }
                    catch { model.error = String(describing: error) }
                }
            }, cancel: { adding = nil })
        }
    }

    private var index: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectsSpacing) {
            SettingsHeader(title: "Projects", explanation: "Every folder Shepherd has run an agent in. Open one to edit what applies only there: its instructions, pi settings, skills, extensions and MCP servers.", titleSize: AppLayout.projectsTitleSize, explanationSize: AppLayout.projectsExplanationSize)
                .frame(maxWidth: AppLayout.projectsTextWidth, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppLayout.projectsToolbarGap) { filter; hosts; Spacer(minLength: 0); add }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    HStack(spacing: AppLayout.projectsToolbarGap) { filter; Spacer(minLength: 0); add }
                    ScrollView(.horizontal) { hosts }.scrollIndicators(.hidden)
                }
            }
            if let error = model.error { SettingsNote(text: error) }
            table
            Text("Instructions in AGENTS.md and settings in a project's .pi folder apply only to that project. Each one is stored on the host the project lives on.")
                .nwText(size: AppLayout.projectsHostSize, lineHeight: AppLayout.projectsFooterLineHeight)
                .foregroundStyle(Color.nw.settingsMuted)
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

    private var add: some View {
        Button("Add project…") { adding = model.addHost }
            .buttonStyle(.nw(.raised))
            .disabled(model.addHost == nil || model.addHost?.unavailable != nil)
    }

    private var table: some View {
        VStack(spacing: 0) {
            ProjectColumns {
                Text("PROJECT"); Text("HOST"); Text("SET ONLY HERE"); Color.clear
            }
            .font(.nwMono(AppLayout.projectsHeaderSize))
            .tracking(AppLayout.projectsHeaderSize * AppLayout.projectsHeaderTracking)
            .foregroundStyle(Color.nw.settingsMuted)
            .frame(height: AppLayout.projectsHeaderHeight)
            .background(Color.nw.bgSunken)
            NWHairline()
            LazyVStack(spacing: 0) {
                ForEach(model.visible) { row in
                    VStack(spacing: 0) {
                        ProjectSettingsRow(row: row) { Task { await model.open(row) } }
                        if row.id != model.visible.last?.id { NWHairline() }
                    }
                }
            }
            if model.visible.isEmpty {
                Text(model.loading ? "Loading projects…" : model.rows.isEmpty ? "No projects yet. Add a folder to get started." : "No projects match your filter.")
                    .font(.nw(.body)).foregroundStyle(Color.nw.textTertiary)
                    .padding(NW.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
        .nwBorder(Color.nw.lineSubtle, radius: NWCardRowMetrics.settingsCardRadius)
    }
}

/// The board's 1.5:1 flexible columns, then its fixed summary and disclosure columns.
private struct ProjectColumns<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            let flexible = max(0, geometry.size.width - AppLayout.projectsSummaryWidth - AppLayout.projectsDisclosureWidth
                               - AppLayout.projectsColumnGap * 3 - NW.Space.xl * 2)
            HStack(spacing: AppLayout.projectsColumnGap) {
                Group(subviews: content) { columns in
                    ForEach(columns.indices, id: \.self) { index in
                        columns[index]
                            .frame(width: index == 0 ? flexible * AppLayout.projectsNameRatio / (AppLayout.projectsNameRatio + AppLayout.projectsHostRatio)
                                   : index == 1 ? flexible * AppLayout.projectsHostRatio / (AppLayout.projectsNameRatio + AppLayout.projectsHostRatio)
                                   : index == 2 ? AppLayout.projectsSummaryWidth : AppLayout.projectsDisclosureWidth, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, NW.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectSettingsRow: View {
    let row: ProjectsRow
    let open: () -> Void
    var body: some View {
        let _ = NWRenderProbe.tick("settings.project.row")
        Button(action: open) {
            ProjectColumns {
                identity
                Text(row.host.name).font(.nwSans(AppLayout.projectsHostSize)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
                summary
                Image(systemName: "chevron.right").font(.nwSans(AppLayout.projectsChevronSize)).foregroundStyle(Color.nw.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AppLayout.projectsRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow())
        .accessibilityLabel("Open \(row.project.name) on \(row.host.name)")
        .accessibilityHint(row.unavailable ?? row.project.displayPath + ", " + row.project.summary)
        .help(row.unavailable ?? row.project.directory + "\n" + row.project.summary)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            Text(row.project.name).font(.nwSans(AppLayout.projectsNameSize, .medium)).foregroundStyle(Color.nw.textPrimary)
            Text(row.project.displayPath).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.settingsMuted)
        }.lineLimit(1)
    }

    private var summary: some View {
        Text(row.unavailable == nil ? row.project.summary : row.host.unavailable == nil ? "directory unavailable" : "host unavailable")
            .font(.nwMono(AppLayout.projectsPathSize))
            .foregroundStyle(row.project.minimal || row.unavailable != nil ? Color.nw.settingsMuted : Color.nw.textSecondary)
            .lineLimit(1)
    }
}

struct ProjectSettingsDetail: View {
    @Bindable var model: ProjectsModel
    let project: ProjectsRow

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectsSpacing) {
            Button("Back to Projects") { Task { await model.navigate(.close) } }.buttonStyle(.nw(.ghost)).disabled(model.saving)
            SettingsHeader(title: project.project.name, explanation: "Project settings on \(project.host.name). Changes apply only in this directory.")
            Text(project.project.displayPath).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textTertiary)
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xs) {
                    ForEach(ProjectFile.Category.allCases, id: \.self) { category in
                        Button { Task { await model.navigate(.category(category)) } } label: {
                            Text(category.title).font(.nw(.body))
                                .padding(.horizontal, NW.Space.l)
                                .frame(minHeight: NW.Height.controlL)
                        }
                            .buttonStyle(.nwRow(selected: category == model.category, selectedFill: Color.nw.settingsNavSelected))
                            .accessibilityLabel("Project category \(category.title)")
                            .accessibilityAddTraits(category == model.category ? .isSelected : [])
                            .disabled(model.saving || model.fileLoading)
                    }
                }
            }.scrollIndicators(.hidden)
            if let unavailable = project.unavailable { SettingsNote(text: unavailable) }
            if let error = model.fileError { SettingsNote(text: error) }
            if let notice = model.notice { SettingsNote(text: notice) }
            if model.fileLoading {
                Text("Loading project file…").font(.nw(.body)).foregroundStyle(Color.nw.textTertiary)
            } else if model.selectedFiles.isEmpty {
                SettingsNote(text: model.category == .skills ? "No project skills. Add a SKILL.md in .pi/skills or .agents/skills." : "No project files in this category.")
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: NW.Space.m) {
                        ForEach(model.selectedFiles) { file in
                            Button { Task { await model.navigate(.file(file)) } } label: {
                                Text(file.path).font(.nw(.body))
                                    .padding(.horizontal, NW.Space.l)
                                    .frame(minHeight: NW.Height.controlL)
                            }
                                .buttonStyle(.nwRow(selected: file.path == model.selectedFile?.path, selectedFill: Color.nw.settingsNavSelected))
                                .disabled(model.saving)
                        }
                    }
                }.scrollIndicators(.hidden)
                editor
            }
            if model.pending != nil {
                SettingsGroup(title: "Unsaved changes") {
                    SettingsRow(title: "Discard unsaved changes?", subtitle: "The project file on disk has not been changed.") {
                        HStack(spacing: NW.Space.m) {
                            Button("Keep editing") { model.pending = nil }.buttonStyle(.nw())
                            Button("Discard changes") { Task { await model.discard() } }.buttonStyle(.nw(.danger))
                        }
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Text(model.selectedFile?.path ?? "").font(.nwMono(AppLayout.instructionsPathSize)).foregroundStyle(Color.nw.textSecondary)
                Spacer(minLength: 0)
                if model.dirty { Text("edited").font(.nwSans(AppLayout.instructionsEditedSize)).foregroundStyle(Color.nw.textSecondary) }
                Button("Revert") { if let file = model.selectedFile { Task { await model.read(file) } } }.buttonStyle(.nw()).disabled(!model.fileLoaded || model.saving)
                Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }.buttonStyle(.nw(.primary))
                    .disabled(!model.dirty || model.saving || project.unavailable != nil)
            }.padding(NW.Space.l)
            NWHairline()
            if model.fileLoaded {
                InstructionsEditor(text: $model.draft, saved: model.saved ?? "", accessibilityLabel: "Project file editor")
                    .frame(height: AppLayout.projectsEditorHeight)
                    .disabled(model.saving || project.unavailable != nil)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
        .nwBorder(Color.nw.lineSubtle, radius: NWCardRowMetrics.settingsCardRadius)
    }
}
