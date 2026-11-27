import SwiftUI
import ShepherdProtocol
import ShepherdUI

/// The space Settings tab (ProjectSettings board): pi's settings as a form over the space's
/// `settings.json`, each row with where its value comes from and a reset to the inherited value.
struct SpaceSettingsFormView: View {
    @Bindable var model: ProjectsModel
    let project: ProjectsRow
    /// The line back to the space.
    let up: (label: String, action: () -> Void)

    private var locked: Bool { !model.formEditable }

    var body: some View {
        SpacePageFrame {
            SpacePageHeader(up: up, title: "Settings", subtitle: project.project.name, intro: scopeCopy, disabled: model.saving) {
                Text(model.selectedFile?.path ?? ".pi/settings.json").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                // The form shows only its keys; every other key is edited as JSON, over the same draft.
                Button("Edit JSON…") { model.showingSettingsJSON = true }.buttonStyle(SpaceLinkStyle())
                    .disabled(!model.fileLoaded || model.saving)
                Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(SpaceLinkStyle())
                    .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
            }
            SpacePageStatus(text: statusText, alert: statusAlert)
            if let parent = model.context.parentName { inheritance(parent) }
            if model.fileLoaded, model.formSettings == nil {
                SHEmptyState(Text("This settings file isn’t a JSON object"),
                             message: "Fix \(model.selectedFile?.path ?? "settings.json") in an editor, then come back. The form won’t overwrite it.") {
                    Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(.sh(.secondary))
                        .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil)
                }.frame(maxWidth: .infinity)
            }
            parentSection
            ForEach(model.formGroups) { group in section(group) }
            if model.formSettings != nil { codemodeSection }
        } bar: {
            SpaceSettingsFormFooter(model: model, project: project)
        }.accessibilityElement(children: .contain).accessibilityLabel("Space settings form")
    }

    private var scopeCopy: String {
        if let parent = model.context.parentName { return "Only this space. Unset values follow \(parent), then global defaults." }
        if model.hasInheritingChildren { return "These defaults also apply to child spaces without a local override." }
        return "Only this space. Unset values follow your global defaults."
    }

    /// ProjectChildSettings' banner: where unset values come from, and a way to the parent.
    private func inheritance(_ parent: String) -> some View {
        let row = model.rows.first(where: { $0.host.id == project.host.id && $0.project.name == parent && $0.id != project.id })
        return SpaceInheritanceBanner(title: "Inherited from \(parent)", message: SpaceInheritanceBanner.childMessage(project.project.name),
                                      open: row.map { row in ("Open \(parent)", { Task { await model.navigate(.close); if model.selected == nil { await model.open(row) } } }) },
                                      disabled: model.saving)
    }

    private var statusText: String {
        if project.unavailable != nil { return "Host offline. Reconnect to edit or save." }
        if model.conflict { return "Space settings changed elsewhere. Reload latest before saving." }
        if let error = model.fileError { return model.fileLoaded ? "Save failed. Your changes are still here." : error }
        if model.notice != nil, !model.dirty { return "Space settings saved." }
        return "Global defaults remain unchanged. Reset removes only the space override."
    }

    private var statusAlert: Bool { project.unavailable != nil || model.conflict || model.fileError != nil }

    private func section(_ group: SpaceSettingsForm.Group) -> some View {
        SpaceSection(group.title, note: group.note) {
            ForEach(group.rows) { row in
                if group.tools && row.key == "defaultTools" {
                    VStack(spacing: 0) { rowView(row); tools }
                } else {
                    rowView(row)
                }
            }
        }
    }

    private func rowView(_ row: SpaceSettingsForm.Row) -> some View {
        SpaceRow(title: row.label, hint: row.description, source: row.source,
                 reset: row.overridden ? ("Reset to \(row.resetTo)", "Reset \(row.label) to \(row.resetTo)", { model.resetForm(row) }, !locked) : nil,
                 problem: row.error) {
            control(row).disabled(locked)
        }
    }

    @ViewBuilder private func control(_ row: SpaceSettingsForm.Row) -> some View {
        switch row.control {
        case .dropdown(let options):
            SpaceMenu(label: row.label, value: options.first { $0.value == row.value }?.label ?? row.value) {
                ForEach(options, id: \.self) { option in Button(option.label) { model.setForm(row, option.value) } }
            }
        case .segments(let options):
            SHSegmentedPicker(row.label, selection: Binding(get: { row.value }, set: { model.setForm(row, $0) }),
                              options: options.map { ($0.value, $0.label) })
                .shControlScale(.settings)
        case .field, .number:
            SpaceField(label: row.label, prompt: row.placeholder, text: Binding(get: { row.value }, set: { model.setForm(row, $0) }),
                       width: row.control == .field ? AppLayout.spaceWideFieldWidth : AppLayout.spaceFieldWidth, invalid: row.error != nil)
        case .stepper:
            SpaceStepper(label: row.label, value: Binding(get: { row.effective }, set: { model.setForm(row, String($0)) }), range: 0...AppLayout.spaceFormStepperMax)
        }
    }

    /// The space's parent space, as Add space sets it. It saves at once: it is Shepherd's record,
    /// not a line of the settings file this form drafts.
    private var parentSection: some View {
        let problem = model.parentProblem
        let note = problem ?? "Lists this space under another on \(project.host.name). A folder inside the parent’s also inherits its settings and resources. No files move."
        return SpaceSection("Organization", note: "Where this space sits in the Spaces list.") {
            SpaceRow(title: "Parent space", hint: note, problem: model.parentError) {
                SpaceMenu(label: "Parent space", value: model.parentSpaceName ?? "None · root space") {
                    Button("None · root space") { Task { await model.setParent(nil) } }
                    ForEach(model.parentChoices) { parent in Button(parent.name) { Task { await model.setParent(parent.id) } } }
                }.disabled(problem != nil || model.settingParent || model.saving)
            }
        }
    }

    private var tools: some View {
        let follows = model.formSettings?["defaultTools"] == nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppLayout.spaceToolsGap) {
                ForEach(SpaceSettingsForm.tools, id: \.self) { tool in
                    Toggle(isOn: Binding(get: { model.formTools.contains(tool) }, set: { model.toggleFormTool(tool, on: $0) })) {
                        Text(tool).font(.sh(.ui).monospaced()).foregroundStyle(Color.sh.textPrimary)
                    }.toggleStyle(.shCheckbox)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, AppLayout.spaceRowSides).padding(.top, SH.Space.l - SH.Space.xxs).padding(.bottom, SH.Space.xs)
                .disabled(locked || follows).accessibilityElement(children: .contain).accessibilityLabel("Built-in tools")
            Text(follows ? "Inherited tool selection. Switch to Space selection to change tools."
                         : "Explicit space selection. Unchecked tools are unavailable; an empty selection enables none.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, AppLayout.spaceRowSides).padding(.bottom, SH.Space.l)
        }
    }

    /// Codemode, kept from the editor this form replaces: the board has no row for it.
    private var codemodeSection: some View {
        SpaceSection("Codemode", note: "Overrides this host’s global setting for this space.",
                     footnote: model.formGroups.isEmpty ? nil : "Space defaults apply to new threads.") {
            SpaceRow(title: "Codemode", hint: model.codemodeProblem ?? "Lets the agent call tools from scripts.",
                     problem: nil) {
                SHSegmentedPicker("Space codemode", selection: $model.projectCodemode,
                                  options: [(ProjectsModel.CodemodeChoice.inherit, "Follow global"), (.on, "On"), (.off, "Off")])
                    .shControlScale(.settings)
                    .disabled(locked || model.codemodeProblem != nil)
            }
        }
    }
}

/// The form's bar, across the whole page: save state, what the save applies to, Discard and Save changes.
struct SpaceSettingsFormFooter: View {
    @Bindable var model: ProjectsModel
    let project: ProjectsRow

    var body: some View {
        let offline = project.unavailable != nil
        SpacePageBar(status: badge, tone: tone, note: note) {
            if model.conflict {
                Button("Reload latest") { model.pending = .reload }.buttonStyle(SpaceBarStyle(kind: .strong)).disabled(offline || model.saving)
            }
            Button("Discard") { model.discardForm() }.buttonStyle(SpaceBarStyle())
                .disabled(offline || model.saving || !model.dirty && !model.conflict)
            Button(model.saving ? "Saving…" : "Save changes") { Task { await model.save() } }.buttonStyle(SpaceBarStyle(kind: .primary))
                .disabled(offline || model.saving || model.conflict || !model.dirty || model.formInvalid || model.formSettings == nil)
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var note: String {
        model.formInvalid ? "Fix invalid values before saving." : model.conflict ? "Saving is blocked. Existing values will not be overwritten."
            : model.hasInheritingChildren ? "Applies to new threads in this space and inheriting child spaces." : "Applies to new threads in this space."
    }

    private var tone: SpaceBarTone {
        if model.conflict { return .warn }
        if project.unavailable != nil || model.fileError != nil, model.fileLoaded { return .bad }
        return model.saving || model.dirty ? .warn : .plain
    }

    private var badge: String {
        if model.saving { return "Saving…" }
        if project.unavailable != nil { return "Offline" }
        if model.conflict { return "Conflict" }
        if model.fileError != nil, model.fileLoaded { return "Save failed" }
        return model.dirty ? "Unsaved changes" : "Saved"
    }
}

/// Leaving the Settings tab with unsaved changes, or Reload latest after a conflict, asks first.
struct SpaceSettingsLeaveDialog: View {
    @Bindable var model: ProjectsModel

    var body: some View {
        let reload = model.pending == .reload
        ZStack {
            Color.sh.scrim.ignoresSafeArea().onTapGesture { model.pending = nil }
            SpaceSheet(title: reload ? "Reload latest space settings?" : "Discard changes and leave?",
                       caption: AnyView(SpaceSheetCaption(text: reload ? "Your local edits will be discarded only after the latest values load. Nothing will be overwritten."
                                                                       : "Unsaved space changes will be discarded. Global defaults will not change.")),
                       width: AppLayout.spaceConfirmWidth) { EmptyView() } actions: {
                Button("Stay") { model.pending = nil }.buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
                Button(reload ? "Discard and reload" : "Discard and leave") { Task { await model.discard() } }
                    .buttonStyle(SpaceBarStyle(kind: .danger)).disabled(model.saving)
            }
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.xxl))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xxl)
            .shPopover()
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
            .accessibilityLabel(reload ? "Confirm reload" : "Confirm leaving")
    }
}

/// The boards' inheritance banner (ProjectChildSettings, ProjectChildMCP, ProjectChildSkills,
/// ProjectParentMCP): where a child's values come from, with a way to the parent, or a parent's
/// note that its child spaces share them.
struct SpaceInheritanceBanner: View {
    let title: String
    let message: String
    var open: (label: String, action: () -> Void)? = nil
    var disabled = false

    static func childMessage(_ space: String) -> String { "Local overrides win. Reset removes only \(space)’s override." }

    var body: some View {
        HStack(spacing: AppLayout.spaceControlGap) {
            SHGlyph.Settings.worktrees.image.foregroundStyle(Color.sh.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                Text(message).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            }
            Spacer(minLength: 0)
            if let open {
                Button(open.label, action: open.action).buttonStyle(SpaceLinkStyle(tone: .strong)).disabled(disabled)
            }
        }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m + SH.Space.xxs)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: AppLayout.spaceBannerRadius))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
