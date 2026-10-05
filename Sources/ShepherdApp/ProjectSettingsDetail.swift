import SwiftUI
import ShepherdProtocol
import ShepherdUI

struct ProjectSettingsDetail: View {
    @Environment(\.displayScale) private var displayScale
    @Bindable var model: ProjectsModel
    let project: ProjectsRow
    @Bindable var cookies: ProjectCookiesModel
    let cookieScope: ProjectCookieScope?
    @State private var hoveredTab: String?

    private var categories: [(ProjectFile.Category, String)] {
        [(.instructions, "Instructions"), (.pi, "Settings"), (.skills, "Resources"), (.mcp, "MCP servers")]
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width - AppLayout.settingsWideSides * 2 < AppLayout.projectColumnsMinimumWidth
            VStack(alignment: .leading, spacing: AppLayout.projectDetailGap) {
                if model.showingBrowser {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NW.Space.xxl) {
                            header.disabled(cookies.pending != nil || cookies.clearing).accessibilityHidden(cookies.pending != nil)
                            ProjectBrowserSettings(model: cookies, project: project, scope: cookieScope)
                        }.padding(.bottom, AppLayout.settingsBottom)
                    }
                } else {
                    header.frame(maxWidth: .infinity, alignment: .leading).disabled(cookies.clearing)
                    if narrow {
                        ScrollView {
                            VStack(alignment: .leading, spacing: AppLayout.projectSideGap) {
                                editorColumn.frame(height: AppLayout.projectNarrowEditorHeight)
                                contextColumn
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: AppLayout.projectColumnsGap) {
                            editorColumn
                            contextColumn.frame(width: AppLayout.projectSideWidth)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SettingsPageContent")
                .padding(.top, AppLayout.projectDetailTop)
                .padding(.horizontal, AppLayout.settingsWideSides)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Button { Task { await model.navigate(.close) } } label: {
                    Text("Projects").frame(minHeight: NW.Height.controlS).contentShape(Rectangle())
                }.buttonStyle(.nwRow(focusColor: .nw.running)).accessibilityLabel("Back to Projects").disabled(model.saving || cookies.clearing)
                NWGlyph.Settings.next.image.foregroundStyle(Color.nw.textSecondary).accessibilityHidden(true)
                Text(project.project.name).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            }.font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(Color.nw.textSecondary)
                .frame(height: AppLayout.projectBreadcrumbHeight)
            HStack(spacing: NW.Space.l) {
                NWGlyph.Settings.folder.image.foregroundStyle(Color.nw.textSecondary)
                    .frame(width: AppLayout.projectFolderSize, height: AppLayout.projectFolderSize)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m, width: NWSettingsNavMetrics.borderWidth)
                Text(project.project.name).font(.nwSans(AppLayout.projectsTitleSize, .semibold))
                    .tracking(AppLayout.projectNameTracking * ThemeStore.shared.textScale)
                    .foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(project.host.name).font(.nwMono(AppLayout.projectsPathSize))
                    .foregroundStyle(Color.nw.textSecondary).lineLimit(1)
                    .offset(y: AppLayout.projectHostBaseline * ThemeStore.shared.textScale)
            }.frame(height: AppLayout.projectIdentityHeight)
            Text(project.project.displayPath).font(.nwMono(AppLayout.projectsPathSize))
                .foregroundStyle(Color.nw.textSecondary).lineLimit(1)
                .padding(.leading, AppLayout.projectPathInset).frame(height: AppLayout.projectPathHeight)
                .offset(y: AppLayout.projectPathBaseline * ThemeStore.shared.textScale)
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xs) {
                    ForEach(categories, id: \.0) { category, label in
                        Button { Task { await model.navigate(.category(category)) } } label: {
                            HStack(spacing: NW.Space.s) {
                                Text(label).font(.nwSans(AppLayout.projectTabSize, !model.showingBrowser && model.category == category ? .medium : .regular))
                                if category == .skills { tabCount(model.context.resources) }
                                if category == .mcp { tabCount(model.context.mcpServers) }
                            }.offset(y: AppLayout.projectTabBaseline * ThemeStore.shared.textScale)
                                .padding(.horizontal, NW.Space.l).frame(height: AppLayout.projectTabHeight)
                                .foregroundStyle(!model.showingBrowser && model.category == category || hoveredTab == label ? Color.nw.textPrimary : Color.nw.textSecondary)
                                .overlay(alignment: .bottom) {
                                    if !model.showingBrowser && model.category == category { Color.nw.lantern.frame(height: AppLayout.projectTabUnderline) }
                                }.contentShape(Rectangle())
                        }.buttonStyle(.nwRow(radius: AppLayout.projectTabRadius, focusColor: .nw.running))
                            .onHover { hoveredTab = $0 ? label : nil }
                            .accessibilityLabel("Project category \(label)")
                            .disabled(model.saving || model.fileLoading || cookies.clearing)
                    }
                    Button { Task { await model.navigate(.browser) } } label: {
                        Text("Browser").font(.nwSans(AppLayout.projectTabSize, model.showingBrowser ? .medium : .regular))
                            .offset(y: AppLayout.projectTabBaseline * ThemeStore.shared.textScale)
                            .foregroundStyle(model.showingBrowser || hoveredTab == "Browser" ? Color.nw.textPrimary : Color.nw.textSecondary)
                            .padding(.horizontal, NW.Space.l).frame(height: AppLayout.projectTabHeight)
                            .overlay(alignment: .bottom) {
                                if model.showingBrowser { Color.nw.lantern.frame(height: AppLayout.projectTabUnderline) }
                            }.contentShape(Rectangle())
                    }.buttonStyle(.nwRow(radius: AppLayout.projectTabRadius, focusColor: .nw.running))
                        .onHover { hoveredTab = $0 ? "Browser" : nil }
                        .accessibilityLabel("Project category Browser").disabled(model.saving || cookies.clearing)
                }
            }.scrollIndicators(.hidden).frame(height: AppLayout.projectTabHeight)
                .background(alignment: .bottom) { Color.nw.lineSubtle.frame(height: NWSettingsNavMetrics.borderWidth) }
        }.frame(height: AppLayout.projectHeaderHeight)
    }

    private func tabCount(_ count: Int) -> some View {
        Text(count.formatted()).font(.nwMono(NWTextStyle.micro.size)).foregroundStyle(Color.nw.textSecondary)
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectFileGap) {
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.s) {
                    ForEach(model.selectedFiles) { file in
                        Button { Task { await model.navigate(.file(file)) } } label: {
                            Text(file.path.hasSuffix("/SKILL.md") ? URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent : URL(fileURLWithPath: file.path).lastPathComponent)
                                .font(.nwMono(AppLayout.projectsPathSize, file.path == model.selectedFile?.path ? .semibold : .regular))
                                .foregroundStyle(file.path == model.selectedFile?.path ? Color.nw.textPrimary : file.exists ? Color.nw.textSecondary : Color.nw.settingsMuted)
                                .padding(.horizontal, AppLayout.projectFilePadding).frame(height: AppLayout.projectFileHeight)
                                .background(file.path == model.selectedFile?.path ? Color.nw.settingsNavSelected : .clear,
                                            in: RoundedRectangle(cornerRadius: NW.Radius.s))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(file.path).disabled(model.saving || model.fileLoading)
                    }
                    if let file = model.selectedFile {
                        Spacer(minLength: 0)
                        Text(project.project.displayPath + "/" + file.path).font(.nwMono(AppLayout.projectsPathSize))
                            .foregroundStyle(Color.nw.settingsMuted).lineLimit(1)
                    }
                }
            }.scrollIndicators(.hidden).frame(height: AppLayout.projectFileHeight)
            if let error = model.fileError {
                Text(error).font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(Color.nw.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.pending != nil {
                HStack {
                    Text("Discard unsaved changes?").font(.nwSans(AppLayout.projectFileSize))
                    Spacer()
                    Button("Keep editing") { model.pending = nil }.buttonStyle(.nw(.ghost))
                    Button("Discard") { Task { await model.discard() } }.buttonStyle(.nw())
                }
            }
            if model.selectedFile?.path == ".pi/settings.json", model.fileLoaded {
                SettingsGroup(title: "Tools") {
                    SettingsRow(title: "Codemode",
                                subtitle: "Overrides this host's global setting for this project. Save the file, then start or restart the agent.",
                                problem: model.codemodeProblem) {
                        NWSegmentedPicker("Project codemode", selection: $model.projectCodemode,
                                          options: [(ProjectsModel.CodemodeChoice.inherit, "Use global default"), (.on, "On"), (.off, "Off")])
                            .disabled(model.codemodeProblem != nil || model.saving || model.selected?.unavailable != nil)
                    }
                }
            }
            editor
            footer
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProjectEditorColumn")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppLayout.projectFileGap) {
                Text(model.category == .instructions ? "Markdown" : model.selectedFile?.path.hasSuffix(".json") == true ? "JSON" : "Text")
                    .font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textSecondary)
                Spacer(minLength: 0)
                Text(model.tokenText).font(.nwMono(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.settingsMuted)
                Color.nw.lineStrong.frame(width: AppLayout.projectMetadataRule, height: AppLayout.projectDividerHeight)
                Text(model.editedLabel).font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            }.padding(.horizontal, NW.Space.l).frame(height: AppLayout.projectEditorHeaderHeight).background(Color.nw.projectEditorHeader)
            NWHairline()
            if model.fileLoaded {
                InstructionsEditor(text: $model.draft, saved: model.saved ?? "",
                                   accessibilityLabel: "Project file editor", project: true, markdown: model.category == .instructions)
                    .disabled(project.unavailable != nil || model.saving)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NWEmptyState(Text(model.fileLoading ? "Loading file…" : "No project file"),
                             message: model.fileLoading ? "Reading from \(project.host.name)." : "Choose a file or add this resource in the project folder.") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.nw.projectEditorBackground)
            .clipShape(RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
            .nwBorder(Color.nw.lineStrong, radius: NWCardRowMetrics.settingsCardRadius)
    }

    private var footer: some View {
        HStack(spacing: AppLayout.projectFileGap) {
            Text(model.dirty ? "Unsaved changes" : model.savedNotice)
                .font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(Color.nw.settingsMuted).lineLimit(2)
            Spacer(minLength: 0)
            Button { Task { await model.openInEditor() } } label: {
                Text(model.openingEditor ? "Opening…" : "Open in editor").font(.nwSans(AppLayout.projectsHostSize, .medium))
                    .padding(.horizontal, NW.Space.l).frame(height: AppLayout.projectEditorButtonHeight)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m)
            }.buttonStyle(.plain).disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
            Button { Task { await model.save() } } label: {
                Text(model.saving ? "Saving…" : "Save").font(.nwSans(AppLayout.projectsHostSize, .semibold))
                    .foregroundStyle(Color.nw.bgWindow).padding(.horizontal, AppLayout.projectSavePad)
                    .frame(height: AppLayout.projectEditorButtonHeight)
                    .background(Color.nw.lantern, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            }.buttonStyle(.plain)
                .disabled(model.saving || !model.fileLoaded || project.unavailable != nil)
        }.foregroundStyle(Color.nw.textPrimary).frame(height: AppLayout.projectEditorFooterHeight)
    }

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectSideGap) {
            if model.category == .instructions {
                readingCard
                hostsCard
                Text("APPEND_SYSTEM.md adds to the system prompt and SYSTEM.md replaces it. Both live in the project's .pi folder.")
                    .font(.nwSans(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.settingsMuted)
                    .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
            } else { hostsCard }
        }.padding(.top, AppLayout.projectContextTop).frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProjectContextColumn")
    }

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text("WHAT AN AGENT READS HERE").font(.nwMono(NWTextStyle.micro.size))
                .tracking(NWTextStyle.micro.size * AppLayout.projectReadingTracking).foregroundStyle(Color.nw.settingsMuted)
            VStack(spacing: 0) {
                ForEach(model.readRows) { row in
                    if row.id != model.readRows.first?.id { Color.nw.projectRowDivider.frame(height: NW.hairline(displayScale)) }
                    HStack(spacing: NW.Space.m) {
                        Circle().fill(row.selected ? Color.nw.running : Color.nw.textTertiary)
                            .frame(width: AppLayout.projectDotSize, height: AppLayout.projectDotSize)
                        Text(row.label).font(.nwSans(AppLayout.projectFileSize)).lineLimit(1)
                            .foregroundStyle(row.selected ? Color.nw.textPrimary : Color.nw.textSecondary)
                        Spacer(minLength: 0)
                        Text(row.scope).font(.nwMono(NWTextStyle.micro.size)).lineLimit(1)
                            .foregroundStyle(row.selected ? Color.nw.running : Color.nw.settingsMuted)
                    }.padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.s)
                        .frame(minHeight: AppLayout.projectReadRowHeight)
                }
            }.clipShape(RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
                .nwBorder(Color.nw.projectDivider, radius: NWCardRowMetrics.settingsCardRadius)
            Text("Pi loads every context file from the folder up to the root. A file in a folder applies there and below.")
                .font(.nwSans(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.settingsMuted)
                .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostsCard: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text("Hosts").font(.nwSans(AppLayout.projectsHostSize, .semibold)).foregroundStyle(Color.nw.textPrimary)
            Text(hostsDescription).font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(Color.nw.textSecondary)
                .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
            ForEach(model.peers) { peer in
                HStack(spacing: NW.Space.s) {
                    Circle().fill(peer.tone == .done ? Color.nw.done : InstructionsHostChip.color(peer.tone)).frame(width: AppLayout.projectDotSize, height: AppLayout.projectDotSize)
                    Text(peer.status).font(.nwSans(AppLayout.projectFileSize)).foregroundStyle(InstructionsHostChip.color(peer.tone))
                }
            }
        }.padding(.horizontal, AppLayout.projectSavePad).padding(.vertical, NW.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
            .nwBorder(Color.nw.lineStrong, radius: NWCardRowMetrics.settingsCardRadius)
    }

    private var hostsDescription: String {
        guard let peer = model.peers.first else { return "This is the copy on \(project.host.name). No other host has this project." }
        if peer.status == "In sync" { return "This is the copy on \(project.host.name). \(peer.host) has its own checkout of \(project.project.name), and its \(model.selectedFile?.path ?? "file") matches." }
        return peer.note
    }
}
