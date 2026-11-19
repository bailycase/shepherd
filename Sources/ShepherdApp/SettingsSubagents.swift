import SwiftUI
import ShepherdUI
import ShepherdSessions

struct SubagentsSettings: View {
    @Bindable var model: SubagentDefinitionsModel
    /// The native subagent defaults the editor shows its context against.
    var settings: AppSettings = .shared
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
        SettingsPage(title: "Profiles") {
            let ready = !model.busy && model.loaded && model.problem == nil
            SettingsGroup(title: "Profiles", links: ready ? [
                SettingsLink("New profile") { model.create() },
                SettingsLink("Restore defaults") { model.askRestore() },
            ] : []) {
                if let problem = model.problem {
                    SettingsRow(title: "", problem: problem) {
                        Button("Reload") { Task { await model.refresh() } }.buttonStyle(.sh(.secondary, size: .s)).disabled(model.busy)
                    }
                }
                if model.visible.isEmpty {
                    SettingsRow(title: model.problem != nil ? "Could not read subagent definitions"
                                : !model.loaded ? "Loading subagents…" : "No subagents") { EmptyView() }
                }
                ForEach(model.visible) { definition in
                    SettingsDrillRow(title: definition.name, subtitle: definition.diagnostic ?? definition.description,
                                     value: definition.diagnostic != nil ? definition.file : definition.capability, mono: true) {
                        Task { await model.open(definition) }
                    }
                }
            }
            .disabled(model.busy)
            SettingsGroup(title: "") {
                SettingsRow(title: "Where they live", subtitle: "One Markdown file each") {
                    HStack(spacing: SH.Space.m) {
                        SettingsValue(text: "Shepherd/pi/agents", mono: true).help(model.directory.path)
                        Button("Reveal") { model.revealFolder() }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .disabled(model.busy || !model.loaded)
                    }
                }
            }
        }
    }

    /// SubagentEdit.dc.html: the file as a form, beside its instructions.
    private var editor: some View {
        SubagentEditForm(model: model, inheritedContext: settings.childContext)
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
