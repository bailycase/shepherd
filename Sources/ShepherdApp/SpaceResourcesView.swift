import AppKit
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension ProjectResource.Kind {
    var title: String {
        switch self { case .skill: "Skills"; case .prompt: "Slash commands"; case .agent: "Subagents"; case .extension: "Extensions" }
    }
    var singular: String {
        switch self { case .skill: "skill"; case .prompt: "command"; case .agent: "subagent"; case .extension: "extension" }
    }
    var column: String {
        switch self { case .skill: "SKILL"; case .prompt: "COMMAND"; case .agent: "SUBAGENT"; case .extension: "EXTENSION" }
    }
    var glyph: SHGlyph.Settings {
        switch self { case .skill: .skills; case .prompt: .slashCommands; case .agent: .agents; case .extension: .extensions }
    }
    var addLabel: String { self == .extension ? "Add extension" : "New \(singular)" }
    func subtitle(_ space: String) -> String {
        switch self {
        case .skill: "Space skills, with global skills inherited."
        case .prompt: "Commands available in \(space). Disabled commands cannot run."
        case .agent: "Profiles for this space, plus your global subagents."
        case .extension: "Space integrations. Global extensions stay separate."
        }
    }
}

/// The Resources tab (ProjectResources board and its per-kind boards): one kind's space and
/// global resources with search, scope, status and removal, over `SpaceResourcesModel`'s draft.
struct SpaceResourcesView: View {
    @Bindable var model: SpaceResourcesModel
    let project: ProjectsRow
    /// Opens the parent space (the banner's Open <parent>); nil when it isn't listed.
    var openParent: (() -> Void)? = nil

    private var locked: Bool { project.unavailable != nil || !project.host.supportsResources || model.saving || model.loading || !model.loadedOnce }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            // ProjectChildSkills: only skills inherit from the parent space.
            if model.kind == .skill, let parent = model.parent {
                SpaceInheritanceBanner(title: "Inherited from \(parent.name)", message: SpaceInheritanceBanner.childMessage(project.project.name),
                                       open: openParent.map { ("Open \(parent.name)", $0) }, disabled: model.saving)
            }
            // Departure: the boards draw no kind switcher inside the Resources tab. Subagents are hidden:
            // the runtime loads only Shepherd-owned profiles, so a space's would do nothing.
            SHSegmentedPicker("Resource kind", selection: $model.kind,
                              options: ProjectResource.Kind.allCases.filter { $0 != .agent }.map { ($0, $0.title) })
                .shControlScale(.settings).fixedSize()
            HStack(alignment: .top, spacing: SH.Space.xl) {
                SettingsHeader(title: model.kind.title, explanation: model.kind == .skill && model.parent != nil
                               ? "Inherited resources from \(model.parent!.name) stay read-only. Overrides change only \(project.project.name)."
                               : model.kind.subtitle(project.project.name))
                Spacer(minLength: 0)
                if model.kind == .skill {
                    Button("Add from repo") { model.install = .init() }.buttonStyle(.sh(.secondary, size: .l)).disabled(locked)
                }
                Button { model.create() } label: {
                    Label(model.kind.addLabel, systemImage: "plus")
                }.buttonStyle(.sh(.primary, size: .l)).disabled(locked)
            }
            HStack(spacing: SH.Space.xl) {
                SHSearchField("Search \(model.kind.title.lowercased())", text: $model.query).frame(width: AppLayout.resourceSearchWidth)
                SHSegmentedPicker("Resource scope", selection: $model.scope,
                                  options: [(SpaceResourcesModel.Scope.all, "All"), (.space, "Space"), (.inherited, "Inherited")])
                    .shControlScale(.settings).fixedSize()
                Spacer(minLength: 0)
                Text("\(model.spaceCount) space · \(model.inheritedCount) inherited").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if let warning {
                HStack(spacing: SH.Space.xl) {
                    Text(warning).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    if project.unavailable == nil {
                        Button(model.conflict ? "Reload latest" : "Retry") {
                            if model.conflict { model.reloading = true; model.confirmingDiscard = true }
                            else { model.message = nil; Task { await reload() } }
                        }.buttonStyle(.sh(.secondary)).disabled(model.saving || model.loading)
                    }
                }.padding(SH.Space.l).background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
                    .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
            }
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: SH.Space.xl) {
                        Text(model.kind.column).frame(maxWidth: .infinity, alignment: .leading)
                        Text("FROM").frame(width: AppLayout.resourceFromWidth, alignment: .leading)
                        Text("STATUS").frame(width: AppLayout.resourceStatusWidth, alignment: .leading)
                        Color.clear.frame(width: AppLayout.resourceRemoveWidth, height: 0)
                    }.font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                        .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                        .background(Color.sh.bgSunken).accessibilityHidden(true)
                    SHHairline(color: Color.sh.lineSubtle)
                    if model.rows.isEmpty {
                        empty
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.rows) { row in
                                SpaceResourceRow(model: model, row: row, project: project.project.name, locked: locked, last: row.id == model.rows.last?.id)
                            }
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
                    .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
            }.scrollIndicators(.automatic)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("Space resources")
    }

    private func reload() async {
        // The model keeps its own request; Retry reads the files again without dropping the draft.
        model.message = nil
        await model.reloadKeepingDraft()
    }

    private var warning: String? {
        if project.unavailable != nil { return "This host is offline. Reconnect to edit space resources." }
        if !project.host.supportsResources { return "Update Shepherd on \(project.host.name) to manage space resources." }
        if let message = model.message { return model.loadedOnce ? message : "Could not load space resources. No files have been changed. \(message)" }
        return nil
    }

    private var empty: some View {
        VStack(spacing: SH.Space.m) {
            model.kind.glyph.image.resizable().scaledToFit().frame(width: AppLayout.resourceEmptyGlyph, height: AppLayout.resourceEmptyGlyph)
                .foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            Text(model.loading ? "Loading \(model.kind.title.lowercased())…" : !model.query.isEmpty ? "No matching \(model.kind.title.lowercased())"
                 : model.scope == .space ? "No space \(model.kind.title.lowercased())" : "No \(model.kind.title.lowercased())")
                .font(.sh(.title, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
            Text(!model.query.isEmpty ? "Try another search." : "Add a resource to use it only in \(project.project.name).")
                .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
        }.frame(maxWidth: .infinity, minHeight: AppLayout.resourceEmptyHeight).padding(SH.Space.xxl)
    }
}

/// One resource; its actions go to the model, so a row redraws only when its own value changes.
private struct SpaceResourceRow: View {
    let model: SpaceResourcesModel
    let row: SpaceResourcesModel.Row
    let project: String
    let locked: Bool
    let last: Bool
    @State private var hovered = false

    private func open() { Task { await model.edit(row) } }
    private func toggle(_ on: Bool) { Task { await model.toggle(row, on: on) } }
    private func remove() { Task { await model.askRemove(row) } }

    var body: some View {
        let _ = SHRenderProbe.tick("spaceResources.row")
        let item = row.resource
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.xl) {
                HStack(spacing: SH.Space.l) {
                    item.kind.glyph.image.resizable().scaledToFit().frame(width: AppLayout.resourceGlyph, height: AppLayout.resourceGlyph)
                        .foregroundStyle(Color.sh.textSecondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        if row.local, item.kind != .extension {
                            Button(action: open) { Text(row.displayName).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary) }
                                .buttonStyle(.plain).shFocusRing(radius: SH.Radius.xs, color: .sh.running)
                                .accessibilityLabel("Edit \(item.name)").disabled(locked)
                        } else {
                            Text(row.displayName).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                        }
                        Text(item.description).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                        Text(row.detail).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                    }.lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text(row.inheritedFrom.map { "From \($0)" } ?? (item.global ? "Global" : "This space")).font(.shSans(SHTextStyle.micro.size))
                        .foregroundStyle(row.local ? Color.sh.running : Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.s).padding(.vertical, SH.Space.xxs)
                        .background(row.local ? Color.sh.runningTint : Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                    if row.inheritedFrom != nil {
                        Button("Override here") { Task { await model.overrideInherited(row) } }.buttonStyle(.sh(.ghost)).disabled(locked)
                            .accessibilityLabel("Override \(item.name) in \(project)")
                    } else if let parent = row.overrides {
                        Button("Reset to inherited") { Task { await model.resetToInherited(row) } }.buttonStyle(.sh(.ghost)).disabled(locked)
                            .accessibilityLabel("Reset \(item.name) to \(parent)’s")
                    }
                }.frame(width: AppLayout.resourceFromWidth, alignment: .leading)
                HStack(spacing: SH.Space.m) {
                    Toggle("Enable \(item.name) in \(project)", isOn: Binding(get: { row.enabled }, set: toggle))
                        .toggleStyle(.shSwitch).labelsHidden().disabled(locked || !row.canToggle)
                        .help(row.canToggle ? "" : row.inheritedFrom != nil ? "Update Shepherd on this space’s host to turn off inherited skills." : "Global subagents are turned on or off in Settings ▸ Subagents.")
                    Text(row.enabled ? "Enabled" : "Disabled").font(.sh(.caption))
                        .foregroundStyle(row.enabled ? Color.sh.textSecondary : Color.sh.textTertiary)
                }.frame(width: AppLayout.resourceStatusWidth, alignment: .leading)
                Group {
                    if row.local {
                        Button(action: remove) { Image(systemName: "trash").frame(width: AppLayout.resourceRemoveWidth, height: SH.Height.controlL) }
                            .buttonStyle(.sh(.ghost)).accessibilityLabel("Remove \(item.name) from \(project)").disabled(locked)
                    } else { Color.clear.frame(height: 0) }
                }.frame(width: AppLayout.resourceRemoveWidth)
            }.padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
                .background(hovered ? Color.sh.bgHover : .clear)
                .onHover { hovered = $0 }
            if !last { SHHairline(color: Color.sh.lineSubtle) }
        }.accessibilityElement(children: .contain).accessibilityLabel("\(row.displayName), \(row.inheritedFrom.map { "from \($0)" } ?? (item.global ? "global" : "this space")), \(row.enabled ? "enabled" : "disabled")")
    }
}

/// The Resources tab's footer: save state, Discard changes and Save changes.
struct SpaceResourcesFooter: View {
    @Bindable var model: SpaceResourcesModel
    let project: ProjectsRow

    var body: some View {
        let offline = project.unavailable != nil
        HStack(spacing: SH.Space.l) {
            Text(model.saving ? "Saving…" : model.dirty ? "Unsaved changes" : "Saved · applies to new threads")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            Button("Discard changes") { model.reloading = false; model.confirmingDiscard = true }.buttonStyle(.sh(.ghost, size: .l))
                .disabled(offline || model.saving || !model.dirty)
            Button(model.saving ? "Saving…" : "Save changes") { Task { await model.save() } }.buttonStyle(.sh(.primary, size: .l))
                .disabled(offline || model.saving || model.conflict || !model.dirty)
                .keyboardShortcut("s", modifiers: .command)
        }.padding(.vertical, SH.Space.xl)
            .overlay(alignment: .top) { SHHairline(color: Color.sh.lineSubtle) }
            .padding(.horizontal, AppLayout.settingsWideSides)
            .background(Color.sh.bgWindow)
    }
}

/// A centered dialog over the page (the boards' overlay dialogs).
struct SpaceResourceDialog<Content: View>: View {
    let label: String
    var width: CGFloat = AppLayout.projectCookieConfirmWidth
    var height: CGFloat? = nil
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.sh.scrim.ignoresSafeArea().onTapGesture(perform: close)
            content.frame(width: width, height: height, alignment: .topLeading)
                .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.l))
                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
                .shPopover()
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityLabel(label)
            .onExitCommand(perform: close)
    }
}

/// Every Resources dialog the model asks for: remove, discard or reload, the editor, Add from repo.
struct SpaceResourceDialogs: View {
    @Bindable var projects: ProjectsModel
    let project: ProjectsRow
    private var model: SpaceResourcesModel { projects.resources }

    var body: some View {
        if let row = model.removing {
            SpaceResourceDialog(label: "Remove resource", close: { model.removing = nil }) {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    Text("Remove \(row.resource.name)?").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
                    Text("Removes only this space’s resource. Parent and sibling spaces are unchanged.").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                    Text(row.resource.path).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                    HStack(spacing: SH.Space.m) {
                        Spacer(minLength: 0)
                        Button("Cancel") { model.removing = nil }.buttonStyle(.sh(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                        Button("Remove") { model.confirmRemove() }.buttonStyle(.sh(.danger, size: .l))
                    }
                }.padding(SH.Space.xxl)
            }
        } else if model.confirmingDiscard || projects.pending != nil {
            SpaceResourceDialog(label: "Unsaved space changes", close: cancelLeave) {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    Text("Discard unsaved changes?").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
                    Text("Your changes to \(model.kind.title) have not been saved.").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                    HStack(spacing: SH.Space.m) {
                        Spacer(minLength: 0)
                        Button("Keep editing", action: cancelLeave).buttonStyle(.sh(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                        Button("Discard changes") {
                            Task { if projects.pending != nil { await projects.discard() } else { await model.confirmDiscard() } }
                        }.buttonStyle(.sh(.danger, size: .l)).disabled(model.saving || model.loading)
                    }
                }.padding(SH.Space.xxl)
            }
        } else if model.editor != nil {
            SpaceResourceDialog(label: "Resource editor", width: AppLayout.resourceEditorWidth, height: AppLayout.resourceEditorHeight,
                                close: { model.editor = nil }) {
                SpaceResourceEditorView(model: model, project: project, models: projects.formModels)
            }
        } else if model.install != nil {
            SpaceResourceDialog(label: "Add skills to this space", width: AppLayout.resourceInstallWidth, close: { model.install = nil }) {
                SpaceSkillInstallView(model: model, project: project)
            }
        }
    }

    private func cancelLeave() { model.confirmingDiscard = false; model.reloading = false; projects.pending = nil }
}
