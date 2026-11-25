import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings › Hooks on iPhone and iPad (MobileHooks, MobileHookEdit, MobileHookSources,
// iPadHooks): the fleet's hooks, over `hooks.v1` through the one Mac the app reads (a fleet keeps
// them the same on every Mac). `ClientHooks` keeps the rules and derives the rows; these views only
// draw them.

/// Settings › Hooks: the host's hooks by event, each with its switch, and its Sources. Beside the
/// iPad's list it carries Hooks | Sources itself (iPadHooks); Edit and Add open the form as a sheet.
struct HooksScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn
    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.hooks
        let host = model.host
        let state = host.map { _ in model.state }
        @Bindable var selection = navigator.settingsSelection
        @Bindable var editing = store
        SettingsPageScaffold(SettingsPage.hooks.title, lead: inColumn ? nil : "Commands that run at set points in a thread, on the host where the agent runs. Every hook runs unless you turn it off.", store: nil) {
            if inColumn {
                HStack(spacing: SH.Space.l) {
                    HookSegments(selection: $selection.hooksSources, options: [(false, "Hooks"), (true, "Sources")], label: "Show", pad: true)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                SettingsLead("Commands that run at set points in a thread, on the host where the agent runs. Every hook runs unless you turn it off.")
            }
            if let problem = state?.page?.snapshot.settingsProblem {
                SHBanner(.failed, title: problem)
            } else if let problem = model.problem {
                SHBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.settingsPill)
                }
            }
            if let host, let state {
                content(state, host: host, model: model)
            } else {
                SettingsFootnote("Add a Mac in Settings ▸ Fleet to manage the fleet's hooks.")
            }
        }
        .refreshable { await model.refresh() }
        .shAnimation(.content, value: state)
        .toolbar {
            if !inColumn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sources") { navigator.open(.settings(.hookSources)) }
                    .tint(Color.sh.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add hook", systemImage: "plus") {
                    if let page = state?.page { store.hookEditor = ClientHookEditor(adding: page.snapshot) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .tint(Color.sh.primary)
                .disabled(state?.page == nil)
            }
        }
        .sheet(item: $editing.hookEditor) { editor in
            if let host {
                NavigationStack { HookEditScreen(editor: editor, host: host, hooks: model) { store.hookEditor = nil } }
            }
        }
        .task(id: "\(host?.id.uuidString ?? "")/\(host?.isConnected == true)") { await model.refresh() }
    }

    @ViewBuilder
    private func content(_ state: ClientHooks.State, host: SettingsHost, model: ClientHooks) -> some View {
        switch state {
        case .offline:
            SettingsFootnote("\(host.name) is offline. Its hooks show here once it's back.")
        case .unsupported:
            SettingsFootnote("\(host.name)'s Shepherd is too old to manage hooks from here. Update it to see them.")
        case .loading:
            SHBusyLabel("Reading the hooks…").frame(maxWidth: .infinity)
        case .failed(let reason):
            SettingsFootnote(reason, tone: .failed)
        case .loaded(let page):
            if inColumn && navigator.settingsSelection.hooksSources {
                HookReaders(readers: page.readers) { format, on in Task { await model.setReader(format, on) } }
                HookPadFiles(sections: page.sections)
            } else {
                if !inColumn {
                    SettingsCard { SettingsRow(host.name, trailing: .value(HooksPresentation.hooks(page.groups.reduce(0) { $0 + $1.rows.count })), chevron: false) }
                }
                if page.groups.isEmpty {
                    SettingsFootnote("No hooks yet. Add one, or ask an agent to propose one; Shepherd also reads the hooks in Claude Code's and Codex's files.")
                }
                ForEach(page.groups) { group in
                    HookGroupSection(group: group, pad: inColumn) { row in
                        if let entry = page.entry(slot: row.id) { SettingsStore.of(hosts).hookEditor = ClientHookEditor(editing: entry, in: page.snapshot) }
                    } setOn: { row, on in
                        Task { await model.setOn(row, on) }
                    }
                }
            }
        }
    }
}

/// One event's hooks: its label and name over a card of rows.
private struct HookGroupSection: View {
    let group: HookEventGroup
    let pad: Bool
    let open: (HookRowValue) -> Void
    let setOn: (HookRowValue, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SettingsCaption(group.label, code: group.event)
            SettingsCard {
                ForEach(group.rows) { row in
                    HookRow(row: row, pad: pad, open: { open(row) }, setOn: { setOn(row, $0) })
                }
            }
        }
    }
}

/// A hook: on the phone, the command (mono, wrapping) over its matcher, host and file; on the iPad, the chip,
/// the command over the host and file. The text opens Edit; the switch turns it off.
private struct HookRow: View {
    let row: HookRowValue
    let pad: Bool
    let open: () -> Void
    let setOn: (Bool) -> Void

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Button(action: open) {
                Group {
                    if pad {
                        HStack(spacing: SH.Space.l) {
                            HookChip(text: row.matcher, any: row.matcherIsAny, height: MobileLayout.hookPadChipHeight)
                            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                Text(row.command).font(.shMono(MobileLayout.hookFieldMonoSize)).foregroundStyle(sh.textPrimary).lineLimit(1)
                                    .truncationMode(.tail)
                                Text(row.source).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(row.command).font(.shMono(MobileLayout.settingsNoteSize + 1)).foregroundStyle(sh.textPrimary)
                                .multilineTextAlignment(.leading)
                            Text("\(Text(row.matcher).font(.shMono(MobileLayout.settingsNoteCodeSize))) · \(row.source)")
                                .font(.shSans(MobileLayout.settingsCaptionSize))
                                .foregroundStyle(sh.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.command)
            .accessibilityValue("\(row.matcher), \(row.source)")
            .accessibilityHint("Opens the hook")
            Toggle(row.command, isOn: Binding(get: { row.on }, set: setOn))
                .toggleStyle(.settingsSwitch)
                .labelsHidden()
                .disabled(row.locked)
                .accessibilityHint(row.lockHelp ?? "")
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
    }
}

/// The matcher, mono in a bordered pill (the boards' `gt-tag`); quiet when it matches everything.
struct HookChip: View {
    let text: String
    let any: Bool
    let height: CGFloat

    var body: some View {
        let sh = Color.sh
        Text(text)
            .font(.shMono(MobileLayout.settingsNoteCodeSize).weight(.medium))
            .foregroundStyle(any ? sh.textTertiary : sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.m)
            .frame(height: MobileLayout.hookPadChipHeight)
            .overlay { Capsule().strokeBorder(sh.lineSubtle) }
            .fixedSize()
    }
}

/// Two or more choices on a pill track, the chosen one raised (Form | JSON, Hooks | Sources).
struct HookSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let label: String
    var pad = false

    var body: some View {
        SettingsSegments(label, selection: $selection, options: options)
            .frame(width: pad ? MobileLayout.hookPadSegmentsWidth : nil)
            .shAnimation(.content, value: selection)
    }
}

// MARK: Sources

/// Sources on the phone (MobileHookSources): the readers, then each scope's files with their state.
struct HookSourcesScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.hooks
        let host = model.host
        let page = model.state.page
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                SettingsLead(host.map { "Files \($0.name) reads hooks from. Hooks from every file run together." }
                             ?? "Files a Mac reads hooks from. Hooks from every file run together.")
                if let problem = model.problem {
                    SettingsFootnote(problem, tone: .failed)
                }
                if let page {
                    HookReaders(readers: page.readers) { format, on in Task { await model.setReader(format, on) } }
                    ForEach(page.sections) { section in
                        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                            SettingsCaption(section.name, code: section.root == nil ? "every space" : section.note)
                            SettingsCard {
                                ForEach(section.files) { file in HookFileLine(file: file, path: file.shownPath) }
                            }
                        }
                    }
                } else {
                    SettingsFootnote(host == nil ? "Add a Mac in Settings ▸ Fleet to manage the fleet's hooks." : "The files show here once the hooks are read.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, SH.Space.s)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refresh() }
        .background(Color.sh.bgWindow)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(host?.id.uuidString ?? "")/\(host?.isConnected == true)") { await model.refresh() }
    }
}

/// The Claude Code and Codex readers' switches, with the files each reads.
private struct HookReaders: View {
    let readers: HookSettings.Readers
    let set: (HookFormat, Bool) -> Void

    var body: some View {
        SettingsCard {
            reader("Read Claude Code hooks", paths: ".claude/settings.json", on: readers.claude) { set(.claude, $0) }
            reader("Read Codex hooks", paths: ".codex/hooks.json, config.toml", on: readers.codex) { set(.codex, $0) }
        }
    }

    private func reader(_ title: String, paths: String, on: Bool, toggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                Text(paths).font(.shMono(MobileLayout.settingsNoteCodeSize + 1)).foregroundStyle(Color.sh.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: Binding(get: { on }, set: toggle))
                .toggleStyle(.settingsSwitch)
                .labelsHidden()
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(minHeight: MobileLayout.settingsRowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A hooks file on the phone: its path (mono) over its format and count, its state trailing, a problem
/// under it in `failed`; dimmed while it isn't read.
private struct HookFileLine: View {
    let file: HookFileRow
    let path: String

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(path).font(.shMono(MobileLayout.hookFieldMonoSize)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(file.count == "–" ? file.format : "\(file.format) · \(file.count)")
                    .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary).lineLimit(1)
                if file.tone == .failed {
                    Text(file.state).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(AgentState.failed.textColor).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if file.tone != .failed {
                Text(file.state).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(HookFileState.color(file.tone)).lineLimit(1)
            }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
        .opacity(file.dimmed ? SHListMetrics.dimmedOpacity : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A file's state: a dot and the words, in its tone.
private struct HookFileState: View {
    let file: HookFileRow
    var count = false

    var body: some View {
        let color = Self.color(file.tone)
        HStack(spacing: SH.Space.s) {
            Circle().fill(color).frame(width: MobileLayout.hookDot, height: MobileLayout.hookDot).accessibilityHidden(true)
            Text(count && file.tone == .ok ? "\(file.state) · \(file.count)" : file.state)
                .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(color).lineLimit(2)
        }
    }

    @MainActor static func color(_ tone: HookFileRow.Tone) -> Color {
        switch tone {
        case .ok: Color.sh.textTertiary
        case .off: Color.sh.textTertiary
        case .failed: AgentState.failed.textColor
        }
    }
}

/// Sources beside the iPad's list (iPadHooks): every file read, its format and state.
private struct HookPadFiles: View {
    let sections: [HookScopeSection]

    var body: some View {
        let sh = Color.sh
        SettingsCard {
            ForEach(sections) { section in
                ForEach(section.files) { file in
                    HStack(spacing: SH.Space.l) {
                        Text(section.root == nil ? file.shownPath : "\(section.name)/\(file.shownPath)")
                            .font(.shMono(MobileLayout.settingsNoteSize)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        Text(file.format).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary)
                            .frame(width: MobileLayout.hookPadFormatWidth, alignment: .leading)
                        HookFileState(file: file, count: true)
                            .frame(minWidth: MobileLayout.hookPadStateMinWidth, maxWidth: MobileLayout.hookPadStateWidth, alignment: .leading)
                    }
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.vertical, SH.Space.xs)
                    .frame(minHeight: MobileLayout.hookCompactRowHeight)
                    .opacity(file.dimmed ? SHListMetrics.dimmedOpacity : 1)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: Edit

/// Add hook and Edit hook (MobileHookEdit), as a sheet on the phone and the iPad: Close, the
/// title, Save; Form or JSON; the test runs on the host.
struct HookEditScreen: View {
    @Bindable var editor: ClientHookEditor
    let host: SettingsHost
    let hooks: ClientHooks
    let close: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                HookSegments(selection: $editor.pane, options: [(.form, "Form"), (.json, "JSON")], label: "Edit as")
                if editor.readOnly {
                    SettingsFootnote("This hook is in \(editor.targetFile). Shepherd reads that file but doesn't write it; edit it on \(host.name).")
                }
                if editor.pane == .form { form } else { json }
                if let problem = editor.problem { SettingsFootnote(problem, tone: .failed) }
                if editor.entry != nil, !editor.readOnly {
                    Button("Delete hook") { confirmingDelete = true }
                        .buttonStyle(.settingsLink(.failed))
                        .padding(.horizontal, SH.Space.xs)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, SH.Space.s)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .navigationTitle(editor.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(editor.saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(editor.readOnly ? "Close" : "Cancel", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .tint(Color.sh.textPrimary)
            }
            if !editor.readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await editor.save(with: hooks) { close() } } }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.primary)
                        .disabled(editor.saving)
                }
            }
        }
        .confirmationDialog("Delete this hook?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete hook", role: .destructive) { Task { if await editor.delete(with: hooks) { close() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from \(editor.targetFile) on \(host.name).")
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        SettingsCard {
            fieldRow("When") {
                SettingsPicker("When", selection: editor.event, options: HookEvent.allCases, title: \.label) { editor.event = $0 }
            }
            fieldRow("Saved in") {
                SettingsPicker("Saved in", selection: editor.target, options: editor.targets.map(\.path), title: { path in
                    editor.targets.first { $0.path == path }.map(editor.targetName) ?? path
                }) { editor.target = $0 }
            }
            fieldRow("Matcher") {
                if let hint = editor.event.matcherHint {
                    TextField("Matcher", text: $editor.matcher, prompt: Text(hint).foregroundStyle(Color.sh.textTertiary))
                        .font(.shMono(MobileLayout.hookFieldMonoSize))
                        .foregroundStyle(editor.matcherValid ? Color.sh.textPrimary : AgentState.failed.textColor)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: SH.Height.touch)
                        .accessibilityHint(hint)
                } else {
                    Text("None: runs every time").font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .disabled(editor.readOnly)
        if editor.matchesTools {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SettingsCaption("Matches")
                SHFlowLayout(spacing: SH.Space.s) {
                    ForEach(HookMatcher.agentTools, id: \.self) { tool in
                        HookToolChip(name: tool, hit: editor.matched.contains(tool))
                    }
                }
                .padding(.horizontal, SH.Space.xs)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(editor.matched.isEmpty ? "Matches no built-in tool" : "Matches " + editor.matched.joined(separator: ", "))
            }
        }
        if !editor.matcherValid {
            SettingsFootnote("This isn't a regular expression Shepherd can read.", tone: .failed)
        }
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SettingsCaption("Runs")
            ForEach($editor.handlers) { $handler in
                HookCommandCard(handler: $handler, removable: editor.handlers.count > 1 && !editor.readOnly) { editor.remove(handler.id) }
                    .disabled(editor.readOnly)
            }
            if !editor.readOnly {
                Button("Add another command") { editor.addHandler() }
                    .buttonStyle(.settingsLink)
                    .padding(.horizontal, SH.Space.xs)
            }
        }
        VStack(alignment: .leading, spacing: SH.Space.s) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack(spacing: SH.Space.l) {
                    Text(editor.testing ? "Running on \(host.name)…" : "Test with a sample event")
                        .font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .shShimmer(active: editor.testing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Run") { Task { await editor.test(with: hooks) } }
                        .buttonStyle(.settingsPill)
                        .disabled(editor.testable == nil || editor.testing)
                        .accessibilityHint(editor.testable == nil ? "Enter a command to test it" : "Runs the command once on \(host.name) against a sample \(editor.event.rawValue) event")
                }
                if let result = editor.testResult {
                    HookTestResultCard(outcome: result.outcome, meta: editor.testMeta(result, host: host.name), output: HookTestOutput(result))
                }
            }
            .padding(.horizontal, MobileLayout.settingsRowInset)
            .padding(.vertical, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
            SettingsFootnote("Gets the event as JSON on stdin. Exit 2, or a block decision, stops the call; the reason goes to the agent.")
        }
    }

    private func fieldRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: SH.Space.l) {
            Text(label).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityHidden(true)
            control().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .frame(minHeight: MobileLayout.settingsRowHeight)
    }

    // MARK: JSON

    @ViewBuilder private var json: some View {
        TextEditor(text: $editor.jsonText)
            .font(.shMono(MobileLayout.hookJSONSize))
            .foregroundStyle(Color.sh.textSecondary)
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(SH.Space.l)
            .frame(minHeight: MobileLayout.hookJSONMinHeight)
            .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
            .overlay { RoundedRectangle(cornerRadius: MobileLayout.settingsCardRadius).strokeBorder(editor.jsonError == nil ? .clear : AgentState.failed.textColor) }
            .disabled(editor.readOnly)
            .accessibilityLabel("Hook entry as JSON")
        if let error = editor.jsonError { SettingsFootnote(error, tone: .failed) }
        SettingsFootnote("This entry in \(editor.targetFile) on \(host.name).")
    }
}

/// One command (MobileHookEdit's Runs card): what it runs, its time limit and what the thread says while it
/// runs. A handler the form can't edit (an MCP tool, a prompt) says so; JSON edits it.
private struct HookCommandCard: View {
    @Binding var handler: HookFormHandler
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if handler.type == "command" {
                TextField("Command", text: $handler.command, axis: .vertical)
                    .font(.shMono(MobileLayout.settingsNoteSize + 1))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1...8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Command")
            } else {
                Text(handler.type == "mcp_tool" ? "MCP tool \(handler.server) › \(handler.tool). Edit it in JSON." : "\(handler.type) handler: listed, never run. Edit it in JSON.")
                    .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: SH.Space.l, verticalSpacing: SH.Space.xs) {
                GridRow {
                    Text("Time limit").foregroundStyle(Color.sh.textSecondary)
                        .frame(width: MobileLayout.hookLabelWidth, alignment: .leading)
                    HStack(spacing: SH.Space.xs) {
                        TextField("Time limit", text: $handler.timeout, prompt: Text("60").foregroundStyle(Color.sh.textTertiary))
                            .keyboardType(.decimalPad)
                            .fixedSize()
                        Text("s").foregroundStyle(Color.sh.textPrimary).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Time limit in seconds")
                }
                GridRow {
                    Text("While it runs").foregroundStyle(Color.sh.textSecondary)
                        .frame(width: MobileLayout.hookLabelWidth, alignment: .leading)
                    TextField("Status while it runs", text: $handler.statusMessage, prompt: Text("Shown in the thread").foregroundStyle(Color.sh.textTertiary))
                }
            }
            .font(.shSans(MobileLayout.hookFieldTextSize))
            .foregroundStyle(Color.sh.textPrimary)
            if removable {
                Button("Remove this command", action: remove)
                    .buttonStyle(.settingsLink(.dim))
            }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
    }
}

/// A built-in tool in Matches (the boards' `gt-tag`): ink when the matcher matches it, a hairline when not.
private struct HookToolChip: View {
    let name: String
    let hit: Bool

    var body: some View {
        let sh = Color.sh
        Text(name)
            .font(.shMono(MobileLayout.settingsNoteCodeSize).weight(.medium))
            .foregroundStyle(hit ? sh.textOnPrimary : sh.textSecondary)
            .padding(.horizontal, SH.Space.m)
            .frame(height: MobileLayout.hookPadChipHeight)
            .background(hit ? sh.primary : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(hit ? .clear : sh.lineSubtle) }
    }
}

/// The test's result: the outcome in its color, the run's line under it, ending "on <host>", and
/// what the hook printed in a collapsed Output.
private struct HookTestResultCard: View {
    let outcome: HookOutcome
    let meta: String
    var output: HookTestOutput? = nil
    @State private var outputOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(outcome.summary).font(.sh(.ui)).foregroundStyle(Self.color(outcome)).lineLimit(4)
                Text(meta).font(.shMono(MobileLayout.settingsNoteCodeSize)).foregroundStyle(Color.sh.textTertiary)
            }
            .accessibilityElement(children: .combine)
            if let output {
                DisclosureGroup(isExpanded: $outputOpen) {
                    VStack(alignment: .leading, spacing: SH.Space.m) {
                        ForEach(output.streams) { stream in
                            VStack(alignment: .leading, spacing: SH.Space.xs) {
                                HStack(spacing: SH.Space.s) {
                                    Text(stream.label).font(.shSans(MobileLayout.settingsCaptionSize, .semibold)).foregroundStyle(Color.sh.textSecondary)
                                    if let note = stream.note { Text(note).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textTertiary) }
                                }
                                ScrollView {
                                    Text(stream.text).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(SH.Space.m)
                                }
                                .frame(maxHeight: MobileLayout.hookOutputHeight)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                                .accessibilityLabel(stream.label)
                            }
                        }
                    }
                    .padding(.top, SH.Space.s)
                } label: {
                    Text("Output").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).frame(minHeight: SH.Height.touch)
                }
                .tint(Color.sh.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor static func color(_ outcome: HookOutcome) -> Color {
        switch outcome {
        case .allowed: AgentState.done.textColor
        case .blocked: AgentState.failed.textColor
        case .context: AgentState.running.textColor
        case .ask, .failed, .timedOut: AgentState.attention.textColor
        }
    }
}
