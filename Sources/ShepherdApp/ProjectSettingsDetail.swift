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

    /// "‹ Spaces", or "‹ the space" inside a drill-in.
    private var up: (label: String, action: () -> Void) {
        (model.overview ? "Spaces" : project.project.name, { if !(model.saving || cookies.clearing) { Task { await model.stepBack() } } })
    }

    var body: some View {
        Group {
            if showsForm {
                SpaceSettingsFormView(model: model, project: project, up: up)
            } else {
                if model.category == .mcp, !model.overview, !model.showingHooks, !model.showingBrowser, model.fileLoaded {
                    ProjectMCPSettings(model: model, up: up, files: AnyView(filesRow), notice: AnyView(editorNotice), bar: AnyView(footer))
                        .id(model.selectedFile?.path)
                } else {
                SpacePageFrame(scrolls: scrolls) {
                    header
                    if model.overview {
                        overviewPage
                    } else if model.showingHooks, let hooks {
                        HooksSpacePage(model: hooks, root: project.project.directory, openSettings: openHooks)
                    } else if model.showingBrowser {
                        ProjectBrowserSettings(model: cookies, project: project, scope: cookieScope)
                    } else if model.category == .mcp {
                        editorColumn
                    } else if showsResources {
                        SpaceResourcesView(model: model.resources, project: project,
                                           openParent: model.inheritanceParent == nil ? nil : { Task { await model.openInheritanceParent() } })
                    } else {
                        editorColumn
                        contextColumn
                    }
                } bar: {
                    if showsResources && !model.overview { SpaceResourcesFooter(model: model.resources, project: project) }
                    else if showsEditor { footer }
                }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsPageContent")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shControlScale(.settings)
    }

    /// The Settings form draws pi's settings as a form, not a JSON editor; Edit JSON… swaps it for the raw editor.
    private var showsForm: Bool { !model.overview && !model.showingHooks && !model.showingBrowser && model.category == .pi && !model.showingSettingsJSON }
    private var showsResources: Bool { !model.overview && !model.showingHooks && !model.showingBrowser && model.category == .skills }
    /// The editors fill the page; every other page scrolls.
    private var scrolls: Bool { true }
    /// The raw-file pages: Edit JSON…, and what an MCP file shows before it loads.
    private var showsEditor: Bool { !model.overview && !model.showingHooks && !model.showingBrowser && !showsResources }

    // MARK: Header

    /// "‹ Spaces" (or "‹ the space" inside a drill-in), the name in the page title with the path beside it.
    private var header: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SpacePageHeader(up: up, title: model.overview ? project.project.name : drillTitle,
                            subtitle: model.overview ? project.project.displayPath : project.project.name,
                            disabled: model.saving || cookies.clearing) {
                if !model.overview, showsEditor, model.category == .pi {
                    Button("Back to form") { model.showingSettingsJSON = false }.buttonStyle(SpaceLinkStyle()).disabled(model.saving)
                }
            }
            if model.overview, let parent = model.rows.first(where: { $0.host.id == project.host.id && $0.project.directory == project.project.parent }) {
                Button { Task { await model.navigate(.close); if model.selected == nil { await model.open(parent) } } } label: {
                    Text("Child of \(parent.project.name)").font(.sh(.caption)).foregroundStyle(Color.sh.running)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open parent space \(parent.project.name)")
                .disabled(model.saving || cookies.clearing)
                .padding(.horizontal, SH.Space.xs)
            }
        }
        .disabled(cookies.clearing)
    }

    // MARK: Overview

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                instructionsCard
                SettingsGroup(title: "Pi settings") {
                    SettingsDrillRow(title: "Settings", subtitle: ".shepherd/settings.json", mono: true,
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

    /// The files the page edits (`gspc-files`): each a tab in mono, the chosen one filled, and where it lives at the right.
    private var filesRow: some View {
        HStack(spacing: SH.Space.xs) {
            ForEach(model.selectedFiles) { file in
                let chosen = file.path == model.selectedFile?.path
                Button { Task { await model.navigate(.file(file)) } } label: {
                    Text(file.path).font(.shMono(SHTextStyle.mono.size, chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Color.sh.textPrimary : file.exists ? Color.sh.textSecondary : Color.sh.textTertiary)
                        .padding(.horizontal, SH.Space.m).frame(height: AppLayout.spaceKindHeight)
                        .background(chosen ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(file.path).disabled(model.saving || model.fileLoading)
            }
            if let file = model.selectedFile {
                Spacer(minLength: SH.Space.l)
                Text(project.project.displayPath + "/" + file.path).font(.shMono(SHTextStyle.mono.size)).foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }.padding(.horizontal, SH.Space.xs).padding(.top, -SH.Space.m)
    }

    /// What sits over a raw file: why it can't be shown, and the prompt before unsaved changes are dropped.
    @ViewBuilder private var editorNotice: some View {
        if let error = model.fileError {
            SpacePageStatus(text: error, failed: true)
        }
        if model.pending != nil {
            HStack(spacing: SH.Space.m) {
                Text("Discard unsaved changes?").font(.sh(.ui))
                Spacer(minLength: 0)
                Button("Keep editing") { model.pending = nil }.buttonStyle(SpaceLinkStyle())
                Button("Discard") { Task { await model.discard() } }.buttonStyle(SpaceLinkStyle(tone: .danger))
            }.padding(.horizontal, SH.Space.xs)
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: AppLayout.spacePageGap) {
            filesRow
            editorNotice
            if model.category == .mcp, model.fileLoaded {
                ProjectMCPSettings(model: model).id(model.selectedFile?.path)
            } else { editor }
        }.frame(maxWidth: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProjectEditorColumn")
    }

    /// The raw file (`gspc-card` with `gspc-edh`): its name, Open in, the size and when it was edited, then the text.
    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppLayout.spaceControlGap) {
                Text((model.selectedFile?.path as NSString?)?.lastPathComponent ?? (model.category == .instructions ? "AGENTS.md" : "file"))
                    .font(.shMono(SHTextStyle.mono.size, .medium)).foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: 0)
                if model.fileLoaded {
                    SettingsOpenIn(text: $model.draft, name: (model.selectedFile?.path as NSString?)?.lastPathComponent ?? "AGENTS.md")
                        .id(model.selectedFile?.path)
                }
                Text(model.tokenText).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                Text(model.dirty ? "Unsaved changes" : model.editedLabel).font(.sh(.caption))
                    .foregroundStyle(model.dirty ? Color.sh.lanternText : Color.sh.textTertiary).lineLimit(1)
            }.padding(.horizontal, AppLayout.spaceRowSides).frame(height: AppLayout.spaceEditorHeaderHeight)
            SHHairline()
            if model.fileLoaded {
                InstructionsEditor(text: $model.draft, saved: model.saved ?? "",
                                   accessibilityLabel: "Space file editor", project: true, markdown: model.category == .instructions)
                    .disabled(project.unavailable != nil || model.saving)
                    .frame(maxWidth: .infinity, minHeight: editorHeight, maxHeight: editorHeight)
            } else {
                SHEmptyState(Text(model.fileLoading ? "Loading file…" : "No space file"),
                             message: model.fileLoading ? "Reading from \(project.host.name)." : "Choose a file or add this resource in the space folder.") {}
                    .frame(maxWidth: .infinity, minHeight: AppLayout.spaceEditorMinHeight)
            }
        }.shCard(radius: SH.Radius.l, lift: true)
    }

    /// The editor grows with the file to a ceiling, then scrolls inside itself.
    private var editorHeight: CGFloat {
        let lines = CGFloat(model.draft.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(AppLayout.settingsEditorHeight, max(AppLayout.spaceEditorMinHeight, lines * AppLayout.projectEditorLineHeight + 2 * AppLayout.projectEditorInset))
    }

    private var footer: some View {
        SpacePageBar(status: model.dirty ? "Unsaved changes" : "", tone: .warn, note: model.dirty ? "" : model.savedNotice) {
            Button(model.openingEditor ? "Opening…" : "Open in editor") { Task { await model.openInEditor() } }.buttonStyle(SpaceBarStyle())
                .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
            Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }.buttonStyle(SpaceBarStyle(kind: .primary))
                .disabled(model.saving || !model.fileLoaded || project.unavailable != nil || !model.dirty || model.category == .mcp && model.mcp.problem != nil)
        }
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
        }.frame(maxWidth: .infinity, alignment: .top)
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

    /// Where else the file lives (`Hosts`): each host's state over what it means for this copy.
    private var hostsCard: some View {
        SpaceSection("Hosts") {
            if model.peers.isEmpty {
                SpaceRow(title: "Only on \(project.host.name)", hint: hostsDescription) { EmptyView() }
            }
            ForEach(model.peers) { peer in
                SpaceRow(title: peer.status, hint: hostsDescription) { EmptyView() }
                    .accessibilityLabel("\(peer.host), \(peer.status)")
            }
        }
    }

    private var hostsDescription: String {
        guard let peer = model.peers.first else { return "This is the copy on \(project.host.name). No other host has this space." }
        if peer.status == "In sync" { return "This is the copy on \(project.host.name). \(peer.host) has its own checkout of \(project.project.name), and its \(model.selectedFile?.path ?? "file") matches." }
        return peer.note
    }
}
