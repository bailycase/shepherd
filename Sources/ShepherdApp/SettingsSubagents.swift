import SwiftUI
import ShepherdUI
import ShepherdSessions

struct SubagentsSettings: View {
    @Bindable var model: SubagentDefinitionsModel
    /// The native subagent switches and defaults under the list; nil in a test of the list alone.
    var native: NativeSubagentSettings? = nil
    @State private var dontAskAgain = false
    static let explanation = "A subagent is a Markdown file: a name, a description, and the instructions it runs with. An agent starts one by name and gets the result back. Shepherd ships a few to start with. Edit them, delete them, or add your own. They are read from one folder, and nowhere else."

    var body: some View {
        Group {
            if model.editing { editor }
            else { index }
        }
        .task { await model.refresh() }
        .sheet(item: Binding(get: { model.confirmation.map { Confirmation(action: $0) } }, set: { if $0 == nil { model.cancelConfirmation() } else { model.confirmation = $0?.action } })) { prompt in
            SHDialog(prompt.title, message: prompt.message, content: { DontAskAgainToggle(isOn: $dontAskAgain).dialogInset() }) {
                Button("Cancel") { model.cancelConfirmation() }.buttonStyle(.sh(.secondary)).keyboardShortcut(.cancelAction)
                Button(prompt.button) {
                    if dontAskAgain { model.settings.skip(prompt.action.skippable, with: prompt.button) }
                    Task { await model.confirm() }
                }.buttonStyle(.sh(.danger))
            }
            .onAppear { dontAskAgain = false }
        }
    }

    private var index: some View {
        VStack(alignment: .leading, spacing: AppLayout.subagentSettingsGap) {
            SettingsHeader(title: "Subagents", explanation: Self.explanation)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppLayout.subagentToolbarGap) { filter; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: SH.Space.m) { filter; HStack { Spacer(minLength: 0); actions } }
            }
            if let problem = model.problem {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHInlineProblem(problem)
                    Button("Reload") { Task { await model.refresh() } }.buttonStyle(.sh(.secondary, size: .s)).disabled(model.busy)
                }
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppLayout.subagentToolbarGap) { sectionHeading; Spacer(minLength: 0); folder }
                    VStack(alignment: .leading, spacing: SH.Space.m) { sectionHeading; folder }
                }.padding(.horizontal, SH.Space.xs)
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { definition in
                        SubagentDefinitionRow(definition: definition) { Task { await model.open(definition) } }
                    }
                    if model.visible.isEmpty {
                        Text(model.problem != nil ? "Could not read subagent definitions." : !model.loaded ? "Loading subagents…" : model.definitions.isEmpty ? "No subagents" : "No matching subagents")
                            .font(.sh(.body)).foregroundStyle(Color.sh.textSecondary)
                            .padding(SH.Space.xxl).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(SH.Space.xs)
                    .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius))
                    .shBorder(Color.sh.projectDivider, radius: SHCardRowMetrics.settingsCardRadius, width: SHSettingsNavMetrics.borderWidth)
                    .disabled(model.busy)
            }
            if let native { native.padding(.top, AppLayout.settingsGroupSpacing - AppLayout.subagentSettingsGap) }
        }
    }
    private var filter: some View {
        SHSettingsSearchField("Filter subagents", text: $model.filter, placement: .subagents)
            .frame(width: AppLayout.subagentFilterWidth)
    }
    private var actions: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Button("Restore defaults") { model.askRestore() }.buttonStyle(SubagentSettingsActionStyle()).disabled(model.busy || !model.loaded || model.problem != nil)
            Button { model.create() } label: {
                HStack(spacing: SH.Space.m) { SHGlyph.Settings.subagentPlus.image.accessibilityHidden(true); Text("New subagent") }
            }.buttonStyle(SubagentSettingsActionStyle(primary: true)).disabled(model.busy || !model.loaded || model.problem != nil)
                .accessibilityLabel("New subagent")
        }
    }
    private var sectionHeading: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Text("SUBAGENTS").font(.shSans(AppLayout.subagentSectionSize, .semibold))
                .tracking(AppLayout.subagentSectionSize * AppLayout.subagentSectionTracking).foregroundStyle(Color.sh.textSecondary)
            Text(model.problem != nil && model.definitions.isEmpty ? "Unavailable" : !model.loaded ? "…" : model.definitions.count.formatted()).font(.shMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.sh.settingsMuted)
        }
    }
    private var folder: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Text("Shepherd/pi/agents").font(.shMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.sh.settingsMuted).help(model.directory.path)
            Button("Show in Finder") { model.revealFolder() }
                .font(.shSans(AppLayout.subagentFinderSize)).foregroundStyle(Color.sh.textSecondary)
                .padding(.horizontal, SH.Space.m).frame(height: AppLayout.subagentFinderVisualHeight)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.s, width: SHSettingsNavMetrics.borderWidth)
                .frame(minHeight: SH.Height.controlS)
                .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
                .buttonStyle(.shRow(focusColor: .sh.running)).disabled(model.busy || !model.loaded)
        }
    }

    /// SubagentEdit.dc.html: the file as a form, beside its instructions.
    private var editor: some View {
        SubagentEditForm(model: model, inheritedContext: native?.settings.childContext ?? "fresh")
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
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.m) {
                Text(definition.name).font(.shMono(AppLayout.subagentRowNameSize, .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                if failed { badge(definition.disabled == true && definition.error == nil ? "disabled" : "can’t load", failed: true) }
                else if definition.isDefault { badge("default", failed: false) }
            }
            Text(definition.diagnostic ?? definition.description ?? "")
                .font(.shSans(AppLayout.subagentDescriptionSize)).foregroundStyle(failed ? AgentState.failed.color : Color.sh.textSecondary)
                .lineLimit(1).truncationMode(.tail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var glyph: some View {
        SHGlyph.Settings.subagentFile.image
            .foregroundStyle(failed ? AgentState.failed.color : Color.sh.textSecondary)
            .frame(width: AppLayout.subagentGlyphTile, height: AppLayout.subagentGlyphTile)
            .background(failed ? Color.sh.subagentFailureTile : Color.sh.bgBubble, in: RoundedRectangle(cornerRadius: AppLayout.subagentGlyphRadius))
            .accessibilityHidden(true)
    }
    var body: some View {
        let _ = SHRenderProbe.tick("settings.subagent.row")
        Button(action: open) {
            HStack(spacing: SH.Space.l) {
                glyph
                details
                Text(failed ? definition.file : definition.capability).font(.shMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.sh.settingsMuted).lineLimit(1)
                SHGlyph.Settings.subagentNext.image.foregroundStyle(Color.sh.settingsMuted).accessibilityHidden(true)
            }.padding(.horizontal, AppLayout.subagentRowPadding)
                .frame(minHeight: AppLayout.subagentRowContentHeight)
                .background(hovering || focused ? Color.sh.bgBubble : .clear, in: RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
                .shBorder(hovering || focused ? Color.sh.lineStrong : .clear, radius: AppLayout.subagentActionRadius, width: SHSettingsNavMetrics.borderWidth)
                .contentShape(RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
        }.buttonStyle(.shRow(radius: AppLayout.subagentActionRadius, focusColor: .sh.running))
            .focused($focused)
            .frame(minHeight: AppLayout.subagentRowHeight)
            .onHover { hovering = $0 }
            .help(definition.diagnostic ?? definition.description ?? definition.file)
            .accessibilityLabel("Open \(definition.name)")
            .accessibilityValue(definition.diagnostic ?? ((definition.description ?? "") + ", " + definition.capability))
    }
    private func badge(_ title: String, failed: Bool) -> some View {
        Text(title).font(.shMono(AppLayout.subagentBadgeSize)).foregroundStyle(failed ? AgentState.failed.color : Color.sh.textSecondary)
            .padding(.horizontal, AppLayout.subagentBadgePadding)
            .shBorder(failed ? Color.sh.subagentFailureBorder : Color.sh.lineStrong, radius: SH.Radius.xs, width: SHSettingsNavMetrics.borderWidth)
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
        let fill = primary ? (configuration.isPressed && enabled ? Color.sh.lanternPressed : hovering && enabled ? Color.sh.lanternHover : Color.sh.lantern)
                           : (hovering && enabled ? Color.sh.bgHover : Color.sh.bgRaised)
        configuration.label.font(.shSans(AppLayout.subagentActionSize, primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.sh.textOnLantern : Color.sh.textPrimary)
            .padding(.horizontal, AppLayout.subagentActionPadding).frame(minHeight: SH.Height.controlL)
            .background(fill, in: RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
            .shBorder(primary ? .clear : Color.sh.lineStrong, radius: AppLayout.subagentActionRadius, width: SHSettingsNavMetrics.borderWidth)
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.subagentActionRadius))
            .shFocusRing(radius: AppLayout.subagentActionRadius, color: .sh.running)
            .shEnabledOpacity(enabled)
            .onHover { hovering = $0 }
    }
}
