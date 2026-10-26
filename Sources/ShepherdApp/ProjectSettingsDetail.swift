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
                        VStack(alignment: .leading, spacing: SH.Space.xxl) {
                            header.disabled(cookies.pending != nil || cookies.clearing).accessibilityHidden(cookies.pending != nil)
                            ProjectBrowserSettings(model: cookies, project: project, scope: cookieScope)
                        }.padding(.bottom, AppLayout.settingsBottom)
                    }
                } else {
                    header.frame(maxWidth: .infinity, alignment: .leading).disabled(cookies.clearing)
                    if model.category == .mcp {
                        editorColumn
                    } else if narrow {
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
            HStack(spacing: SH.Space.m) {
                Button { Task { await model.navigate(.close) } } label: {
                    Text("Spaces").frame(minHeight: SH.Height.controlS).contentShape(Rectangle())
                }.buttonStyle(.shRow(focusColor: .sh.running)).accessibilityLabel("Back to Spaces").disabled(model.saving || cookies.clearing)
                SHGlyph.Settings.next.image.foregroundStyle(Color.sh.textSecondary).accessibilityHidden(true)
                Text(project.project.name).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }.font(.shSans(AppLayout.projectFileSize)).foregroundStyle(Color.sh.textSecondary)
                .frame(height: AppLayout.projectBreadcrumbHeight)
            HStack(spacing: SH.Space.l) {
                SHGlyph.Settings.folder.image.foregroundStyle(Color.sh.textSecondary)
                    .frame(width: AppLayout.projectFolderSize, height: AppLayout.projectFolderSize)
                    .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.m, width: SHSettingsNavMetrics.borderWidth)
                Text(project.project.name).font(.shSans(AppLayout.projectsTitleSize, .semibold))
                    .tracking(AppLayout.projectNameTracking * ThemeStore.shared.textScale)
                    .foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(project.host.name).font(.shMono(AppLayout.projectsPathSize))
                    .foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    .offset(y: AppLayout.projectHostBaseline * ThemeStore.shared.textScale)
            }.frame(height: AppLayout.projectIdentityHeight)
            Text(project.project.displayPath).font(.shMono(AppLayout.projectsPathSize))
                .foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                .padding(.leading, AppLayout.projectPathInset).frame(height: AppLayout.projectPathHeight)
                .offset(y: AppLayout.projectPathBaseline * ThemeStore.shared.textScale)
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.xs) {
                    ForEach(categories, id: \.0) { category, label in
                        Button { Task { await model.navigate(.category(category)) } } label: {
                            HStack(spacing: SH.Space.s) {
                                Text(label).font(.shSans(AppLayout.projectTabSize, !model.showingBrowser && model.category == category ? .medium : .regular))
                                if category == .skills { tabCount(model.context.resources) }
                                if category == .mcp { tabCount(model.context.mcpServers) }
                            }.offset(y: AppLayout.projectTabBaseline * ThemeStore.shared.textScale)
                                .padding(.horizontal, SH.Space.l).frame(height: AppLayout.projectTabHeight)
                                .foregroundStyle(!model.showingBrowser && model.category == category || hoveredTab == label ? Color.sh.textPrimary : Color.sh.textSecondary)
                                .overlay(alignment: .bottom) {
                                    if !model.showingBrowser && model.category == category { Color.sh.lantern.frame(height: AppLayout.projectTabUnderline) }
                                }.contentShape(Rectangle())
                        }.buttonStyle(.shRow(radius: AppLayout.projectTabRadius, focusColor: .sh.running))
                            .onHover { hoveredTab = $0 ? label : nil }
                            .accessibilityLabel("Space category \(label)")
                            .disabled(model.saving || model.fileLoading || cookies.clearing)
                    }
                    Button { Task { await model.navigate(.browser) } } label: {
                        Text("Browser").font(.shSans(AppLayout.projectTabSize, model.showingBrowser ? .medium : .regular))
                            .offset(y: AppLayout.projectTabBaseline * ThemeStore.shared.textScale)
                            .foregroundStyle(model.showingBrowser || hoveredTab == "Browser" ? Color.sh.textPrimary : Color.sh.textSecondary)
                            .padding(.horizontal, SH.Space.l).frame(height: AppLayout.projectTabHeight)
                            .overlay(alignment: .bottom) {
                                if model.showingBrowser { Color.sh.lantern.frame(height: AppLayout.projectTabUnderline) }
                            }.contentShape(Rectangle())
                    }.buttonStyle(.shRow(radius: AppLayout.projectTabRadius, focusColor: .sh.running))
                        .onHover { hoveredTab = $0 ? "Browser" : nil }
                        .accessibilityLabel("Space category Browser").disabled(model.saving || cookies.clearing)
                }
            }.scrollIndicators(.hidden).frame(height: AppLayout.projectTabHeight)
                .background(alignment: .bottom) { Color.sh.lineSubtle.frame(height: SHSettingsNavMetrics.borderWidth) }
        }.frame(height: AppLayout.projectHeaderHeight)
    }

    private func tabCount(_ count: Int) -> some View {
        Text(count.formatted()).font(.shMono(SHTextStyle.micro.size)).foregroundStyle(Color.sh.textSecondary)
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectFileGap) {
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.s) {
                    ForEach(model.selectedFiles) { file in
                        Button { Task { await model.navigate(.file(file)) } } label: {
                            Text(file.path)
                                .font(.shMono(AppLayout.projectsPathSize, file.path == model.selectedFile?.path ? .semibold : .regular))
                                .foregroundStyle(file.path == model.selectedFile?.path ? Color.sh.textPrimary : file.exists ? Color.sh.textSecondary : Color.sh.settingsMuted)
                                .padding(.horizontal, AppLayout.projectFilePadding).frame(height: AppLayout.projectFileHeight)
                                .background(file.path == model.selectedFile?.path ? Color.sh.settingsNavSelected : .clear,
                                            in: RoundedRectangle(cornerRadius: SH.Radius.s))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(file.path).disabled(model.saving || model.fileLoading)
                    }
                    if let file = model.selectedFile {
                        Spacer(minLength: 0)
                        Text(project.project.displayPath + "/" + file.path).font(.shMono(AppLayout.projectsPathSize))
                            .foregroundStyle(Color.sh.settingsMuted).lineLimit(1)
                    }
                }
            }.scrollIndicators(.hidden).frame(height: AppLayout.projectFileHeight)
            if let error = model.fileError {
                Text(error).font(.shSans(AppLayout.projectFileSize)).foregroundStyle(Color.sh.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.pending != nil {
                HStack {
                    Text("Discard unsaved changes?").font(.shSans(AppLayout.projectFileSize))
                    Spacer()
                    Button("Keep editing") { model.pending = nil }.buttonStyle(.sh(.ghost))
                    Button("Discard") { Task { await model.discard() } }.buttonStyle(.sh())
                }
            }
            if model.selectedFile?.category == .pi, model.fileLoaded {
                SettingsGroup(title: "Tools") {
                    SettingsRow(title: "Codemode",
                                subtitle: "Overrides this host's global setting for this space. Save the file, then start or restart the agent.",
                                problem: model.codemodeProblem) {
                        SHSegmentedPicker("Space codemode", selection: $model.projectCodemode,
                                          options: [(ProjectsModel.CodemodeChoice.inherit, "Use global default"), (.on, "On"), (.off, "Off")])
                            .disabled(model.codemodeProblem != nil || model.saving || model.selected?.unavailable != nil)
                    }
                }
            }
            if model.category == .mcp, model.fileLoaded {
                ProjectMCPSettings(model: model).id(model.selectedFile?.path)
            } else { editor }
            footer
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProjectEditorColumn")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppLayout.projectFileGap) {
                Text(model.category == .instructions ? "Markdown" : model.selectedFile?.path.hasSuffix(".json") == true ? "JSON" : "Text")
                    .font(.shMono(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.textSecondary)
                Spacer(minLength: 0)
                Text(model.tokenText).font(.shMono(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.settingsMuted)
                Color.sh.lineStrong.frame(width: AppLayout.projectMetadataRule, height: AppLayout.projectDividerHeight)
                Text(model.editedLabel).font(.shSans(AppLayout.projectFileSize)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }.padding(.horizontal, SH.Space.l).frame(height: AppLayout.projectEditorHeaderHeight).background(Color.sh.projectEditorHeader)
            SHHairline()
            if model.fileLoaded {
                InstructionsEditor(text: $model.draft, saved: model.saved ?? "",
                                   accessibilityLabel: "Space file editor", project: true, markdown: model.category == .instructions)
                    .disabled(project.unavailable != nil || model.saving)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SHEmptyState(Text(model.fileLoading ? "Loading file…" : "No space file"),
                             message: model.fileLoading ? "Reading from \(project.host.name)." : "Choose a file or add this resource in the space folder.") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.sh.projectEditorBackground)
            .clipShape(RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius))
            .shBorder(Color.sh.lineStrong, radius: SHCardRowMetrics.settingsCardRadius)
    }

    private var footer: some View {
        HStack(spacing: AppLayout.projectFileGap) {
            Text(model.dirty ? "Unsaved changes" : model.savedNotice)
                .font(.shSans(AppLayout.projectFileSize)).foregroundStyle(Color.sh.settingsMuted).lineLimit(2)
            Spacer(minLength: 0)
            Button { Task { await model.openInEditor() } } label: {
                Text(model.openingEditor ? "Opening…" : "Open in editor").font(.shSans(AppLayout.projectsHostSize, .medium))
                    .padding(.horizontal, SH.Space.l).frame(height: AppLayout.projectEditorButtonHeight)
                    .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
            }.buttonStyle(.plain).disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
            Button { Task { await model.save() } } label: {
                Text(model.saving ? "Saving…" : "Save").font(.shSans(AppLayout.projectsHostSize, .semibold))
                    .foregroundStyle(Color.sh.bgWindow).padding(.horizontal, AppLayout.projectSavePad)
                    .frame(height: AppLayout.projectEditorButtonHeight)
                    .background(Color.sh.lantern, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            }.buttonStyle(.plain)
                .disabled(model.saving || !model.fileLoaded || project.unavailable != nil || model.category == .mcp && model.mcp.problem != nil)
        }.foregroundStyle(Color.sh.textPrimary).frame(height: AppLayout.projectEditorFooterHeight)
    }

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: AppLayout.projectSideGap) {
            if model.category == .instructions {
                readingCard
                hostsCard
                Text("APPEND_SYSTEM.md adds to the system prompt and SYSTEM.md replaces it. Both live in the space's .shepherd or .pi folder.")
                    .font(.shSans(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.settingsMuted)
                    .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
            } else { hostsCard }
        }.padding(.top, AppLayout.projectContextTop).frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProjectContextColumn")
    }

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("WHAT AN AGENT READS HERE").font(.shMono(SHTextStyle.micro.size))
                .tracking(SHTextStyle.micro.size * AppLayout.projectReadingTracking).foregroundStyle(Color.sh.settingsMuted)
            VStack(spacing: 0) {
                ForEach(model.readRows) { row in
                    if row.id != model.readRows.first?.id { Color.sh.projectRowDivider.frame(height: SH.hairline(displayScale)) }
                    HStack(spacing: SH.Space.m) {
                        Circle().fill(row.selected ? Color.sh.running : Color.sh.textTertiary)
                            .frame(width: AppLayout.projectDotSize, height: AppLayout.projectDotSize)
                        Text(row.label).font(.shSans(AppLayout.projectFileSize)).lineLimit(1)
                            .foregroundStyle(row.selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                        Spacer(minLength: 0)
                        Text(row.scope).font(.shMono(SHTextStyle.micro.size)).lineLimit(1)
                            .foregroundStyle(row.selected ? Color.sh.running : Color.sh.settingsMuted)
                    }.padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.s)
                        .frame(minHeight: AppLayout.projectReadRowHeight)
                }
            }.clipShape(RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius))
                .shBorder(Color.sh.projectDivider, radius: SHCardRowMetrics.settingsCardRadius)
            Text("Pi loads every context file from the folder up to the root. A file in a folder applies there and below.")
                .font(.shSans(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.settingsMuted)
                .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostsCard: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Hosts").font(.shSans(AppLayout.projectsHostSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
            Text(hostsDescription).font(.shSans(AppLayout.projectFileSize)).foregroundStyle(Color.sh.textSecondary)
                .lineSpacing(AppLayout.projectSideLineExtra).fixedSize(horizontal: false, vertical: true)
            ForEach(model.peers) { peer in
                HStack(spacing: SH.Space.s) {
                    Circle().fill(peer.tone == .done ? Color.sh.done : InstructionsHostChip.color(peer.tone)).frame(width: AppLayout.projectDotSize, height: AppLayout.projectDotSize)
                    Text(peer.status).font(.shSans(AppLayout.projectFileSize)).foregroundStyle(InstructionsHostChip.color(peer.tone))
                }
            }
        }.padding(.horizontal, AppLayout.projectSavePad).padding(.vertical, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius))
            .shBorder(Color.sh.lineStrong, radius: SHCardRowMetrics.settingsCardRadius)
    }

    private var hostsDescription: String {
        guard let peer = model.peers.first else { return "This is the copy on \(project.host.name). No other host has this space." }
        if peer.status == "In sync" { return "This is the copy on \(project.host.name). \(peer.host) has its own checkout of \(project.project.name), and its \(model.selectedFile?.path ?? "file") matches." }
        return peer.note
    }
}
