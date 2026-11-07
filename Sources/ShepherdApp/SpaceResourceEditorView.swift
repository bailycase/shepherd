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
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.l) {
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text("\(editor.isNew ? "New" : "Edit") \(kind.singular)").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(project.project.name) · This space only").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                    Spacer(minLength: 0)
                    SpaceResourceCloseButton(label: "Close resource editor") { model.editor = nil }
                }.padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.xl)
                SHHairline(color: Color.sh.lineSubtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.Space.xl) {
                        if kind == .extension { extensionFields } else { commonFields(editor) }
                        if kind == .agent { agentFields(editor) }
                        if kind != .extension {
                            field(kind == .prompt ? "Prompt" : "Instructions") {
                                SpaceResourceTextArea(label: kind == .prompt ? "Prompt" : "Instructions", text: binding(\.body), mono: true,
                                                      height: kind == .agent ? AppLayout.resourceAgentBodyHeight : AppLayout.resourceBodyHeight)
                            }
                        }
                        if kind == .skill {
                            HStack(spacing: SH.Space.l) {
                                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                    Text("Use automatically").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                                    Text("When off, load this skill only with its slash command.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Toggle("Use this skill automatically", isOn: binding(\.automatic)).toggleStyle(.shSwitch).labelsHidden()
                            }
                        }
                        if kind == .agent { agentOptions(editor) }
                        if let error = editor.error {
                            Text(error).font(.sh(.ui)).foregroundStyle(Color.sh.failed).accessibilityAddTraits(.isStaticText)
                        }
                    }.padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.xl)
                }.scrollIndicators(.automatic)
                SHHairline(color: Color.sh.lineSubtle)
                HStack(spacing: SH.Space.m) {
                    Text(editor.destination).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel") { model.editor = nil }.buttonStyle(.sh(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                    Button(editor.isNew ? "Create \(kind.singular)" : "Save changes") { model.saveEditor() }
                        .buttonStyle(.sh(.primary, size: .l)).keyboardShortcut(.defaultAction)
                }.padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.l)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<SpaceResourcesModel.Editor, Value>) -> Binding<Value> {
        Binding(get: { (model.editor ?? .init(kind: .skill))[keyPath: key] }, set: { model.editor?[keyPath: key] = $0; model.editor?.error = nil })
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(label).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func commonFields(_ editor: SpaceResourcesModel.Editor) -> some View {
        let prompt = editor.kind == .prompt
        HStack(alignment: .top, spacing: SH.Space.xl) {
            field(prompt ? "Command name" : "Name") {
                // An existing resource keeps its name (its file is named after it): the field reads, never edits.
                TextField(prompt ? "Command name" : "Name", text: Binding(get: { model.editor?.name ?? "" }, set: { name in
                    guard model.editor?.isNew == true else { return }
                    model.editor?.name = name; model.editor?.error = nil
                }), prompt: Text(verbatim: prompt ? "review" : "ledger-review"))
                    .textFieldStyle(.sh(mono: true))
            }
            field(prompt ? "Arguments" : "Saved in") {
                if prompt {
                    TextField("Argument hint", text: binding(\.arguments), prompt: Text(verbatim: "[focus]")).textFieldStyle(.sh(mono: true))
                } else {
                    Text(editor.destination).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                        .frame(minHeight: SH.Height.controlL, alignment: .leading)
                }
            }
        }
        field("Description") {
            SpaceResourceTextArea(label: "Resource description", text: binding(\.description), mono: false, height: AppLayout.resourceDescriptionHeight)
        }
    }

    @ViewBuilder private func agentFields(_ editor: SpaceResourcesModel.Editor) -> some View {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            field("Model") {
                SpaceResourceDropdown(label: "Subagent model", value: binding(\.model),
                                      options: [("", "Use the parent model")] + Array(Set(models + [editor.model].filter { !$0.isEmpty })).sorted().map { ($0, $0) })
            }
            field("Thinking") { SpaceResourceDropdown(label: "Subagent thinking level", value: binding(\.thinking), options: Self.thinking) }
        }
        field("Tools") {
            HStack(spacing: SH.Space.xs) {
                ForEach(SpaceResourcesModel.tools, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(get: { model.editor?.tools.contains(tool) == true }, set: { on in
                        guard var tools = model.editor?.tools else { return }
                        tools.removeAll { $0 == tool }
                        if on { tools = SpaceResourcesModel.tools.filter { tools.contains($0) || $0 == tool } + tools.filter { !SpaceResourcesModel.tools.contains($0) } }
                        model.editor?.tools = tools
                    })).toggleStyle(.shCheckbox).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary)
                        .frame(width: AppLayout.resourceToolWidth, height: SH.Height.controlL, alignment: .leading)
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("Tools")
            Text("Never more permissions than the parent agent.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
    }

    @ViewBuilder private func agentOptions(_ editor: SpaceResourcesModel.Editor) -> some View {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            field("Starts with") {
                SpaceResourceDropdown(label: "Subagent starting context", value: binding(\.context),
                                      options: [("fresh", "Fresh context"), ("fork", "Copy of the parent thread")])
            }
            field("System instructions") {
                SpaceResourceDropdown(label: "Subagent system prompt mode", value: binding(\.promptMode),
                                      options: [("append", "Add to the default system prompt"), ("replace", "Replace the system prompt")])
            }
        }
        HStack {
            Text("Read the space's instructions").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: 0)
            Toggle("Read the space's instructions", isOn: binding(\.inheritContext)).toggleStyle(.shSwitch).labelsHidden()
        }
    }

    @ViewBuilder private var extensionFields: some View {
        field("Extension file") {
            HStack(spacing: SH.Space.m) {
                TextField("Extension file", text: binding(\.file), prompt: Text(verbatim: "extensions/outbox-guard.ts"))
                    .textFieldStyle(.sh(mono: true)).disabled(true)
                Button("Choose file") { choose() }.buttonStyle(.sh(.secondary, size: .l))
            }
            Text("Paths are relative to the project's .pi folder. Extensions execute code on the space's host.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
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
            Image(systemName: "xmark").font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                .frame(width: SH.Height.controlL, height: SH.Height.controlL)
                .background(Color.sh.bgWindow, in: Circle()).overlay(Circle().stroke(Color.sh.lineStrong))
                .contentShape(Circle())
        }.buttonStyle(.plain).shFocusRing(radius: SH.Height.controlL / 2, color: .sh.running).accessibilityLabel(label)
    }
}

/// A multi-line field drawn as the boards' settings field.
struct SpaceResourceTextArea: View {
    let label: String
    @Binding var text: String
    let mono: Bool
    let height: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? .sh(.code) : .sh(.body)).foregroundStyle(Color.sh.textPrimary)
            .scrollContentBackground(.hidden).focused($focused)
            .padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
            .shFocusRing(focused, radius: SH.Radius.s)
            .accessibilityLabel(label)
    }
}

/// The boards' dropdown on a native menu.
struct SpaceResourceDropdown: View {
    let label: String
    @Binding var value: String
    let options: [(String, String)]

    var body: some View {
        let title = options.first { $0.0 == value }?.1 ?? value
        Menu {
            ForEach(options, id: \.0) { option in Button(option.1) { value = option.0 } }
        } label: {
            HStack(spacing: SH.Space.m) {
                Text(title).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                SHGlyph.popupChevrons.image.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            }.padding(.horizontal, SH.Space.l).frame(maxWidth: .infinity, minHeight: SHSettingsControlMetrics.controlHeight)
                .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SHSettingsControlMetrics.radius))
                .shBorder(Color.sh.lineStrong, radius: SHSettingsControlMetrics.radius)
                .contentShape(Rectangle())
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
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                HStack(spacing: SH.Space.l) {
                    Text("Add skills to \(project.project.name)").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SpaceResourceCloseButton(label: "Cancel skill install") { model.install = nil }
                }
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text("Repository URL").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                    TextField("Skills repository URL", text: Binding(get: { state.repository }, set: {
                        model.install?.repository = $0; model.install?.candidates = nil; model.install?.selected = []; model.install?.error = nil
                    }), prompt: Text(verbatim: "https://github.com/owner/skills")).textFieldStyle(.sh(mono: true))
                }
                HStack(alignment: .bottom, spacing: SH.Space.xl) {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text("Revision").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                        TextField("Skills repository revision", text: Binding(get: { state.revision }, set: { model.install?.revision = $0 }),
                                  prompt: Text(verbatim: "Branch, tag or commit")).textFieldStyle(.sh(mono: true))
                    }.frame(maxWidth: .infinity)
                    Button("Preview skills") { Task { await model.preview() } }.buttonStyle(.sh(.secondary, size: .l))
                        .disabled(state.busy || state.repository.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let candidates = state.candidates, !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: SH.Space.m) {
                        ForEach(candidates) { skill in
                            HStack(spacing: SH.Space.l) {
                                Toggle(skill.name, isOn: Binding(get: { model.install?.selected.contains(skill.path) == true }, set: { on in
                                    if on { model.install?.selected.insert(skill.path) } else { model.install?.selected.remove(skill.path) }
                                })).toggleStyle(.shCheckbox).font(.sh(.body)).frame(width: AppLayout.resourceFromWidth + SH.Space.xxxl + SH.Space.m, alignment: .leading)
                                Text(skill.summary).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                            }
                        }
                    }.padding(SH.Space.l).shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                }
                if let error = state.error { Text(error).font(.sh(.ui)).foregroundStyle(Color.sh.failed) }
                Text("Destination · \(project.project.displayPath)/.pi/skills").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                HStack(spacing: SH.Space.m) {
                    Text("Global Skills stays unchanged.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel") { model.install = nil }.buttonStyle(.sh(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                    Button(state.busy ? "Adding…" : "Add \(state.selected.count) skill\(state.selected.count == 1 ? "" : "s")") { Task { await model.installSelected() } }
                        .buttonStyle(.sh(.primary, size: .l)).disabled(state.busy || state.selected.isEmpty)
                }
            }.padding(SH.Space.xxl)
        }
    }
}
