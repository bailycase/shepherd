import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings › Hooks on iPhone and iPad (MobileHooks, MobileHookEdit, MobileHookSources, iPadHooks;
// docs/hooks.md): one host's hooks at a time, over `hooks.v1`. Hooks run on the host where the
// agent runs, so every read, change and test goes to that host. `ClientHooks` keeps the rules
// and derives the rows; these views only draw them.

/// Settings › Hooks: the host's hooks by event, each with its switch, and its Sources. Beside the
/// iPad's list it carries Hooks | Sources itself (iPadHooks); Edit and Add open the form as a sheet.
struct HooksScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn
    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.hooks
        let host = ClientHooks.host(chosen: navigator.settingsSelection.hooksHost, in: store.hosts)
        let state = host.map(model.state(of:))
        @Bindable var selection = navigator.settingsSelection
        @Bindable var editing = store
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if inColumn {
                    HStack(spacing: SH.Space.l) {
                        HookSegments(selection: $selection.hooksSources, options: [(false, "Hooks"), (true, "Sources")], label: "Show", pad: true)
                            .fixedSize()
                        Spacer(minLength: 0)
                        if let host { HookHostMenu(store: store, host: host, pad: true, count: nil) }
                    }
                }
                Text(inColumn ? "Hooks on \(host?.name ?? "this host"). They run where the agent runs; every hook runs unless you turn it off."
                              : "Commands that run at set points in a thread, on the host where the agent runs. Every hook runs unless you turn it off.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if !inColumn, let host { HookHostMenu(store: store, host: host, pad: false, count: state?.page?.hookCount) }
                if let host, let problem = model.problem(of: host) {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem(of: host) }.buttonStyle(.sh(.secondary))
                    }
                }
                if let host, let state {
                    content(state, host: host, model: model)
                } else {
                    SettingsFootnote("Add a host in Settings ▸ Hosts to manage its hooks.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { if let host { await model.refresh(host) } }
        .background(Color.sh.bgWindow)
        .shAnimation(.content, value: state)
        .navigationTitle(SettingsPage.hooks.title)
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add hook", systemImage: "plus") {
                    if let page = state?.page { store.hookEditor = ClientHookEditor(adding: page.snapshot) }
                }
                .disabled(state?.page == nil)
            }
        }
        .sheet(item: $editing.hookEditor) { editor in
            if let host {
                NavigationStack { HookEditScreen(editor: editor, host: host, hooks: model) { store.hookEditor = nil } }
            }
        }
        .task(id: "\(host?.id.uuidString ?? "")/\(host?.isConnected == true)") { if let host { await model.refresh(host) } }
    }

    @ViewBuilder
    private func content(_ state: ClientHooks.State, host: SettingsHost, model: ClientHooks) -> some View {
        switch state {
        case .offline:
            SettingsFootnote("\(host.name) is offline. Its hooks show here once it's back.")
        case .unsupported:
            SettingsFootnote("\(host.name)'s Shepherd is too old to manage hooks from here. Update it to see them.")
        case .loading:
            ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
        case .failed(let reason):
            SettingsFootnote(reason, tone: .failed)
        case .loaded(let page):
            if inColumn && navigator.settingsSelection.hooksSources {
                HookReaders(readers: page.readers) { format, on in Task { await model.setReader(format, on, host: host) } }
                HookPadFiles(sections: page.sections)
            } else {
                if page.groups.isEmpty {
                    SettingsFootnote("No hooks on \(host.name) yet. Add one, or ask an agent to propose one; Shepherd also reads the hooks in Claude Code's and Codex's files.")
                }
                ForEach(page.groups) { group in
                    HookGroupSection(group: group, pad: inColumn) { row in
                        if let entry = page.entry(slot: row.id) { SettingsStore.of(hosts).hookEditor = ClientHookEditor(editing: entry, in: page.snapshot) }
                    } setOn: { row, on in
                        Task { await model.setOn(row, on, host: host) }
                    }
                }
                if !inColumn {
                    SHListCard {
                        Button { navigator.open(.settings(.hookSources)) } label: {
                            SHListRow("Sources", trailing: .value(HooksPresentation.files(page.fileCount)))
                        }
                        .buttonStyle(.shRow(radius: 0))
                    }
                }
            }
        }
    }
}

/// The host whose hooks the page shows, among the hosts that serve them: the phone's full-width
/// row with its hook count, or the iPad's bordered button.
private struct HookHostMenu: View {
    let store: SettingsStore
    let host: SettingsHost
    let pad: Bool
    /// The phone's count beside the name, once read.
    let count: Int?
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let sh = Color.sh
        Menu {
            ForEach(ClientHooks.hosts(store.hosts)) { other in
                Button { navigator.settingsSelection.hooksHost = other.id } label: {
                    if other.id == host.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                }
            }
        } label: {
            HStack(spacing: SH.Space.m) {
                if !pad {
                    Image(systemName: SettingsPage.hosts.symbol).font(.sh(.ui)).foregroundStyle(sh.textSecondary).accessibilityHidden(true)
                }
                Text(host.name).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if !pad {
                    Spacer(minLength: SH.Space.m)
                }
                if !pad, let count {
                    Text(HooksPresentation.hooks(count)).font(.shSans(MobileLayout.hookCountSize)).foregroundStyle(sh.textTertiary)
                }
                Image(systemName: "chevron.down").font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.textTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: pad ? nil : .infinity, minHeight: SH.Height.touch)
            .background(pad ? sh.bgRaised : sh.bgSunken, in: RoundedRectangle(cornerRadius: pad ? SH.Radius.m : SH.Radius.l))
            .shBorder(pad ? sh.lineStrong : sh.lineSubtle, radius: pad ? SH.Radius.m : SH.Radius.l)
            .contentShape(Rectangle())
        }
        .disabled(ClientHooks.hosts(store.hosts).count < 2)
        .accessibilityLabel("Host: \(host.name)")
        .accessibilityValue(count.map(HooksPresentation.hooks) ?? "")
    }
}

/// One event's hooks: its label and name over a card of rows.
private struct HookGroupSection: View {
    let group: HookEventGroup
    let pad: Bool
    let open: (HookRowValue) -> Void
    let setOn: (HookRowValue, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(group.label).font(.shSans(MobileLayout.hookHeadSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                Text(group.event).font(.shMono(MobileLayout.hookEventSize)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            SHListCard {
                ForEach(group.rows) { row in
                    HookRow(row: row, pad: pad, open: { open(row) }, setOn: { setOn(row, $0) })
                }
            }
        }
    }
}

/// A hook: on the phone, two lines of command over its matcher chip and source; on the iPad, the
/// chip, the command, the source in a column. The text opens Edit; the switch turns it off.
private struct HookRow: View {
    let row: HookRowValue
    let pad: Bool
    let open: () -> Void
    let setOn: (Bool) -> Void

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Button(action: open) {
                Group {
                    if pad {
                        HStack(spacing: SH.Space.l) {
                            HookChip(text: row.matcher, any: row.matcherIsAny, height: MobileLayout.hookPadChipHeight)
                            Text(row.command).font(.sh(.code)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.shortSource).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                                .frame(width: MobileLayout.hookPadSourceWidth, alignment: .trailing)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: SH.Space.xs) {
                            Text(row.command).font(.sh(.code)).foregroundStyle(sh.textPrimary).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: SH.Space.s) {
                                HookChip(text: row.matcher, any: row.matcherIsAny, height: MobileLayout.hookChipHeight)
                                Text(row.source).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                            }
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
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .disabled(row.locked)
                .frame(minWidth: SH.Height.touch, minHeight: SH.Height.touch)
                .accessibilityHint(row.lockHelp ?? "")
        }
        .padding(.leading, SH.Space.xl)
        .padding(.trailing, SH.Space.m)
        .padding(.vertical, pad ? SH.Space.xs : SH.Space.m)
        .frame(minHeight: pad ? MobileLayout.hookCompactRowHeight : MobileLayout.hookRowHeight)
    }
}

/// The matcher, mono in a bordered chip; dashed and quiet when it matches everything.
struct HookChip: View {
    let text: String
    let any: Bool
    let height: CGFloat

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xs)
        Text(text)
            .font(.shMono(MobileLayout.hookChipTextSize))
            .foregroundStyle(any ? sh.textTertiary : sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.s)
            .frame(height: height)
            .background(sh.bgWindow, in: shape)
            .overlay {
                if any {
                    shape.strokeBorder(sh.lineStrong, style: StrokeStyle(lineWidth: 1, dash: MobileLayout.hookChipDash))
                } else {
                    shape.strokeBorder(sh.lineStrong, lineWidth: 1)
                }
            }
            .fixedSize()
    }
}

/// Two or more choices on a sunken track, the chosen one raised (Form | JSON, Hooks | Sources).
struct HookSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let label: String
    var pad = false

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.shSans(pad ? MobileLayout.hookPadSegmentTextSize : MobileLayout.hookSegmentTextSize))
                        .foregroundStyle(selection == value ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, pad ? SH.Space.l : 0)
                        .frame(maxWidth: pad ? nil : .infinity, minHeight: pad ? MobileLayout.hookPadSegmentHeight : MobileLayout.hookSegmentHeight)
                        .background(selection == value ? sh.bgRaised : .clear, in: RoundedRectangle(cornerRadius: MobileLayout.hookSegmentRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(SH.Space.xxs)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: MobileLayout.hookSegmentTrackRadius))
        .shBorder(sh.lineSubtle, radius: MobileLayout.hookSegmentTrackRadius)
        .shAnimation(.content, value: selection)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.0) { value, title in Text(title).tag(value) }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: Sources

/// Sources on the phone (MobileHookSources): the readers, then each scope's files with their state.
struct HookSourcesScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.hooks
        let host = ClientHooks.host(chosen: navigator.settingsSelection.hooksHost, in: store.hosts)
        let page = host.flatMap { model.state(of: $0).page }
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text("Files \(host?.name ?? "the host") reads hooks from. Hooks from every file run together.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if let host, let problem = model.problem(of: host) {
                    SettingsFootnote(problem, tone: .failed)
                }
                if let host, let page {
                    HookReaders(readers: page.readers) { format, on in Task { await model.setReader(format, on, host: host) } }
                    ForEach(page.sections) { section in
                        VStack(alignment: .leading, spacing: SH.Space.s) {
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                                Text(section.name).font(.shSans(MobileLayout.hookHeadSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                                Text(section.root == nil ? "every space" : section.note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, SH.Space.xs)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            SHListCard {
                                ForEach(section.files) { file in HookFileLine(file: file, path: file.shownPath) }
                            }
                        }
                    }
                } else {
                    SettingsFootnote(host.map { "\($0.name)'s files show here once its hooks are read." } ?? "Add a host in Settings ▸ Hosts to manage its hooks.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, SH.Space.s)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { if let host { await model.refresh(host) } }
        .background(Color.sh.bgWindow)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(host?.id.uuidString ?? "")/\(host?.isConnected == true)") { if let host { await model.refresh(host) } }
    }
}

/// The Claude Code and Codex readers' switches, with the files each reads.
private struct HookReaders: View {
    let readers: HookSettings.Readers
    let set: (HookFormat, Bool) -> Void

    var body: some View {
        SHListCard {
            reader("Read Claude Code hooks", paths: ".claude/settings.json", on: readers.claude) { set(.claude, $0) }
            reader("Read Codex hooks", paths: ".codex/hooks.json, config.toml", on: readers.codex) { set(.codex, $0) }
        }
    }

    private func reader(_ title: String, paths: String, on: Bool, toggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                Text(paths).font(.shMono(MobileLayout.hookEventSize)).foregroundStyle(Color.sh.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: Binding(get: { on }, set: toggle))
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .frame(minWidth: SH.Height.touch, minHeight: SH.Height.touch)
        }
        .padding(.leading, SH.Space.xl)
        .padding(.trailing, SH.Space.m)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: MobileLayout.hookCompactRowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A hooks file on the phone: its path over its state, the format and count trailing; dimmed
/// while it isn't read.
private struct HookFileLine: View {
    let file: HookFileRow
    let path: String

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(path).font(.sh(.code)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                HookFileState(file: file)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.count == "–" ? file.format : "\(file.format) · \(file.count)")
                .font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
        }
        .padding(.leading, SH.Space.xl)
        .padding(.trailing, SH.Space.m)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: MobileLayout.hookCompactRowHeight)
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
                .font(.sh(.caption)).foregroundStyle(color).lineLimit(2)
        }
    }

    @MainActor static func color(_ tone: HookFileRow.Tone) -> Color {
        switch tone {
        case .ok: AgentState.done.textColor
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
        SHListCard {
            ForEach(sections) { section in
                ForEach(section.files) { file in
                    HStack(spacing: SH.Space.l) {
                        Text(section.root == nil ? file.shownPath : "\(section.name)/\(file.shownPath)")
                            .font(.sh(.code)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        Text(file.format).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
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

/// Add hook and Edit hook (MobileHookEdit), as a sheet on the phone and the iPad: Cancel, the
/// title, Save; Form or JSON; the test runs on the host.
struct HookEditScreen: View {
    @Bindable var editor: ClientHookEditor
    let host: SettingsHost
    let hooks: ClientHooks
    let close: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                HookSegments(selection: $editor.pane, options: [(.form, "Form"), (.json, "JSON")], label: "Edit as")
                if editor.readOnly {
                    SettingsFootnote("This hook is in \(editor.targetFile). Shepherd reads that file but doesn't write it; edit it on \(host.name).")
                }
                if editor.pane == .form { form } else { json }
                if let problem = editor.problem { SettingsFootnote(problem, tone: .failed) }
                if editor.entry != nil, !editor.readOnly {
                    Button { confirmingDelete = true } label: {
                        Text("Delete hook").font(.sh(.ui)).foregroundStyle(AgentState.failed.textColor)
                            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                    }
                    .buttonStyle(.shRow(radius: SH.Radius.m))
                    .hookButtonChrome()
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
                Button(editor.readOnly ? "Close" : "Cancel", action: close)
                    .tint(Color.sh.textPrimary)
            }
            if !editor.readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await editor.save(with: hooks, host: host) { close() } } }
                        .fontWeight(.semibold)
                        .tint(Color.sh.lanternText)
                        .disabled(editor.saving)
                }
            }
        }
        .confirmationDialog("Delete this hook?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete hook", role: .destructive) { Task { if await editor.delete(with: hooks, host: host) { close() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from \(editor.targetFile) on \(host.name).")
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        SHListCard {
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
                    Text("None: runs every time").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .disabled(editor.readOnly)
        if editor.matchesTools {
            SHFlowLayout(spacing: SH.Space.xs) {
                Text("Matches").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.trailing, SH.Space.xs)
                ForEach(HookMatcher.agentTools, id: \.self) { tool in
                    HookToolChip(name: tool, hit: editor.matched.contains(tool))
                }
            }
            .padding(.horizontal, SH.Space.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(editor.matched.isEmpty ? "Matches no built-in tool" : "Matches " + editor.matched.joined(separator: ", "))
        }
        if !editor.matcherValid {
            SettingsFootnote("This isn't a regular expression Shepherd can read.", tone: .failed)
        }
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Runs").font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.textSecondary).padding(.horizontal, SH.Space.xs)
            ForEach($editor.handlers) { $handler in
                HookCommandCard(handler: $handler, removable: editor.handlers.count > 1 && !editor.readOnly) { editor.remove(handler.id) }
                    .disabled(editor.readOnly)
            }
            if !editor.readOnly {
                Button("+ Add another command") { editor.addHandler() }
                    .font(.sh(.ui))
                    .foregroundStyle(AgentState.running.textColor)
                    .padding(.horizontal, SH.Space.xs)
                    .frame(minHeight: SH.Height.touch)
            }
        }
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Button { Task { await editor.test(with: hooks, host: host) } } label: {
                HStack(spacing: SH.Space.m) {
                    if editor.testing { ProgressView().progressViewStyle(SHSpinnerStyle()) }
                    Text(editor.testing ? "Running on \(host.name)…" : "Test with a sample event")
                }
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
            }
            .buttonStyle(.shRow(radius: SH.Radius.m))
            .hookButtonChrome()
            .disabled(editor.testable == nil || editor.testing)
            .accessibilityHint(editor.testable == nil ? "Enter a command to test it" : "Runs the command once on \(host.name) against a sample \(editor.event.rawValue) event")
            if let result = editor.testResult {
                HookTestResultCard(outcome: result.outcome, meta: editor.testMeta(result, host: host.name))
            }
        }
        SettingsFootnote("Gets the event as JSON on stdin. Exit 2, or a block decision, stops the call; the reason goes to the agent.")
    }

    private func fieldRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: SH.Space.l) {
            Text(label).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: MobileLayout.hookLabelWidth, alignment: .leading)
                .accessibilityHidden(true)
            control().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, SH.Space.xl)
        .padding(.trailing, SH.Space.l)
        .frame(minHeight: MobileLayout.hookFieldRowHeight)
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
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
            .shBorder(editor.jsonError == nil ? Color.sh.lineSubtle : AgentState.failed.textColor, radius: SHListMetrics.cardRadius)
            .disabled(editor.readOnly)
            .accessibilityLabel("Hook entry as JSON")
        if let error = editor.jsonError { SettingsFootnote(error, tone: .failed) }
        SettingsFootnote("This entry in \(editor.targetFile) on \(host.name).")
    }
}

/// One command: what it runs, its time limit and what the thread says while it runs. A handler
/// the form can't edit (an MCP tool, a prompt) says so; JSON edits it.
private struct HookCommandCard: View {
    @Binding var handler: HookFormHandler
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if handler.type == "command" {
                TextField("Command", text: $handler.command, axis: .vertical)
                    .font(.shMono(MobileLayout.hookFieldMonoSize))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(2...8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.m)
                    .frame(minHeight: MobileLayout.hookCommandMinHeight, alignment: .topLeading)
                    .hookFieldChrome()
                    .accessibilityLabel("Command")
            } else {
                Text(handler.type == "mcp_tool" ? "MCP tool \(handler.server) › \(handler.tool). Edit it in JSON." : "\(handler.type) handler: listed, never run. Edit it in JSON.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: SH.Space.m) {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text("Time limit").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    HStack(spacing: SH.Space.xs) {
                        TextField("Time limit", text: $handler.timeout, prompt: Text("60").foregroundStyle(Color.sh.textTertiary))
                            .font(.shMono(MobileLayout.hookFieldMonoSize))
                            .keyboardType(.decimalPad)
                        Text("s").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(minHeight: SH.Height.touch)
                    .hookFieldChrome()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Time limit in seconds")
                }
                .frame(width: MobileLayout.hookLabelWidth)
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text("While it runs").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    TextField("Status while it runs", text: $handler.statusMessage, prompt: Text("Shown in the thread").foregroundStyle(Color.sh.textTertiary))
                        .font(.sh(.ui))
                        .padding(.horizontal, SH.Space.l)
                        .frame(minHeight: SH.Height.touch)
                        .hookFieldChrome()
                }
            }
            if removable {
                Button("Remove this command", action: remove)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(minHeight: SH.Height.touch)
            }
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
        .shBorder(Color.sh.lineSubtle, radius: SHListMetrics.cardRadius)
    }
}

/// A built-in tool in Matches: lit in `running` when the matcher matches it.
private struct HookToolChip: View {
    let name: String
    let hit: Bool

    var body: some View {
        let sh = Color.sh
        Text(name)
            .font(.shMono(MobileLayout.hookChipTextSize))
            .foregroundStyle(hit ? sh.textPrimary : sh.textTertiary)
            .padding(.horizontal, SH.Space.s)
            .frame(height: MobileLayout.hookPadChipHeight)
            .background(hit ? (AgentState.running.tint ?? .clear) : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(hit ? AgentState.running.color : sh.lineSubtle, radius: SH.Radius.xs)
    }
}

/// The test's result: the outcome in its color, the run's line under it, ending "on <host>".
private struct HookTestResultCard: View {
    let outcome: HookOutcome
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text(outcome.summary).font(.sh(.ui, weight: .medium)).foregroundStyle(Self.color(outcome)).lineLimit(4)
            Text(meta).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
        .shBorder(Color.sh.lineSubtle, radius: SHListMetrics.cardRadius)
        .accessibilityElement(children: .combine)
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

private extension View {
    /// The edit form's field: the window's fill, a strong line, medium corners.
    func hookFieldChrome() -> some View {
        background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
    }

    /// The form's full-width buttons (Test, Delete hook): raised, a strong line.
    func hookButtonChrome() -> some View {
        background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
    }
}
