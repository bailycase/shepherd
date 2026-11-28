import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// ProjectResourceEditor: a skill, slash command, subagent or extension as a form. Save changes
/// puts the file in the Resources tab's draft; the page's footer writes it.
struct SpaceResourceEditorView: View {
    @Bindable var model: SpaceResourcesModel
    let project: ProjectsRow
    /// `provider/model` ids for a subagent's Model menu.
    let models: [String]

    private static let thinking = [("", "Use the parent thinking level"), ("off", "Off"), ("minimal", "Minimal"), ("low", "Low"),
                                   ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max")]

    var body: some View {
        if let editor = model.editor {
            let kind = editor.kind
            SpaceSheet(title: "\(editor.isNew ? "New" : "Edit") \(kind.singular)",
                       caption: AnyView(SpaceSheetCaption(text: "\(project.project.name) · This space only", mono: true)),
                       width: kind == .agent ? AppLayout.spaceAgentSheetWidth : AppLayout.spaceEditorSheetWidth,
                       close: { model.editor = nil }, note: editor.destination, noteMono: true) {
                if kind == .extension { extensionFields } else { commonFields(editor) }
                if kind == .agent { agentFields(editor) }
                if kind != .extension {
                    field(kind == .prompt ? "Prompt" : "Instructions", openIn: binding(\.body), file: kind == .prompt ? "prompt.md" : "instructions.md") {
                        SpaceResourceTextArea(label: kind == .prompt ? "Prompt" : "Instructions", text: binding(\.body), mono: true,
                                              height: kind == .agent ? AppLayout.resourceAgentBodyHeight : AppLayout.resourceBodyHeight)
                    }
                }
                if kind == .skill {
                    HStack(spacing: SH.Space.xl) {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text("Use automatically").font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                            Text("When off, load this skill only with its slash command.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Toggle("Use this skill automatically", isOn: binding(\.automatic)).toggleStyle(.shSwitch).labelsHidden()
                    }.padding(.top, SH.Space.xl)
                }
                if kind == .agent { agentOptions(editor) }
                if let error = editor.error {
                    SpaceSheetNote(text: error, failed: true).accessibilityAddTraits(.isStaticText)
                }
            } actions: {
                Button("Cancel") { model.editor = nil }.buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
                Button(editor.isNew ? "Create \(kind.singular)" : "Save changes") { model.saveEditor() }
                    .buttonStyle(SpaceBarStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<SpaceResourcesModel.Editor, Value>) -> Binding<Value> {
        Binding(get: { (model.editor ?? .init(kind: .skill))[keyPath: key] }, set: { model.editor?[keyPath: key] = $0; model.editor?.error = nil })
    }

    private func field<Content: View>(_ label: String, openIn: Binding<String>? = nil, file: String = "draft.txt",
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceSheetLabel(text: label, count: nil) {
                if let openIn { SettingsOpenIn(text: openIn, name: file) }
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two fields side by side (`gspcs-two`).
    private func two<A: View, B: View>(@ViewBuilder _ first: () -> A, @ViewBuilder _ second: () -> B) -> some View {
        HStack(alignment: .top, spacing: SH.Space.xl - SH.Space.xxs) { first(); second() }
    }

    @ViewBuilder private func commonFields(_ editor: SpaceResourcesModel.Editor) -> some View {
        let prompt = editor.kind == .prompt
        two {
            field(prompt ? "Command name" : "Name") {
                // An existing resource keeps its name (its file is named after it): the field reads, never edits.
                SpaceSheetField {
                    TextField(prompt ? "Command name" : "Name", text: Binding(get: { model.editor?.name ?? "" }, set: { name in
                        guard model.editor?.isNew == true else { return }
                        model.editor?.name = name; model.editor?.error = nil
                    }), prompt: Text(verbatim: prompt ? "review" : "ledger-review").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize)).accessibilityLabel(prompt ? "Command name" : "Name")
                }
            }
        } _: {
            field(prompt ? "Arguments" : "Saved in") {
                if prompt {
                    SpaceSheetField {
                        TextField("Argument hint", text: binding(\.arguments), prompt: Text(verbatim: "[focus]").foregroundStyle(Color.sh.textTertiary))
                            .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize))
                    }
                } else {
                    SpaceSheetField(readOnly: true) {
                        Text(editor.destination).font(.shMono(SHCardSheetMetrics.codeSize)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        field("Description", openIn: binding(\.description), file: "description.txt") {
            SpaceResourceTextArea(label: "Resource description", text: binding(\.description), mono: false, height: AppLayout.resourceDescriptionHeight)
        }
    }

    @ViewBuilder private func agentFields(_ editor: SpaceResourcesModel.Editor) -> some View {
        two {
            field("Model") {
                SpaceResourceDropdown(label: "Subagent model", value: binding(\.model),
                                      options: [("", "Use the parent model")] + Array(Set(models + [editor.model].filter { !$0.isEmpty })).sorted().map { ($0, $0) })
            }
        } _: {
            field("Thinking") { SpaceResourceDropdown(label: "Subagent thinking level", value: binding(\.thinking), options: Self.thinking) }
        }
        field("Tools") {
            HStack(spacing: AppLayout.spaceToolsGap) {
                ForEach(SpaceResourcesModel.tools, id: \.self) { tool in
                    Toggle(isOn: Binding(get: { model.editor?.tools.contains(tool) == true }, set: { on in
                        guard var tools = model.editor?.tools else { return }
                        tools.removeAll { $0 == tool }
                        if on { tools = SpaceResourcesModel.tools.filter { tools.contains($0) || $0 == tool } + tools.filter { !SpaceResourcesModel.tools.contains($0) } }
                        model.editor?.tools = tools
                    })) { Text(tool).font(.shMono(SHCardSheetMetrics.codeSize)).foregroundStyle(Color.sh.textPrimary) }.toggleStyle(.shCheckbox)
                }
                Spacer(minLength: 0)
            }.frame(minHeight: AppLayout.spaceSheetFieldHeight).accessibilityElement(children: .contain).accessibilityLabel("Tools")
            SpaceSheetNote(text: "Never more permissions than the parent agent.").padding(.top, -SH.Space.xs)
        }
    }

    @ViewBuilder private func agentOptions(_ editor: SpaceResourcesModel.Editor) -> some View {
        two {
            field("Starts with") {
                SpaceResourceDropdown(label: "Subagent starting context", value: binding(\.context),
                                      options: [("fresh", "Fresh context"), ("fork", "Copy of the parent thread")])
            }
        } _: {
            field("System instructions") {
                SpaceResourceDropdown(label: "Subagent system prompt mode", value: binding(\.promptMode),
                                      options: [("append", "Add to the default system prompt"), ("replace", "Replace the system prompt")])
            }
        }
        HStack {
            Text("Read the space's instructions").font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
            Spacer(minLength: 0)
            Toggle("Read the space's instructions", isOn: binding(\.inheritContext)).toggleStyle(.shSwitch).labelsHidden()
        }.padding(.top, SH.Space.xl)
    }

    @ViewBuilder private var extensionFields: some View {
        field("Extension file") {
            HStack(spacing: SH.Space.m) {
                SpaceSheetField(dim: true) {
                    TextField("Extension file", text: binding(\.file), prompt: Text(verbatim: "extensions/outbox-guard.ts").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize)).disabled(true)
                }
                Button("Choose file") { choose() }.buttonStyle(SpaceLinkStyle(tone: .strong))
            }
            SpaceSheetNote(text: "Paths are relative to the project's .pi folder. Extensions execute code on the space's host.")
        }
    }

    /// Reads a .ts or .js file of up to 64 KiB on this Mac; Save changes copies it into the space.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ts", "js"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            model.editor?.error = "Choose a .ts or .js file of up to 64 KiB."
            return
        }
        model.editor?.file = "extensions/" + url.lastPathComponent
        model.editor?.fileText = text
        model.editor?.error = nil
    }
}

struct SpaceResourceCloseButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.shSans(SHSettingsControlMetrics.popupChevronSize, .semibold)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.spaceSheetClose, height: AppLayout.spaceSheetClose)
                .background(Color.sh.bgHover, in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).shFocusRing(radius: AppLayout.spaceSheetClose / 2, color: .sh.running).accessibilityLabel(label)
    }
}

/// A multi-line field (`gspcs-area`): a 1pt line at radius 8, 8pt over 10pt inside.
struct SpaceResourceTextArea: View {
    let label: String
    @Binding var text: String
    let mono: Bool
    let height: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? .shMono(SHTextStyle.caption.size) : .sh(.ui)).foregroundStyle(Color.sh.textPrimary)
            .scrollContentBackground(.hidden).focused($focused)
            .padding(.horizontal, AppLayout.spaceSheetFieldSides - SH.Space.xs).padding(.vertical, SH.Space.xs)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(focused ? Color.sh.textSecondary : Color.sh.lineSubtle) }
            .shFocusRing(focused, radius: SH.Radius.m)
            .accessibilityLabel(label)
    }
}

/// A menu field in a sheet (`gspcs-fld` with chevrons) on a native menu.
struct SpaceResourceDropdown: View {
    let label: String
    @Binding var value: String
    let options: [(String, String)]

    var body: some View {
        let title = options.first { $0.0 == value }?.1 ?? value
        Menu {
            ForEach(options, id: \.0) { option in Button(option.1) { value = option.0 } }
        } label: {
            SpaceSheetField {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                SHGlyph.popupChevrons.image.font(.shSans(SHSettingsControlMetrics.popupChevronSize)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(label).accessibilityValue(title)
    }
}

/// Add from repo (ProjectSkillAdd): look the repository up, tick skills, copy them into `.pi/skills`.
struct SpaceSkillInstallView: View {
    @Bindable var model: SpaceResourcesModel
    let project: ProjectsRow

    var body: some View {
        if let state = model.install {
            SpaceSheet(title: "Add skills to \(project.project.name)", width: AppLayout.spaceInstallSheetWidth, close: { model.install = nil },
                       note: "Global Skills stays unchanged.") {
                SpaceSheetLabel("Repository URL")
                SpaceSheetField {
                    TextField("Skills repository URL", text: Binding(get: { state.repository }, set: {
                        model.install?.repository = $0; model.install?.candidates = nil; model.install?.selected = []; model.install?.error = nil
                    }), prompt: Text(verbatim: "https://github.com/owner/skills").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize))
                }
                SpaceSheetLabel("Revision")
                SpaceSheetField {
                    TextField("Skills repository revision", text: Binding(get: { state.revision }, set: { model.install?.revision = $0 }),
                              prompt: Text(verbatim: "Branch, tag or commit").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize))
                }
                SpaceSheetLabel(text: "Preview skills", count: state.candidates.map { "\($0.count) skill\($0.count == 1 ? "" : "s") found" ?? "" }) {
                    Button(state.busy ? "Looking…" : "Look up") { Task { await model.preview() } }.buttonStyle(SpaceLinkStyle(tone: .strong, caption: true)).accessibilityLabel("Preview skills")
                        .disabled(state.busy || state.repository.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let candidates = state.candidates, !candidates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(candidates) { skill in
                            HStack(spacing: SH.Space.l - SH.Space.xxs) {
                                Toggle(skill.name, isOn: Binding(get: { model.install?.selected.contains(skill.path) == true }, set: { on in
                                    if on { model.install?.selected.insert(skill.path) } else { model.install?.selected.remove(skill.path) }
                                })).toggleStyle(.shCheckbox).font(.sh(.ui, weight: .medium)).frame(width: AppLayout.spaceSkillNameWidth, alignment: .leading)
                                Text(skill.summary).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: AppLayout.spaceSheetFieldHeight + SH.Space.xxs)
                            if skill.id != candidates.last?.id { SHHairline() }
                        }
                    }.padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.xs)
                        .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(Color.sh.lineSubtle) }
                }
                if let error = state.error { SpaceSheetNote(text: error, failed: true) }
                Text("Destination · \(project.project.displayPath)/.pi/skills").font(.shMono(SHTextStyle.caption.size)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.top, SH.Space.xl)
            } actions: {
                Button("Cancel") { model.install = nil }.buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
                Button(state.busy ? "Adding…" : "Add \(state.selected.count) skill\(state.selected.count == 1 ? "" : "s")") { Task { await model.installSelected() } }
                    .buttonStyle(SpaceBarStyle(kind: .primary)).disabled(state.busy || state.selected.isEmpty)
            }
        }
    }
}
