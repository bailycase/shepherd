import SwiftUI
import ShepherdProtocol
import ShepherdUI

/// The space Settings tab (ProjectSettings board): pi's settings as a form over the space's
/// `settings.json`, each row with where its value comes from and a reset to the inherited value.
struct SpaceSettingsFormView: View {
    @Bindable var model: ProjectsModel
    let project: ProjectsRow

    private var locked: Bool { !model.formEditable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    Text("Space defaults").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(scopeCopy).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: SH.Space.m) {
                    Text(model.selectedFile?.path ?? ".pi/settings.json").font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                    // The form shows only its keys; every other key is edited as JSON, over the same draft.
                    Button("Edit JSON…") { model.showingSettingsJSON = true }.buttonStyle(.sh(.secondary))
                        .disabled(!model.fileLoaded || model.saving)
                    Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(.sh(.secondary))
                        .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil || model.openingEditor)
                }.padding(.top, SH.Space.l)
            }.padding(.top, SH.Space.xxl - AppLayout.projectDetailGap).padding(.bottom, SH.Space.xl)
            if let parent = model.context.parentName { inheritance(parent) }
            Text(statusText).font(.sh(.caption)).foregroundStyle(statusAlert ? Color.sh.lanternText : Color.sh.textSecondary)
                .padding(.bottom, SH.Space.l).accessibilityAddTraits(.updatesFrequently)
            ScrollView {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    if model.fileLoaded, model.formSettings == nil {
                        SHEmptyState(Text("This settings file isn’t a JSON object"),
                                     message: "Fix \(model.selectedFile?.path ?? "settings.json") in an editor, then come back. The form won’t overwrite it.") {
                            Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(.sh(.secondary))
                                .disabled(model.selectedFile?.exists != true || !project.host.supportsDetails || project.unavailable != nil)
                        }.frame(maxWidth: .infinity).padding(.vertical, SH.Space.xxxl)
                    }
                    ForEach(model.formGroups) { group in card(group) }
                    if model.formSettings != nil { codemodeCard }
                    if !model.formGroups.isEmpty {
                        Text("Space defaults apply to new threads.").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    }
                }.padding(.bottom, SH.Space.xxl)
            }.scrollIndicators(.automatic)
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
            .padding(.bottom, SH.Space.l)
    }

    private var statusText: String {
        if project.unavailable != nil { return "Host offline. Reconnect to edit or save." }
        if model.conflict { return "Space settings changed elsewhere. Reload latest before saving." }
        if let error = model.fileError { return model.fileLoaded ? "Save failed. Your changes are still here." : error }
        if model.notice != nil, !model.dirty { return "Space settings saved." }
        return "Global defaults remain unchanged. Reset removes only the space override."
    }

    private var statusAlert: Bool { project.unavailable != nil || model.conflict || model.fileError != nil }

    private func card(_ group: SpaceSettingsForm.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(group.title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Text(group.note).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.xl)
                .background(Color.sh.bgSunken)
            ForEach(group.rows) { row in
                SHHairline(color: Color.sh.lineSubtle)
                rowView(row)
            }
            if group.tools {
                SHHairline(color: Color.sh.lineSubtle)
                tools
            }
        }.background(Color.sh.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .accessibilityElement(children: .contain).accessibilityLabel(group.title)
    }

    private func rowView(_ row: SpaceSettingsForm.Row) -> some View {
        HStack(spacing: SH.Space.xl) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(row.label).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                Text(row.description).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                Text(row.source).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                if let error = row.error {
                    Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed).accessibilityAddTraits(.isStaticText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            control(row).disabled(locked)
            Button("Reset to \(row.resetTo)") { model.resetForm(row) }
                .buttonStyle(.sh(.ghost)).frame(width: AppLayout.spaceFormResetWidth)
                .disabled(locked || !row.overridden)
                .accessibilityLabel("Reset \(row.label) to \(row.resetTo)")
        }.padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.l)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func control(_ row: SpaceSettingsForm.Row) -> some View {
        switch row.control {
        case .dropdown(let options):
            Menu {
                ForEach(options, id: \.self) { option in Button(option.label) { model.setForm(row, option.value) } }
            } label: {
                HStack(spacing: SH.Space.m) {
                    Text(options.first { $0.value == row.value }?.label ?? row.value).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    SHGlyph.popupChevrons.image.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                }.padding(.horizontal, SH.Space.l).frame(width: AppLayout.spaceFormControlWidth, height: SHSettingsControlMetrics.controlHeight)
                    .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SHSettingsControlMetrics.radius))
                    .shBorder(Color.sh.lineStrong, radius: SHSettingsControlMetrics.radius)
                    .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(row.label).accessibilityValue(options.first { $0.value == row.value }?.label ?? row.value)
        case .segments(let options):
            SHSegmentedPicker(row.label, selection: Binding(get: { row.value }, set: { model.setForm(row, $0) }),
                              options: options.map { ($0.value, $0.label) })
                .shControlScale(.settings)
        case .field, .number:
            SettingsTextField(label: row.label, prompt: row.placeholder,
                              text: Binding(get: { row.value }, set: { model.setForm(row, $0) }),
                              mono: true, width: AppLayout.spaceFormControlWidth)
        case .stepper:
            SHStepper(row.label, value: Binding(get: { row.effective }, set: { model.setForm(row, String($0)) }), in: 0...AppLayout.spaceFormStepperMax)
                .shControlScale(.settings)
        }
    }

    private var tools: some View {
        let follows = model.formSettings?["defaultTools"] == nil
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.xl) {
                ForEach(SpaceSettingsForm.tools, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(get: { model.formTools.contains(tool) }, set: { model.toggleFormTool(tool, on: $0) }))
                        .toggleStyle(.shCheckbox).font(.sh(.body)).foregroundStyle(Color.sh.textSecondary)
                }
            }.frame(minHeight: SH.Height.controlL).disabled(locked || follows).accessibilityElement(children: .contain).accessibilityLabel("Built-in tools")
            Text(follows ? "Inherited tool selection. Switch to Space selection to change tools."
                         : "Explicit space selection. Unchecked tools are unavailable; an empty selection enables none.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
        }.padding(.horizontal, SH.Space.xxl).padding(.bottom, SH.Space.xl)
    }

    /// Codemode, kept from the editor this form replaces: the board has no row for it.
    private var codemodeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text("Codemode").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Text("Overrides this host’s global setting for this space.").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.xl).background(Color.sh.bgSunken)
            SHHairline(color: Color.sh.lineSubtle)
            HStack(spacing: SH.Space.xl) {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text("Codemode").font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                    Text(model.codemodeProblem ?? "Lets the agent call tools from scripts.").font(.sh(.caption))
                        .foregroundStyle(model.codemodeProblem == nil ? Color.sh.textSecondary : Color.sh.failed)
                }.frame(maxWidth: .infinity, alignment: .leading)
                SHSegmentedPicker("Space codemode", selection: $model.projectCodemode,
                                  options: [(ProjectsModel.CodemodeChoice.inherit, "Follow global"), (.on, "On"), (.off, "Off")])
                    .shControlScale(.settings)
                    .disabled(locked || model.codemodeProblem != nil)
                Color.clear.frame(width: AppLayout.spaceFormResetWidth, height: 0)
            }.padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.l)
        }.background(Color.sh.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .accessibilityElement(children: .contain).accessibilityLabel("Codemode")
    }
}

/// The form's footer, across the whole detail: save state, what the save applies to, Discard and Save changes.
struct SpaceSettingsFormFooter: View {
    @Bindable var model: ProjectsModel
    let project: ProjectsRow

    var body: some View {
        let offline = project.unavailable != nil
        HStack(spacing: SH.Space.l) {
            Text(badge).font(.sh(.caption)).foregroundStyle(Color.sh.lanternText)
                .padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.xs)
                .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            Text(model.formInvalid ? "Fix invalid values before saving." : model.conflict ? "Saving is blocked. Existing values will not be overwritten." : model.hasInheritingChildren ? "Applies to new threads in this space and inheriting child spaces." : "Applies to new threads in this space.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            if model.conflict {
                Button("Reload latest") { model.pending = .reload }.buttonStyle(.sh(.secondary, size: .l)).disabled(offline || model.saving)
            }
            Button("Discard") { model.discardForm() }.buttonStyle(.sh(.secondary, size: .l))
                .disabled(offline || model.saving || !model.dirty && !model.conflict)
            Button(model.saving ? "Saving…" : "Save changes") { Task { await model.save() } }.buttonStyle(.sh(.primary, size: .l))
                .disabled(offline || model.saving || model.conflict || !model.dirty || model.formInvalid || model.formSettings == nil)
                .keyboardShortcut("s", modifiers: .command)
        }.padding(.horizontal, AppLayout.settingsWideSides).padding(.vertical, SH.Space.xl)
            .background(Color.sh.bgWindow)
            .overlay(alignment: .top) { SHHairline(color: Color.sh.lineSubtle) }
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
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text(reload ? "Reload latest space settings?" : "Discard changes and leave?").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
                Text(reload ? "Your local edits will be discarded only after the latest values load. Nothing will be overwritten."
                            : "Unsaved space changes will be discarded. Global defaults will not change.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SH.Space.m) {
                    Spacer(minLength: 0)
                    Button("Stay") { model.pending = nil }.buttonStyle(.sh(.secondary, size: .l)).keyboardShortcut(.cancelAction)
                    Button(reload ? "Discard and reload" : "Discard and leave") { Task { await model.discard() } }
                        .buttonStyle(.sh(.danger, size: .l)).disabled(model.saving)
                }.padding(.top, SH.Space.xl)
            }.padding(SH.Space.xxl).frame(width: AppLayout.projectCookieConfirmWidth)
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
                .shadow(color: Color.sh.scrim, radius: SH.Space.xxxl, y: SH.Space.xl)
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
        HStack(spacing: SH.Space.l) {
            SHGlyph.Settings.subagents.image.foregroundStyle(Color.sh.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                Text(message).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            }
            Spacer(minLength: 0)
            if let open {
                Button(open.label, action: open.action).buttonStyle(.sh(.ghost)).disabled(disabled)
            }
        }.padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
