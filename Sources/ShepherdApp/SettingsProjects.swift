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
        .accessibilityHint(hint)
        .help(tooltip)
    }

    private var hint: String { row.unavailable ?? "\(row.project.displayPath), \(row.project.summary)" }
    private var tooltip: String { row.unavailable ?? "\(row.project.directory)\n\(row.project.summary)" }

    private var identity: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            Text(row.project.name).font(.nwSans(AppLayout.projectsNameSize, .medium)).foregroundStyle(Color.nw.textPrimary)
            Text(row.project.displayPath).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.settingsMuted)
        }.lineLimit(1)
    }

    private var summary: some View {
        let label: String
        if row.unavailable == nil { label = row.project.summary }
        else if row.host.unavailable == nil { label = "directory unavailable" }
        else { label = "host unavailable" }
        let color = row.project.minimal || row.unavailable != nil ? Color.nw.settingsMuted : Color.nw.textSecondary
        return Text(label).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(color).lineLimit(1)
    }
}
