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
            ] : [], lazy: true) {
                if model.loaded, model.problem == nil {
                    SettingsSearchRow(prompt: "Filter subagents", text: $model.filter)
                }
                if let problem = model.problem {
                    SettingsRow(title: "", problem: problem) {
                        Button("Reload") { Task { await model.refresh() } }.buttonStyle(.sh(.secondary, size: .s)).disabled(model.busy)
                    }
                }
                if model.visible.isEmpty {
                    SettingsRow(title: model.problem != nil ? "Could not read subagent definitions"
                                : !model.loaded ? "Loading subagents…" : model.filter.isEmpty ? "No subagents" : "No subagents match") { EmptyView() }
                }
                ForEach(model.visible) { definition in
                    SubagentProfileRow(definition: definition) { Task { await model.open(definition) } }
                        .equatable()
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

/// One profile in the list. Compares by what it draws, so a change redraws its own row and no other.
private struct SubagentProfileRow: View, Equatable {
    let definition: SubagentDefinitionsStore.Definition
    let open: () -> Void

    nonisolated static func == (a: SubagentProfileRow, b: SubagentProfileRow) -> Bool { a.definition == b.definition }

    var body: some View {
        let _ = SHRenderProbe.tick("settings.subagent.row")
        SettingsDrillRow(title: definition.name, subtitle: definition.diagnostic ?? definition.description,
                         value: definition.diagnostic != nil ? definition.file : definition.capability, mono: true, action: open)
    }
}
