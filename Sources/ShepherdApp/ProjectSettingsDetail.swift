import SwiftUI
import ShepherdProtocol
import ShepherdUI

struct ProjectSettingsDetail: View {
    @Environment(\.displayScale) private var displayScale
    @Bindable var model: ProjectsModel
    let project: ProjectsRow
    @Bindable var cookies: ProjectCookiesModel
    let cookieScope: ProjectCookieScope?
    /// This Mac's hooks, for a local space's Hooks drill-in; nil on a remote host's space (none).
    var hooks: HooksModel? = nil
    var openHooks: () -> Void = {}
    /// Rename… and Remove… for a space Shepherd lists (nil for a folder it only found).
    var rename: (() -> Void)? = nil
    var remove: (() -> Void)? = nil

    /// The drill-ins, in the order the Skills and extensions group lists them.
    private var drills: [(label: String, hint: String, action: ProjectsModel.Pending)] {
        var list: [(String, String, ProjectsModel.Pending)] = [
            ("Resources", count(model.context.resources, "resource"), .category(.skills)),
            ("MCP servers", count(model.context.mcpServers, "server"), .category(.mcp)),
            ("Browser", "Cookies and sites this space’s threads can use", .browser),
        ]
        if hooks != nil { list.append(("Hooks", "Hooks that run in this space", .hooks)) }
        return list
    }

    private func count(_ number: Int, _ noun: String) -> String {
        number == 0 ? "None" : "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private var drillTitle: String {
        if model.showingHooks { return "Hooks" }
        if model.showingBrowser { return "Browser" }
        switch model.category {
        case .pi: return "Settings"
        case .skills: return "Resources"
        case .mcp: return "MCP servers"
        default: return "Instructions"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                header
                if model.overview {
                    overviewPage
                } else if model.showingHooks, let hooks {
                    ScrollView { HooksSpacePage(model: hooks, root: project.project.directory, openSettings: openHooks) }
                } else if model.showingBrowser {
                    ScrollView { ProjectBrowserSettings(model: cookies, project: project, scope: cookieScope) }
                } else if model.category == .mcp {
                    editorColumn
                } else if showsResources {
                    SpaceResourcesView(model: model.resources, project: project,
                                       openParent: model.inheritanceParent == nil ? nil : { Task { await model.openInheritanceParent() } })
                } else if showsForm {
                    SpaceSettingsFormView(model: model, project: project)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppLayout.projectSideGap) {
                            editorColumn.frame(height: AppLayout.projectNarrowEditorHeight)
                            contextColumn
                        }
                    }
                }
                if showsForm && !model.overview { SpaceSettingsFormFooter(model: model, project: project) }
                if showsResources && !model.overview { SpaceResourcesFooter(model: model.resources, project: project) }
            }
            .frame(maxWidth: AppLayout.settingsColumnWidth, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SettingsPageContent")
            .padding(.top, AppLayout.settingsTop)
            .padding(.horizontal, SH.Space.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shControlScale(.settings)
    }

    /// The Settings form draws pi's settings as a form, not a JSON editor; Edit JSON… swaps it for the raw editor.
    private var showsForm: Bool { !model.overview && !model.showingHooks && !model.showingBrowser && model.category == .pi && !model.showingSettingsJSON }
    private var showsResources: Bool { !model.overview && !model.showingHooks && !model.showingBrowser && model.category == .skills }

    // MARK: Header

    /// "‹ Spaces" (or "‹ the space" inside a drill-in), the name in `title` style with the path beside it.
    private var header: some View {
        let busy = model.saving || cookies.clearing
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            Button {
                Task { await model.stepBack() }
            } label: {
                HStack(spacing: SH.Space.xs) {
                    Image(systemName: "chevron.left").font(.system(size: SHSettingsControlMetrics.popupChevronSize + 2, weight: .semibold))
                    Text(model.overview ? "Spaces" : project.project.name).font(.shSans(SHSettingsControlMetrics.segmentTextSize))
                }
                .foregroundStyle(Color.sh.textSecondary)
                .frame(height: AppLayout.settingsGroupHeaderHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shFocusRing(radius: SH.Radius.xs, color: .sh.running)
            .accessibilityLabel(model.overview ? "Back to Spaces" : "Back to \(project.project.name)")
            .disabled(busy)
            .padding(.top, -AppLayout.settingsUpLinkLift)
            if model.overview, let parent = model.rows.first(where: { $0.host.id == project.host.id && $0.project.directory == project.project.parent }) {
                Button { Task { await model.navigate(.close); if model.selected == nil { await model.open(parent) } } } label: {
                    Text("Child of \(parent.project.name)").font(.sh(.caption)).foregroundStyle(Color.sh.running)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open parent space \(parent.project.name)")
                .disabled(busy)
            }
            SettingsHeader(title: model.overview ? project.project.name : drillTitle,
                           subtitle: model.overview ? project.project.displayPath : project.project.name)
        }
        // The board pulls the first group up under the title.
        .padding(.bottom, -SH.Space.m)
        .disabled(cookies.clearing)
    }

    // MARK: Overview

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                instructionsCard
                SettingsGroup(title: "Pi settings") {
                    SettingsDrillRow(title: "Settings", subtitle: ".shepherd/settings.json",
                                     accessibilityName: "Space category Settings") {
                        Task { await model.navigate(.category(.pi)) }
                    }
                }
                SettingsGroup(title: "Skills and extensions") {
                    ForEach(drills, id: \.label) { drill in
                        SettingsDrillRow(title: drill.label, subtitle: drill.hint, accessibilityName: "Space category \(drill.label)") {
                            Task { await model.navigate(drill.action) }
                        }
                    }
                }
                if rename != nil || remove != nil {
                    SettingsGroup(title: "") {
                        if let rename {
                            SettingsRow(title: "Rename space") { Button("Rename…", action: rename).buttonStyle(.sh(.secondary, size: .s)) }
                        }
                        if let remove {
                            SettingsRow(title: "Remove space", subtitle: "Files stay on disk") {
                                Button("Remove…", action: remove).buttonStyle(.sh(.danger, size: .s))
                            }
                        }
                    }
                }
            }
            .padding(.bottom, SH.Space.xxxl)
        }
        .scrollIndicators(.hidden)
    }

    /// The space's instruction files in the editor card: the file's name (a menu when there are several), "● edited",
    /// Open in editor and Save.
    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            SHSectionHeader("Instructions", style: .settings) {
                Text(model.tokenText).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xs)
            if let error = model.fileError {
                Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
            }
            if model.pending != nil, model.category == .instructions {
                HStack(spacing: SH.Space.m) {
                    Text("Discard unsaved changes?").font(.sh(.ui))
                    Spacer()
                    Button("Keep editing") { model.pending = nil }.buttonStyle(.sh(.secondary, size: .s))
                    Button("Discard") { Task { await model.discard() } }.buttonStyle(.sh(.danger, size: .s))
                }
            }
            SettingsEditorCard(name: model.selectedFile?.path ?? "AGENTS.md", edited: model.dirty, openIn: $model.draft, fixedHeight: AppLayout.settingsEditorHeight) {
                if model.selectedFiles.count > 1 {
                    SHPopupMenu("Files", minWidth: 0) {
                        ForEach(model.selectedFiles) { file in
                            Button(file.path) { Task { await model.navigate(.file(file)) } }
                        }
                    }
                    .disabled(model.saving || model.fileLoading)
                    .accessibilityLabel("Space file")
                }
                Button(model.openingEditor ? "Opening…" : "Open in editor") { Task { await model.openInEditor() } }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
                Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
                    .buttonStyle(.sh(.primary, size: .s))
                    .disabled(model.saving || !model.fileLoaded || project.unavailable != nil || !model.dirty)
            } content: {
                if model.fileLoaded {
                    InstructionsEditor(text: $model.draft, saved: model.saved ?? "", accessibilityLabel: "Space file editor", markdown: true)
                        .disabled(project.unavailable != nil || model.saving)
                } else {
                    SHEmptyState(Text(model.fileLoading ? "Loading file…" : "No space file"),
                                 message: model.fileLoading ? "Reading from \(project.host.name)." : "Add AGENTS.md in the space folder.") {}
                }
            }
            Text(model.dirty ? "Unsaved changes" : model.savedNotice).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, SH.Space.xs)
        }
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
                        if model.category == .pi {
                            Button("Back to form") { model.showingSettingsJSON = false }.buttonStyle(.sh(.secondary)).disabled(model.saving)
                        }
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
                if model.fileLoaded {
                    SettingsOpenIn(text: $model.draft, name: (model.selectedFile?.path as NSString?)?.lastPathComponent ?? "AGENTS.md")
                        .id(model.selectedFile?.path)
                }
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
