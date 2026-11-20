import SwiftUI
import ShepherdRemote
import ShepherdCore
import ShepherdUI

/// SubagentEdit.dc.html: a subagent's file as a form. Every control reads and rewrites one
/// frontmatter key of the draft (`SubagentProfileText`), so the file stays the source of truth and
/// Save still validates through the runtime's own parser.
struct SubagentEditForm: View {
    @Bindable var model: SubagentDefinitionsModel
    /// What a profile without `defaultContext` starts with: Shepherd's child default.
    var inheritedContext = "fresh"

    private static let tools = ["read", "grep", "find", "ls", "bash", "edit", "write"]
    /// What pi gives a child whose file omits `tools`.
    private static let piTools = ["read", "bash", "edit", "write"]
    private static let promptLimit = 65_536

    private var title: String {
        let name = model.form.scalar("name") ?? ""
        return name.isEmpty ? (model.original == nil ? "New profile" : model.filename) : name
    }

    var body: some View {
        SettingsPage(title: title) {
            if let problem = model.problem ?? model.loadProblem {
                SettingsGroup(title: "") {
                    SettingsRow(title: "", problem: problem) {
                        // The form draws only the fields Shepherd knows, so a file that does not load
                        // (an unsupported field, say) is repaired in a text editor.
                        if model.original != nil, model.loadProblem != nil {
                            Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(.sh(.secondary, size: .s))
                        }
                    }
                }
            }
            SettingsGroup(title: "") {
                if model.original == nil {
                    SettingsRow(title: "File name", subtitle: "pi/agents/") {
                        TextField("Subagent filename", text: $model.filename)
                            .textFieldStyle(.sh(mono: true))
                            .frame(width: AppLayout.settingsFieldWidth)
                    }
                }
                SettingsRow(title: "Name") {
                    SubagentTextField(label: "Subagent name", text: stringBinding("name"), mono: true)
                        .frame(width: AppLayout.settingsFieldWidth)
                }
                SettingsRow(title: "Description", subtitle: "The parent reads this to decide when to use it") {
                    VStack(alignment: .trailing, spacing: SH.Space.s) {
                        SettingsOpenIn(text: stringBinding("description"), name: "description.txt")
                        SubagentTextField(label: "Subagent description", text: stringBinding("description"), multiline: true)
                    }
                    .frame(width: AppLayout.settingsFieldWidth)
                }
                SettingsRow(title: "Model") { modelMenu }
                SettingsRow(title: "Thinking") { thinkingMenu }
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tools").font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                        Text("Never more than the parent has").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                    SHFlowLayout(spacing: AppLayout.subagentEditChipGap) {
                        ForEach(Self.tools, id: \.self) { tool in
                            let on = enabledTools.contains(tool)
                            Button { toggle(tool) } label: {
                                Text(tool).font(.shMono(AppLayout.subagentEditChipSize))
                                    .foregroundStyle(on ? Color.sh.textPrimary : Color.sh.textTertiary)
                                    .padding(.horizontal, AppLayout.subagentEditChipPadding)
                                    .frame(height: AppLayout.subagentEditChipHeight)
                                    .background(on ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                                    .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
                            }.buttonStyle(.plain).shFocusRing(radius: SH.Radius.s, color: .sh.running)
                                .accessibilityLabel(tool).accessibilityValue(on ? "on" : "off").accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsRow(title: "Starts with") {
                    SubagentSegments(label: "Starts with", selection: stringBinding("defaultContext", fallback: inheritedContext, also: "context"),
                                     options: [("fresh", "Fresh context"), ("fork", "A copy of the thread")])
                }
                SettingsRow(title: "Instructions are") {
                    SubagentSegments(label: "Instructions are", selection: stringBinding("systemPromptMode", fallback: isDelegate ? "append" : "replace"),
                                     options: [("replace", "Its whole prompt"), ("append", "Added to default")])
                }
                SettingsRow(title: "Read the space's AGENTS.md", subtitle: model.form.bool("inheritProjectContext") ?? isDelegate ? "On" : "Off by default") {
                    SettingsSwitch(label: "Read the space's AGENTS.md", isOn: flag("inheritProjectContext", default: isDelegate))
                }
                SettingsRow(title: "Use the thread's skills", subtitle: flag("inheritSkills", default: false).wrappedValue ? "On" : "Off by default") {
                    SettingsSwitch(label: "Use the thread's skills", isOn: flag("inheritSkills", default: false))
                }
                SettingsRow(title: "Disabled", subtitle: "It will refuse to launch") {
                    SettingsSwitch(label: "Disabled", isOn: flag("disabled", default: false))
                }
            }
            prompt
            if model.original != nil {
                SettingsGroup(title: "") {
                    SettingsRow(title: "Delete profile", subtitle: "Removes the Markdown file") {
                        Button("Delete…") { model.askDelete() }.buttonStyle(.sh(.danger, size: .s))
                    }
                }
            }
        }
        .disabled(model.busy)
    }

    private var isDelegate: Bool { model.form.scalar("name") == "delegate" }

    // MARK: Tools

    private var enabledTools: [String] { model.form.list("tools") ?? Self.piTools }

    private func toggle(_ tool: String) {
        var chosen = enabledTools
        if let index = chosen.firstIndex(of: tool) { chosen.remove(at: index) } else { chosen.append(tool) }
        // The seven in the board's order, then any tool the file names that the form does not draw.
        model.form.set("tools", list: Self.tools.filter(chosen.contains) + chosen.filter { !Self.tools.contains($0) })
    }

    // MARK: Model and thinking

    private var modelMenu: some View {
        let current = model.form.scalar("model")
        let choices = ([current].compactMap { $0 } + model.modelChoices).reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }
        return SubagentModelField(current: current, choices: choices) { model.form.set("model", scalar: $0) }
    }

    private var thinkingMenu: some View {
        // `thinking: false` is how a file says off.
        let current = model.form.scalar("thinking").map { $0 == "false" ? "off" : $0 }
        return SubagentPopup(label: "Thinking", title: current.flatMap { ThinkingLevel(rawValue: $0)?.title } ?? current ?? "Inherit from the thread", mono: false) {
            Button("Inherit from the thread") { model.form.set("thinking", scalar: nil) }
            Divider()
            ForEach(ThinkingLevel.allCases, id: \.self) { level in Button(level.title) { model.form.set("thinking", scalar: level.rawValue) } }
        }
    }

    // MARK: Prompt

    /// The profile's instructions in the Settings editor card.
    private var prompt: some View {
        let used = model.form.body.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            SHSectionHeader("Prompt", style: .settings) {
                Text("\(used.formatted()) / \(Self.promptLimit.formatted())").font(.sh(.mono))
                    .foregroundStyle(used > Self.promptLimit ? Color.sh.failed : Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xs)
            SettingsEditorCard(name: model.filename.isEmpty ? "profile.md" : model.filename, edited: model.dirty,
                               openIn: Binding(get: { model.form.body }, set: { model.form.body = $0 })) {
                Button("Revert") { model.revert() }.buttonStyle(.sh(.secondary, size: .s)).disabled(!model.dirty)
                Button("Save") { Task { await model.save() } }.buttonStyle(.sh(.primary, size: .s)).disabled(!model.canSave)
            } content: {
                InstructionsEditor(text: Binding(get: { model.form.body }, set: { model.form.body = $0 }), saved: model.form.body,
                                   accessibilityLabel: "Subagent instructions")
            }
        }
        .shControlScale(.settings)
    }

    // MARK: Bindings

    /// A key's text, or `fallback` while the file leaves it out. Choosing a value writes it, and
    /// `also` (an older spelling of the same key) is dropped. Clearing a text field removes its key.
    private func stringBinding(_ key: String, fallback: String = "", also older: String? = nil) -> Binding<String> {
        Binding(
            get: { model.form.scalar(key) ?? older.flatMap { model.form.scalar($0) } ?? fallback },
            set: { value in
                var form = model.form
                if let older { form.set(older, scalar: nil) }
                form.set(key, scalar: value.isEmpty ? nil : value)
                model.form = form
            })
    }

    /// A true/false key. Off removes it when the runtime's default is also off.
    private func flag(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { model.form.bool(key) ?? fallback },
            set: { on in model.form.set(key, bool: on || fallback ? on : nil) })
    }
}

// MARK: Controls

private struct SubagentTextField: View {
    let label: String
    @Binding var text: String
    var mono = false
    var multiline = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline { TextField("", text: $text, axis: .vertical) } else { TextField("", text: $text) }
        }
            .textFieldStyle(.plain).focused($focused)
            .font(mono ? .shMono(AppLayout.subagentEditFieldSize) : .shSans(AppLayout.subagentEditFieldSize))
            .foregroundStyle(Color.sh.textPrimary).tint(Color.sh.lantern)
            .lineSpacing(multiline ? AppLayout.subagentEditDescriptionLineExtra : 0)
            .padding(.horizontal, AppLayout.subagentEditFieldPadding)
            .padding(.top, multiline ? AppLayout.subagentEditDescriptionTop : 0)
            .frame(maxWidth: .infinity, minHeight: multiline ? AppLayout.subagentEditDescriptionHeight : AppLayout.subagentEditFieldHeight,
                   alignment: multiline ? .topLeading : .leading)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.subagentEditFieldRadius))
            .shBorder(Color.sh.lineStrong, radius: AppLayout.subagentEditFieldRadius)
            .shFocusRing(focused, radius: AppLayout.subagentEditFieldRadius)
            .contentShape(Rectangle()).onTapGesture { focused = true }
            .accessibilityLabel(label)
    }
}

/// A popup drawn full width with the board's chevron, on a native menu.
private struct SubagentPopup<Items: View>: View {
    let label: String
    let title: String
    let mono: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) { SubagentPopupLabel(title: title, mono: mono) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .shFocusRing(radius: AppLayout.subagentEditFieldRadius, color: .sh.running)
            .accessibilityLabel(label).accessibilityValue(title)
    }
}

private struct SubagentPopupLabel: View {
    let title: String
    let mono: Bool

    var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(title).font(mono ? .shMono(AppLayout.subagentEditChipSize) : .shSans(AppLayout.subagentEditFieldSize))
                .foregroundStyle(Color.sh.textPrimary).lineLimit(mono ? 1 : 2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: AppLayout.subagentEditPopupChevron, weight: .semibold))
                .foregroundStyle(Color.sh.settingsMuted)
        }
        .padding(.horizontal, AppLayout.subagentEditFieldPadding).padding(.vertical, SH.Space.xs)
        .frame(maxWidth: .infinity, minHeight: AppLayout.subagentEditFieldHeight)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.subagentEditFieldRadius))
        .shBorder(Color.sh.lineStrong, radius: AppLayout.subagentEditFieldRadius)
        .contentShape(Rectangle())
    }
}

/// The model field: the popup's look, opening the composer's searchable model picker, because a
/// custom provider lists hundreds of models. Typing filters by substring of the id.
struct SubagentModelField: View {
    let current: String?
    let choices: [String]
    let choose: (String?) -> Void
    @State private var open = false
    @State private var query = ""
    @State private var selection = 0

    static let inherit = "Inherit from the thread"

    var body: some View {
        Button { open = true } label: { SubagentPopupLabel(title: current ?? Self.inherit, mono: current != nil) }
            .buttonStyle(.plain)
            .shFocusRing(radius: AppLayout.subagentEditFieldRadius, color: .sh.running)
            .accessibilityLabel("Model").accessibilityValue(current ?? Self.inherit)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SHModelPicker(query: $query, sections: Self.sections(choices: choices, query: query, current: current), selection: $selection, onChoose: {
                    choose($0.id.isEmpty ? nil : $0.id)
                    open = false
                }, onClose: { open = false })
                .onDisappear { query = ""; selection = 0 }
            }
    }

    static func sections(choices: [String], query: String, current: String?) -> [SHModelSection] {
        // Each word typed must appear in the id: ids join words with hyphens, people type spaces.
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matches = choices.filter { choice in
            let key = choice.lowercased()
            return words.allSatisfy { key.contains($0) }
        }
        let options = matches.map { SHModelOption(id: $0, title: $0, isCurrent: $0 == current) }
        let inherit = SHModelOption(id: "", title: Self.inherit, isCurrent: current == nil)
        return [SHModelSection(title: "Models", options: (words.isEmpty ? [inherit] : []) + options)]
    }
}

/// The kit's segmented control at the Settings scale.
private struct SubagentSegments: View {
    let label: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SHSegmentedPicker(label, selection: $selection, options: options).shControlScale(.settings)
    }
}

/// The board's switch: 32 × 18, a dark knob on lantern, with its label and a note after it.
private struct SubagentSwitch: View {
    let label: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: AppLayout.subagentEditSwitchGap) {
                Capsule().fill(isOn ? Color.sh.lantern : Color.sh.lineStrong)
                    .frame(width: AppLayout.subagentEditSwitchWidth, height: AppLayout.subagentEditSwitchHeight)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(isOn ? Color.sh.textOnLantern : Color.sh.textSecondary)
                            .frame(width: AppLayout.subagentEditKnob, height: AppLayout.subagentEditKnob)
                            .padding(AppLayout.subagentEditKnobInset)
                    }
                    .shComponentAnimation(.content, value: isOn)
                Text(label).font(.shSans(AppLayout.subagentEditSwitchLabelSize)).foregroundStyle(Color.sh.textPrimary)
                Text(note).font(.shSans(AppLayout.subagentEditNoteSize)).foregroundStyle(Color.sh.settingsMuted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: SH.Height.controlS).contentShape(Rectangle())
        }
        .buttonStyle(.plain).shFocusRing(radius: SH.Radius.xs, color: .sh.running)
        .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
    }
}

/// Delete, Revert and Save: 30 high at radius 7.
private struct SubagentEditButton: ButtonStyle {
    enum Kind { case delete, revert, save }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, kind: kind) }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let active = enabled && (hovering || configuration.isPressed)
            let radius = AppLayout.subagentEditButtonRadius
            configuration.label
                .font(.shSans(AppLayout.subagentEditButtonSize, kind == .save ? .semibold : .regular))
                .foregroundStyle(kind == .delete ? Color.sh.failed : kind == .save ? Color.sh.textOnLantern : Color.sh.subagentControlText)
                .padding(.horizontal, kind == .save ? AppLayout.subagentEditSavePadding : AppLayout.subagentEditButtonPadding)
                .frame(height: AppLayout.subagentEditButtonHeight)
                .background(fill(active: active, pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: radius))
                .shBorder(kind == .delete ? Color.sh.subagentFailureBorder : kind == .revert ? Color.sh.lineStrong : .clear, radius: radius)
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .shFocusRing(radius: radius, color: .sh.running)
                .shEnabledOpacity(enabled)
                .onHover { hovering = $0 }
        }

        private func fill(active: Bool, pressed: Bool) -> Color {
            switch kind {
            case .save: pressed ? Color.sh.lanternPressed : active ? Color.sh.lanternHover : Color.sh.lantern
            case .revert: active ? Color.sh.bgHover : Color.sh.bgRaised
            case .delete: active ? Color.sh.subagentFailureTile : .clear
            }
        }
    }
}
