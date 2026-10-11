import SwiftUI
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.subagentEditGap) {
            header
            GeometryReader { geometry in
                if geometry.size.width >= AppLayout.subagentEditFormWidth + AppLayout.subagentEditColumnGap + AppLayout.subagentEditInstructionsMinWidth {
                    HStack(alignment: .top, spacing: AppLayout.subagentEditColumnGap) {
                        ScrollView(.vertical) { fields }
                            .scrollIndicators(.hidden).scrollClipDisabled()
                            .frame(width: AppLayout.subagentEditFormWidth)
                        instructions.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: AppLayout.subagentEditGap) {
                            fields.frame(maxWidth: AppLayout.subagentEditFormWidth)
                            instructions.frame(height: AppLayout.subagentEditNarrowInstructionsHeight)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            }
        }
        .disabled(model.busy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var title: String {
        let name = model.form.scalar("name") ?? ""
        return name.isEmpty ? (model.original == nil ? "New subagent" : model.filename) : name
    }

    private var header: some View {
        HStack(spacing: AppLayout.subagentToolbarGap) {
            Button { model.back() } label: {
                Text("Subagents").font(.nwSans(AppLayout.subagentActionSize)).foregroundStyle(Color.nw.settingsMuted)
                    .frame(minHeight: NW.Height.controlS).contentShape(Rectangle())
            }.buttonStyle(.plain).nwFocusRing(radius: NW.Radius.xs, color: .nw.running).accessibilityLabel("Back to Subagents")
            Text("/").font(.nwSans(AppLayout.subagentEditSlashSize)).foregroundStyle(Color.nw.settingsMuted).accessibilityHidden(true)
            Text(title).font(.nw(.title)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
            path
            Spacer(minLength: 0)
            if model.original != nil {
                Button("Delete") { model.askDelete() }.buttonStyle(SubagentEditButton(.delete))
            }
            Button("Revert") { model.revert() }.buttonStyle(SubagentEditButton(.revert)).disabled(!model.dirty)
            Button("Save") { Task { await model.save() } }.buttonStyle(SubagentEditButton(.save)).disabled(!model.canSave)
        }
    }

    /// The file's path in the pi folder. A new file's name is typed here.
    private var path: some View {
        HStack(spacing: 0) {
            Text("pi/agents/")
            if model.original == nil {
                TextField("Subagent filename", text: $model.filename).textFieldStyle(.plain)
                    .font(.nwMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.nw.textPrimary).tint(Color.nw.lantern)
                    .fixedSize().accessibilityLabel("Subagent filename")
            } else {
                Text(model.filename)
            }
        }
        .font(.nwMono(AppLayout.subagentMetaSize)).foregroundStyle(Color.nw.settingsMuted).lineLimit(1)
        .padding(.horizontal, AppLayout.subagentEditPathPadding).padding(.vertical, NW.Space.xxs)
        .nwBorder(Color.nw.lineStrong, radius: AppLayout.subagentEditPathRadius)
    }

    // MARK: Form

    private var fields: some View {
        VStack(alignment: .leading, spacing: AppLayout.subagentEditFieldGap) {
            if let problem = model.problem ?? model.loadProblem {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWInlineProblem(problem)
                    // The form draws only the fields Shepherd knows, so a file that does not load
                    // (an unsupported field, say) is repaired in a text editor.
                    if model.original != nil, model.loadProblem != nil {
                        Button("Open in editor") { Task { await model.openInEditor() } }.buttonStyle(SubagentEditButton(.revert))
                    }
                }
            }
            field("Name") {
                SubagentTextField(label: "Subagent name", text: stringBinding("name"), mono: true)
            }
            field("Description", hint: "the parent reads this to decide when to use it") {
                SubagentTextField(label: "Subagent description", text: stringBinding("description"), multiline: true)
            }
            field("Tools", hint: "never more than the parent has", gap: AppLayout.subagentEditToolsGap) {
                NWFlowLayout(spacing: AppLayout.subagentEditChipGap) {
                    ForEach(Self.tools, id: \.self) { tool in
                        let on = enabledTools.contains(tool)
                        Button { toggle(tool) } label: {
                            Text(tool).font(.nwMono(AppLayout.subagentEditChipSize))
                                .foregroundStyle(on ? Color.nw.textPrimary : Color.nw.settingsMuted)
                                .padding(.horizontal, AppLayout.subagentEditChipPadding)
                                .frame(height: AppLayout.subagentEditChipHeight)
                                .background(on ? Color.nw.subagentChipOn : .clear, in: RoundedRectangle(cornerRadius: AppLayout.subagentEditChipRadius))
                                .nwBorder(on ? Color.nw.subagentChipOnBorder : Color.nw.lineStrong, radius: AppLayout.subagentEditChipRadius)
                                .contentShape(RoundedRectangle(cornerRadius: AppLayout.subagentEditChipRadius))
                        }.buttonStyle(.plain).nwFocusRing(radius: AppLayout.subagentEditChipRadius, color: .nw.running)
                            .accessibilityLabel(tool).accessibilityValue(on ? "on" : "off").accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(alignment: .top, spacing: AppLayout.subagentEditPopupGap) {
                field("Model") { modelMenu }.frame(maxWidth: .infinity, alignment: .leading)
                field("Thinking") { thinkingMenu }.frame(maxWidth: .infinity, alignment: .leading)
            }
            field("Starts with") {
                SubagentSegments(label: "Starts with", selection: stringBinding("defaultContext", fallback: inheritedContext, also: "context"),
                                 options: [("fresh", "Fresh context"), ("fork", "A copy of the thread")])
            }
            field("Instructions are") {
                SubagentSegments(label: "Instructions are", selection: stringBinding("systemPromptMode", fallback: isDelegate ? "append" : "replace"),
                                 options: [("replace", "Its whole system prompt"), ("append", "Added to the default")])
            }
            VStack(alignment: .leading, spacing: AppLayout.subagentEditSwitchGap - NW.Space.s) {
                SubagentSwitch(label: "Read the space's AGENTS.md", note: model.form.bool("inheritProjectContext") ?? isDelegate ? "on" : "off by default",
                               isOn: flag("inheritProjectContext", default: isDelegate))
                SubagentSwitch(label: "Use the thread's skills", note: flag("inheritSkills", default: false).wrappedValue ? "on" : "off by default",
                               isOn: flag("inheritSkills", default: false))
                SubagentSwitch(label: "Disabled", note: "it will refuse to launch", isOn: flag("disabled", default: false))
            }.padding(.top, AppLayout.subagentEditSwitchesTop - NW.Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(_ title: String, hint: String? = nil, gap: CGFloat = AppLayout.subagentEditLabelGap,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.xs) {
                Text(title).font(.nwSans(AppLayout.subagentEditLabelSize, .medium)).foregroundStyle(Color.nw.textSecondary)
                if let hint { Text(hint).font(.nwSans(AppLayout.subagentEditLabelSize)).foregroundStyle(Color.nw.settingsMuted) }
            }.accessibilityElement(children: .combine)
            content()
        }
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

    // MARK: Instructions

    private var instructions: some View {
        let used = model.form.body.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return VStack(alignment: .leading, spacing: AppLayout.subagentEditLabelGap) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Text("Instructions").font(.nwSans(AppLayout.subagentEditLabelSize, .medium)).foregroundStyle(Color.nw.textSecondary)
                Text("Markdown").font(.nwSans(AppLayout.subagentEditHintSize)).foregroundStyle(Color.nw.settingsMuted)
                Spacer(minLength: 0)
                Text("\(used.formatted()) / \(Self.promptLimit.formatted())").font(.nwMono(AppLayout.subagentEditCountSize))
                    .foregroundStyle(used > Self.promptLimit ? Color.nw.failed : Color.nw.settingsMuted)
            }
            InstructionsEditor(text: Binding(get: { model.form.body }, set: { model.form.body = $0 }), saved: "",
                               accessibilityLabel: "Subagent instructions", project: true, plain: true)
                .background(Color.nw.projectEditorBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppLayout.subagentEditFieldRadius))
                .nwBorder(Color.nw.lineStrong, radius: AppLayout.subagentEditFieldRadius)
                .frame(maxHeight: .infinity)
            Text("Saved as a plain .md file with the fields above as YAML at the top. A field Shepherd doesn't know stops the profile from loading, and the list says which one.")
                .font(.nwSans(AppLayout.subagentEditNoteSize)).foregroundStyle(Color.nw.settingsMuted)
                .lineSpacing(AppLayout.subagentEditNoteLineExtra).fixedSize(horizontal: false, vertical: true)
        }
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
            .font(mono ? .nwMono(AppLayout.subagentEditFieldSize) : .nwSans(AppLayout.subagentEditFieldSize))
            .foregroundStyle(Color.nw.textPrimary).tint(Color.nw.lantern)
            .lineSpacing(multiline ? AppLayout.subagentEditDescriptionLineExtra : 0)
            .padding(.horizontal, AppLayout.subagentEditFieldPadding)
            .padding(.top, multiline ? AppLayout.subagentEditDescriptionTop : 0)
            .frame(maxWidth: .infinity, minHeight: multiline ? AppLayout.subagentEditDescriptionHeight : AppLayout.subagentEditFieldHeight,
                   alignment: multiline ? .topLeading : .leading)
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.subagentEditFieldRadius))
            .nwBorder(Color.nw.lineStrong, radius: AppLayout.subagentEditFieldRadius)
            .nwFocusRing(focused, radius: AppLayout.subagentEditFieldRadius)
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
            .nwFocusRing(radius: AppLayout.subagentEditFieldRadius, color: .nw.running)
            .accessibilityLabel(label).accessibilityValue(title)
    }
}

private struct SubagentPopupLabel: View {
    let title: String
    let mono: Bool

    var body: some View {
        HStack(spacing: NW.Space.m) {
            Text(title).font(mono ? .nwMono(AppLayout.subagentEditChipSize) : .nwSans(AppLayout.subagentEditFieldSize))
                .foregroundStyle(Color.nw.textPrimary).lineLimit(mono ? 1 : 2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: AppLayout.subagentEditPopupChevron, weight: .semibold))
                .foregroundStyle(Color.nw.settingsMuted)
        }
        .padding(.horizontal, AppLayout.subagentEditFieldPadding).padding(.vertical, NW.Space.xs)
        .frame(maxWidth: .infinity, minHeight: AppLayout.subagentEditFieldHeight)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.subagentEditFieldRadius))
        .nwBorder(Color.nw.lineStrong, radius: AppLayout.subagentEditFieldRadius)
        .contentShape(Rectangle())
    }
}

/// The model field: the popup's look, opening the composer's searchable model picker, because a
/// proxy such as CLIProxyAPI lists hundreds of models. Typing filters by substring of the id.
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
            .nwFocusRing(radius: AppLayout.subagentEditFieldRadius, color: .nw.running)
            .accessibilityLabel("Model").accessibilityValue(current ?? Self.inherit)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                NWModelPicker(query: $query, sections: Self.sections(choices: choices, query: query, current: current), selection: $selection, onChoose: {
                    choose($0.id.isEmpty ? nil : $0.id)
                    open = false
                }, onClose: { open = false })
                .onDisappear { query = ""; selection = 0 }
            }
    }

    static func sections(choices: [String], query: String, current: String?) -> [NWModelSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? choices : choices.filter { $0.lowercased().contains(q) }
        let options = matches.map { NWModelOption(id: $0, title: $0, isCurrent: $0 == current) }
        let inherit = NWModelOption(id: "", title: Self.inherit, isCurrent: current == nil)
        return [NWModelSection(title: "Models", options: (q.isEmpty ? [inherit] : []) + options)]
    }
}

/// The board's segmented control: unchosen labels in regular weight, the chosen one lifted on the
/// window fill. Drawn here, and a native `Picker` to accessibility.
private struct SubagentSegments: View {
    let label: String
    @Binding var selection: String
    let options: [(String, String)]
    @Namespace private var pill

    var body: some View {
        let M = NWSettingsControlMetrics.self
        HStack(spacing: NW.Space.xxs) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title).font(.nwSans(AppLayout.subagentEditChipSize, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.nw.textPrimary : Color.nw.subagentControlText)
                        .lineLimit(1).padding(.horizontal, M.segmentPadding).frame(height: M.segmentHeight)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: M.segmentRadius).fill(Color.nw.bgWindow)
                                    .shadow(color: Color.nw.knobShadow, radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).nwFocusRing(radius: M.segmentRadius, color: .nw.running)
            }
        }
        .padding(M.segmentTrackPadding)
        .background(Color.nw.lineSubtle, in: RoundedRectangle(cornerRadius: M.segmentTrackRadius))
        .nwComponentAnimation(.content, value: selection)
        .fixedSize()
        .accessibilityRepresentation {
            Picker(label, selection: $selection) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented)
        }
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
                Capsule().fill(isOn ? Color.nw.lantern : Color.nw.lineStrong)
                    .frame(width: AppLayout.subagentEditSwitchWidth, height: AppLayout.subagentEditSwitchHeight)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(isOn ? Color.nw.textOnLantern : Color.nw.textSecondary)
                            .frame(width: AppLayout.subagentEditKnob, height: AppLayout.subagentEditKnob)
                            .padding(AppLayout.subagentEditKnobInset)
                    }
                    .nwComponentAnimation(.content, value: isOn)
                Text(label).font(.nwSans(AppLayout.subagentEditSwitchLabelSize)).foregroundStyle(Color.nw.textPrimary)
                Text(note).font(.nwSans(AppLayout.subagentEditNoteSize)).foregroundStyle(Color.nw.settingsMuted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: NW.Height.controlS).contentShape(Rectangle())
        }
        .buttonStyle(.plain).nwFocusRing(radius: NW.Radius.xs, color: .nw.running)
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
                .font(.nwSans(AppLayout.subagentEditButtonSize, kind == .save ? .semibold : .regular))
                .foregroundStyle(kind == .delete ? Color.nw.failed : kind == .save ? Color.nw.textOnLantern : Color.nw.subagentControlText)
                .padding(.horizontal, kind == .save ? AppLayout.subagentEditSavePadding : AppLayout.subagentEditButtonPadding)
                .frame(height: AppLayout.subagentEditButtonHeight)
                .background(fill(active: active, pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: radius))
                .nwBorder(kind == .delete ? Color.nw.subagentFailureBorder : kind == .revert ? Color.nw.lineStrong : .clear, radius: radius)
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .nwFocusRing(radius: radius, color: .nw.running)
                .nwEnabledOpacity(enabled)
                .onHover { hovering = $0 }
        }

        private func fill(active: Bool, pressed: Bool) -> Color {
            switch kind {
            case .save: pressed ? Color.nw.lanternPressed : active ? Color.nw.lanternHover : Color.nw.lantern
            case .revert: active ? Color.nw.bgHover : Color.nw.bgRaised
            case .delete: active ? Color.nw.subagentFailureTile : .clear
            }
        }
    }
}
