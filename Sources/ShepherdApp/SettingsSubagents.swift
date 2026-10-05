import SwiftUI
import ShepherdUI
import ShepherdSessions

struct SubagentsSettings: View {
    @Bindable var model: SubagentDefinitionsModel
    static let explanation = "A subagent is a Markdown file: a name, a description, and the instructions it runs with. An agent starts one by name and gets the result back. Shepherd ships a few to start with. Edit them, delete them, or add your own. They are read from one folder, and nowhere else."

    var body: some View {
        Group {
            if model.editing { editor }
            else { index }
        }
        .task { await model.refresh() }
        .sheet(item: Binding(get: { model.confirmation.map { Confirmation(action: $0) } }, set: { if $0 == nil { model.cancelConfirmation() } else { model.confirmation = $0?.action } })) { prompt in
            NWDialog(prompt.title, message: prompt.message, content: {}) {
                Button("Cancel") { model.cancelConfirmation() }.buttonStyle(.nw(.secondary)).keyboardShortcut(.cancelAction)
                Button(prompt.button) { Task { await model.confirm() } }.buttonStyle(.nw(.danger))
            }
        }
    }

    private var index: some View {
        VStack(alignment: .leading, spacing: AppLayout.subagentSettingsGap) {
            SettingsHeader(title: "Subagents", explanation: Self.explanation)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppLayout.subagentToolbarGap) { filter; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: NW.Space.m) { filter; HStack { Spacer(minLength: 0); actions } }
            }
            if let problem = model.problem {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWInlineProblem(problem)
                    Button("Reload") { Task { await model.refresh() } }.buttonStyle(.nw(.secondary, size: .s)).disabled(model.busy)
                }
            }
            VStack(alignment: .leading, spacing: NW.Space.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppLayout.subagentToolbarGap) { sectionHeading; Spacer(minLength: 0); folder }
                    VStack(alignment: .leading, spacing: NW.Space.m) { sectionHeading; folder }
                }.padding(.horizontal, NW.Space.xs)
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { definition in
                        SubagentDefinitionRow(definition: definition) { Task { await model.open(definition) } }
                    }
                    if model.visible.isEmpty {
                        Text(model.problem != nil ? "Could not read subagent definitions." : !model.loaded ? "Loading subagents…" : model.definitions.isEmpty ? "No subagents" : "No matching subagents")
                            .font(.nw(.body)).foregroundStyle(Color.nw.textSecondary)
                            .padding(NW.Space.xxl).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(NW.Space.xs)
                    .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
                    .nwBorder(Color.nw.projectDivider, radius: NWCardRowMetrics.settingsCardRadius, width: NWSettingsNavMetrics.borderWidth)
                    .disabled(model.busy)
            }
        }
    }
    private var filter: some View {
        NWSettingsSearchField("Filter subagents", text: $model.filter, placement: .subagents)
            .frame(width: AppLayout.subagentFilterWidth)
    }
    private var actions: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Button("Restore defaults") { model.askRestore() }.buttonStyle(SubagentSettingsActionStyle()).disabled(model.busy || !model.loaded || model.problem != nil)
            Button { model.create() } label: {
                HStack(spacing: NW.Space.m) { NWGlyph.Settings.subagentPlus.image.accessibilityHidden(true); Text("New subagent") }
            }.buttonStyle(SubagentSettingsActionStyle(primary: true)).disabled(model.busy || !model.loaded || model.problem != nil)
                .accessibilityLabel("New subagent")
        }
    }
    private var sectionHeading: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Text("SUBAGENTS").font(.nwSans(AppLayout.subagentSectionSize, .semibold))
                .tracking(AppLayout.subagentSectionSize * AppLayout.subagentSectionTracking).foregroundStyle(Color.nw.textSecondary)
            Text(model.problem != nil && model.definitions.isEmpty ? "Unavailable" : !model.loaded ? "…" : model.definitions.count.formatted()).font(.nwMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.nw.settingsMuted)
        }
    }
    private var folder: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Text("Shepherd/pi/agents").font(.nwMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.nw.settingsMuted).help(model.directory.path)
            Button("Show in Finder") { model.revealFolder() }
                .font(.nwSans(AppLayout.subagentFinderSize)).foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.m).frame(height: AppLayout.subagentFinderVisualHeight)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .nwBorder(Color.nw.lineStrong, radius: NW.Radius.s, width: NWSettingsNavMetrics.borderWidth)
                .frame(minHeight: NW.Height.controlS)
                .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
                .buttonStyle(.nwRow(focusColor: .nw.running)).disabled(model.busy || !model.loaded)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            Button("Subagents") { model.back() }.buttonStyle(.nw(.ghost)).accessibilityLabel("Back to Subagents").disabled(model.busy)
            SettingsHeader(title: model.original == nil ? "New subagent" : model.filename, explanation: "Markdown frontmatter names the subagent and its options. The body is its instructions. Saved changes apply to new child runs.")
            if model.original == nil {
                TextField("Filename", text: $model.filename).nwField(mono: true).accessibilityLabel("Subagent filename").disabled(model.busy)
            }
            InstructionsEditor(text: $model.draft, saved: model.original?.text ?? "", accessibilityLabel: "Subagent definition editor", project: true)
                .frame(minHeight: AppLayout.projectNarrowEditorHeight)
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                .disabled(model.busy)
            if let problem = model.problem { NWInlineProblem(problem) }
            HStack(spacing: NW.Space.m) {
                if model.original != nil {
                    Button("Delete") { model.askDelete() }.buttonStyle(.nw(.danger)).disabled(model.busy)
                    Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(.nw(.secondary)).disabled(model.busy)
                }
                Spacer(minLength: 0)
                Text(model.dirty ? "Unsaved changes" : "Saved").font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                Button("Save") { Task { await model.save() } }.buttonStyle(.nw(.primary)).disabled(!model.canSave)
            }
        }
    }

    private struct Confirmation: Identifiable {
        let action: SubagentDefinitionsModel.Confirmation
        var id: SubagentDefinitionsModel.Confirmation { action }
        var title: String { switch action { case .restore: "Restore default subagents?"; case .delete: "Delete this subagent?"; case .discard: "Discard unsaved changes?" } }
        var message: String { switch action {
            case .restore: "Replace scout, reviewer, planner and worker with Shepherd's defaults. Your custom files stay unchanged."
            case .delete: "This removes the saved Markdown file. Running children keep their loaded instructions."
            case .discard: "Your draft has not been saved. Discard it to return to the list."
        } }
        var button: String { switch action { case .restore: "Restore"; case .delete: "Delete subagent"; case .discard: "Discard" } }
    }
}

struct SubagentDefinitionRow: View, Equatable {
    let definition: SubagentDefinitionsStore.Definition
    let open: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.definition == rhs.definition }

    private var failed: Bool { definition.diagnostic != nil }
    private var details: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            HStack(spacing: NW.Space.m) {
                Text(definition.name).font(.nwMono(AppLayout.subagentRowNameSize, .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                if failed { badge(definition.disabled == true && definition.error == nil ? "disabled" : "can’t load", failed: true) }
                else if definition.isDefault { badge("default", failed: false) }
            }
            Text(definition.diagnostic ?? definition.description ?? "")
                .font(.nwSans(AppLayout.subagentDescriptionSize)).foregroundStyle(failed ? AgentState.failed.color : Color.nw.textSecondary)
                .lineLimit(1).truncationMode(.tail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var glyph: some View {
        NWGlyph.Settings.subagentFile.image
            .foregroundStyle(failed ? AgentState.failed.color : Color.nw.textSecondary)
            .frame(width: AppLayout.subagentGlyphTile, height: AppLayout.subagentGlyphTile)
            .background(failed ? Color.nw.subagentFailureTile : Color.nw.bgBubble, in: RoundedRectangle(cornerRadius: AppLayout.subagentGlyphRadius))
            .accessibilityHidden(true)
    }
    var body: some View {
        let _ = NWRenderProbe.tick("settings.subagent.row")
        Button(action: open) {
            HStack(spacing: NW.Space.l) {
                glyph
                details
                Text(failed ? definition.file : definition.capability).font(.nwMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.nw.settingsMuted).lineLimit(1)
                NWGlyph.Settings.subagentNext.image.foregroundStyle(Color.nw.settingsMuted).accessibilityHidden(true)
            }.padding(.horizontal, AppLayout.subagentRowPadding)
                .frame(minHeight: AppLayout.subagentRowContentHeight)
                .background(hovering || focused ? Color.nw.bgBubble : .clear, in: RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
                .nwBorder(hovering || focused ? Color.nw.lineStrong : .clear, radius: AppLayout.subagentActionRadius, width: NWSettingsNavMetrics.borderWidth)
                .contentShape(RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
        }.buttonStyle(.nwRow(radius: AppLayout.subagentActionRadius, focusColor: .nw.running))
            .focused($focused)
            .frame(minHeight: AppLayout.subagentRowHeight)
            .onHover { hovering = $0 }
            .help(definition.diagnostic ?? definition.description ?? definition.file)
            .accessibilityLabel("Open \(definition.name)")
            .accessibilityValue(definition.diagnostic ?? ((definition.description ?? "") + ", " + definition.capability))
    }
    private func badge(_ title: String, failed: Bool) -> some View {
        Text(title).font(.nwMono(AppLayout.subagentBadgeSize)).foregroundStyle(failed ? AgentState.failed.color : Color.nw.textSecondary)
            .padding(.horizontal, AppLayout.subagentBadgePadding)
            .nwBorder(failed ? Color.nw.subagentFailureBorder : Color.nw.lineStrong, radius: NW.Radius.xs, width: NWSettingsNavMetrics.borderWidth)
    }
}

private struct SubagentSettingsActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { SubagentSettingsAction(configuration: configuration, primary: primary) }
}

private struct SubagentSettingsAction: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let fill = primary ? (configuration.isPressed && enabled ? Color.nw.lanternPressed : hovering && enabled ? Color.nw.lanternHover : Color.nw.lantern)
                           : (hovering && enabled ? Color.nw.bgHover : Color.nw.bgRaised)
        configuration.label.font(.nwSans(AppLayout.subagentActionSize, primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.nw.textOnLantern : Color.nw.textPrimary)
            .padding(.horizontal, AppLayout.subagentActionPadding).frame(minHeight: NW.Height.controlL)
            .background(fill, in: RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
            .nwBorder(primary ? .clear : Color.nw.lineStrong, radius: AppLayout.subagentActionRadius, width: NWSettingsNavMetrics.borderWidth)
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
            .nwFocusRing(radius: AppLayout.subagentActionRadius, color: .nw.running)
            .nwEnabledOpacity(enabled)
            .onHover { hovering = $0 }
    }
}
