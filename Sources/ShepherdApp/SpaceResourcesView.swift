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
        VStack(alignment: .leading, spacing: AppLayout.spacePageGap) {
            SpaceKindTabs(label: "Resource kind", selection: $model.kind, options: ProjectResource.Kind.allCases.map { ($0, $0.title) })
            // ProjectChildSkills: skills, slash commands and extensions inherit from the parent space.
            if model.inheritedKinds.contains(model.kind), let parent = model.parent {
                SpaceInheritanceBanner(title: "Inherited from \(parent.name)", message: SpaceInheritanceBanner.childMessage(project.project.name),
                                       open: openParent.map { ("Open \(parent.name)", $0) }, disabled: model.saving)
            }
            SpaceSection(title: model.kind.title, note: note, footnote: model.kind == .agent ? "Global subagents are turned on or off in Settings • Agents • Profiles." : nil, lazy: true) {
                if model.kind == .skill {
                    Button("Add from repo") { model.install = .init() }.buttonStyle(SpaceLinkStyle()).disabled(locked)
                }
                Button(model.kind.addLabel) { model.create() }.buttonStyle(SpaceLinkStyle()).disabled(locked)
            } content: {
                if let warning {
                    HStack(spacing: AppLayout.spaceControlGap) {
                        Text(warning).font(.sh(.ui)).foregroundStyle(Color.sh.failed).frame(maxWidth: .infinity, alignment: .leading)
                        if project.unavailable == nil {
                            Button(model.conflict ? "Reload latest" : "Retry") {
                                if model.conflict { model.reloading = true; model.confirmingDiscard = true }
                                else { model.message = nil; Task { await reload() } }
                            }.buttonStyle(SpaceLinkStyle(tone: .strong)).disabled(model.saving || model.loading)
                        }
                    }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.l)
                        .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
                }
                HStack(spacing: SH.Space.l) {
                    SpaceSearchField(prompt: "Search \(model.kind.title.lowercased())", text: $model.query)
                    SpaceFilterTabs(label: "Resource scope", selection: $model.scope,
                                    options: [(SpaceResourcesModel.Scope.all, "All"), (.space, "Space"), (.inherited, "Inherited")])
                    Spacer(minLength: 0)
                    Text("\(model.spaceCount) space · \(model.inheritedCount) inherited").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceFilterHeight)
                if model.rows.isEmpty {
                    empty
                } else {
                    ForEach(model.rows) { row in
                        SpaceResourceRow(model: model, row: row, project: project.project.name, locked: locked)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("Space resources")
    }

    private var note: String {
        model.inheritedKinds.contains(model.kind) && model.parent != nil
            ? "Inherited resources from \(model.parent!.name) stay read-only. Overrides change only \(project.project.name)."
            : model.kind.subtitle(project.project.name)
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
        SpaceEmpty(model.loading ? "Loading \(model.kind.title.lowercased())…" : !model.query.isEmpty ? "No matching \(model.kind.title.lowercased())"
                   : model.scope == .space ? "No space \(model.kind.title.lowercased())" : "No \(model.kind.title.lowercased())",
                   message: !model.query.isEmpty ? "Try another search." : "Add a resource to use it only in \(project.project.name).")
    }
}

/// One resource; its actions go to the model, so a row redraws only when its own value changes.
private struct SpaceResourceRow: View {
    let model: SpaceResourcesModel
    let row: SpaceResourcesModel.Row
    let project: String
    let locked: Bool

    private func open() { Task { await model.edit(row) } }
    private func toggle(_ on: Bool) { Task { await model.toggle(row, on: on) } }
    private func remove() { Task { await model.askRemove(row) } }

    var body: some View {
        let _ = SHRenderProbe.tick("spaceResources.row")
        let item = row.resource
        HStack(spacing: AppLayout.spaceRowGap) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                if row.local, item.kind != .extension {
                    Button(action: open) { name }
                        .buttonStyle(.plain).shFocusRing(radius: SH.Radius.xs, color: .sh.running)
                        .accessibilityLabel("Edit \(item.name)").disabled(locked)
                } else {
                    name
                }
                Text(item.description).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                Text(row.detail).font(.shMono(AppLayout.spaceDetailSize)).foregroundStyle(Color.sh.textTertiary)
            }.lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: AppLayout.spaceControlGap) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.inheritedFrom.map { "From \($0)" } ?? (item.global ? "Global" : "This space")).font(.sh(.ui))
                        .foregroundStyle(row.local ? Color.sh.textPrimary : Color.sh.textSecondary)
                    if row.inheritedFrom != nil {
                        Button("Override here") { Task { await model.overrideInherited(row) } }
                            .buttonStyle(SpaceLinkStyle(tone: .strong, caption: true)).disabled(locked)
                            .accessibilityLabel("Override \(item.name) in \(project)")
                    } else if let parent = row.overrides {
                        Button("Reset to inherited") { Task { await model.resetToInherited(row) } }
                            .buttonStyle(SpaceLinkStyle(tone: .strong, caption: true)).disabled(locked)
                            .accessibilityLabel("Reset \(item.name) to \(parent)’s")
                    }
                }.frame(width: AppLayout.spaceFromWidth, alignment: .leading)
                Toggle("Enable \(item.name) in \(project)", isOn: Binding(get: { row.enabled }, set: toggle))
                    .toggleStyle(.shSwitch).labelsHidden().disabled(locked || !row.canToggle)
                    .help(row.canToggle ? "" : row.inheritedFrom != nil ? "Update Shepherd on this space’s host to turn off inherited \(model.kind.title.lowercased())." : "Global subagents are turned on or off in Settings ▸ Subagents.")
                Group {
                    if row.local {
                        Button("Remove", action: remove).buttonStyle(SpaceLinkStyle())
                            .accessibilityLabel("Remove \(item.name) from \(project)").disabled(locked)
                    } else { Color.clear.frame(height: 0) }
                }.frame(width: AppLayout.spaceRemoveWidth, alignment: .trailing)
            }.fixedSize()
        }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceRowMinHeight)
            .accessibilityElement(children: .contain).accessibilityLabel("\(row.displayName), \(row.inheritedFrom.map { "from \($0)" } ?? (item.global ? "global" : "this space")), \(row.enabled ? "enabled" : "disabled")")
    }

    private var name: some View {
        Text(row.displayName).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
    }
}

/// The Resources tab's bar: save state, Discard changes and Save changes.
struct SpaceResourcesFooter: View {
    @Bindable var model: SpaceResourcesModel
    let project: ProjectsRow

    var body: some View {
        let offline = project.unavailable != nil
        SpacePageBar(status: model.saving ? "Saving…" : model.dirty ? "Unsaved changes" : "", tone: .warn,
                     note: model.dirty || model.saving ? "" : "Saved · applies to new threads") {
            Button("Discard changes") { model.reloading = false; model.confirmingDiscard = true }.buttonStyle(SpaceBarStyle())
                .disabled(offline || model.saving || !model.dirty)
            Button(model.saving ? "Saving…" : "Save changes") { Task { await model.save() } }.buttonStyle(SpaceBarStyle(kind: .primary))
                .disabled(offline || model.saving || model.conflict || !model.dirty)
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}

/// A centered dialog over the page (the boards' overlay dialogs): a card at radius 16 on a scrim.
struct SpaceResourceDialog<Content: View>: View {
    let label: String
    var width: CGFloat = AppLayout.spaceSheetWidth
    var height: CGFloat? = nil
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.sh.scrim.ignoresSafeArea().onTapGesture(perform: close)
            content.frame(width: width, height: height, alignment: .topLeading)
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.xxl))
                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.xxl))
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xxl)
                .shPopover()
                .padding(.top, AppLayout.spaceDialogTop)
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
                SpaceSheet(title: "Remove \(row.resource.name)?", caption: AnyView(VStack(alignment: .leading, spacing: SH.Space.xs) {
                    SpaceSheetCaption(text: "Removes only this space’s resource. Parent and sibling spaces are unchanged.")
                    SpaceSheetCaption(text: row.resource.path, mono: true)
                }), width: AppLayout.spaceConfirmWidth) { EmptyView() } actions: {
                    Button("Cancel") { model.removing = nil }.buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
                    Button("Remove") { model.confirmRemove() }.buttonStyle(SpaceBarStyle(kind: .danger))
                }
            }
        } else if model.confirmingDiscard || projects.pending != nil {
            SpaceResourceDialog(label: "Unsaved space changes", close: cancelLeave) {
                SpaceSheet(title: "Discard unsaved changes?",
                           caption: AnyView(SpaceSheetCaption(text: "Your changes to \(model.kind.title) have not been saved.")), width: AppLayout.spaceConfirmWidth) { EmptyView() } actions: {
                    Button("Keep editing", action: cancelLeave).buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
                    Button("Discard changes") {
                        Task { if projects.pending != nil { await projects.discard() } else { await model.confirmDiscard() } }
                    }.buttonStyle(SpaceBarStyle(kind: .danger)).disabled(model.saving || model.loading)
                }
            }
        } else if model.editor != nil {
            SpaceResourceDialog(label: "Resource editor", width: model.editor?.kind == .agent ? AppLayout.spaceAgentSheetWidth : AppLayout.spaceEditorSheetWidth,
                                close: { model.editor = nil }) {
                SpaceResourceEditorView(model: model, project: project, models: projects.formModels)
            }
        } else if model.install != nil {
            SpaceResourceDialog(label: "Add skills to this space", width: AppLayout.spaceInstallSheetWidth, close: { model.install = nil }) {
                SpaceSkillInstallView(model: model, project: project)
            }
        }
    }

    private func cancelLeave() { model.confirmingDiscard = false; model.reloading = false; projects.pending = nil }
}
