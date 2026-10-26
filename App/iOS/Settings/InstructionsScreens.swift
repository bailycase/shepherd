import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Instructions on iPhone and iPad (MobileInstructions, MobileInstructionsEdit,
// iPadSettingsInstructions; home track): the root AGENTS.md and APPEND_SYSTEM.md every pi
// session Shepherd starts reads, which each host keeps in its own support folder
// (`instructions.v1`; never pi's ~/.pi/agent). With Same on every host on (the default, kept per
// device), the page edits one set of files and a save writes them to every host; off, it edits
// one host's. `ClientInstructions` holds every rule; these screens draw it.

/// Settings ▸ Instructions: the phone's page, or the iPad's editor beside Settings' list.
struct InstructionsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        let store = SettingsStore.of(hosts)
        Group {
            if sizeClass == .regular {
                InstructionsPadPage(store: store)
            } else {
                InstructionsPhonePage(store: store)
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(sizeClass == .regular || inColumn ? .inline : .large)
        .task { if !inColumn { await store.watch() } }
    }
}

// MARK: iPhone

/// The phone's page (MobileInstructions): what the files are, Same on every host, the two files
/// (each opening the editor), and every host's state.
private struct InstructionsPhonePage: View {
    let store: SettingsStore
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let model = store.instructions
        let hosts = store.hosts
        let edited = model.edited(in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text(InstructionsCopy.explanation)
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SH.Space.xs)
                    SHListCard {
                        SettingsSwitchRow("Same on every host", note: InstructionsCopy.scopeNote(sameEverywhere: model.sameEverywhere),
                                          isOn: model.sameEverywhere) { model.sameEverywhere = $0 }
                    }
                }
                if let problem = model.problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.sh(.secondary))
                    }
                }
                if let edited, model.files(of: edited).snapshot != nil {
                    SettingsSection("Files") {
                        SHListCard {
                            ForEach(InstructionFile.allCases, id: \.self) { file in
                                Button { navigator.open(.settings(.instructionsFile(file))) } label: {
                                    InstructionsFileRow(file: file, note: InstructionsPresentation.fileNote(file, text: model.text(file, in: hosts, selectedHost: navigator.settingsSelection.instructionsHost), sentence: true),
                                                        edited: model.isEdited(file, in: hosts, selectedHost: navigator.settingsSelection.instructionsHost))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                        }
                    }
                } else {
                    InstructionsUnavailable(model: model, hosts: hosts, edited: edited)
                }
                if !hosts.isEmpty {
                    SettingsSection("Hosts") {
                        SHListCard {
                            ForEach(hosts) { host in
                                InstructionsHostLine(model: model, host: host, hosts: hosts)
                            }
                        }
                        if !model.differing(in: hosts).isEmpty {
                            Button("Sync now") { Task { await model.syncNow(in: hosts) } }
                                .buttonStyle(.sh(.secondary))
                                .disabled(model.busy)
                                .padding(.top, SH.Space.xs)
                        }
                        if !model.sameEverywhere {
                            SettingsFootnote("Tap a host to edit its own files.")
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .shAnimation(.content, value: model.sameEverywhere)
    }
}

/// A file's row: a page glyph, the file (mono 15/600) over what it is and its size, "edited"
/// while a draft waits, and a chevron.
private struct InstructionsFileRow: View {
    let file: InstructionFile
    let note: String
    let edited: Bool

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Image(systemName: "doc.text")
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHListMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(file.fileName)
                    .font(.shMono(SHTextStyle.ui.size, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Text(note)
                    .shText(.caption)
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if edited {
                Text("edited").font(.sh(.caption)).foregroundStyle(sh.lanternText)
            }
            Image(systemName: "chevron.right")
                .font(.sh(.caption, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsFileRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A host's row: a display glyph, the host (mono 15), and its state trailing: with Same on
/// every host on, how it compares ("synced 2m ago", "differs · 2 lines", "offline · will
/// sync"); per host, the files it holds, the host being edited checked, and a tap to edit it.
private struct InstructionsHostLine: View {
    @Environment(MobileNavigator.self) private var navigator
    let model: ClientInstructions
    let host: SettingsHost
    let hosts: [SettingsHost]

    var body: some View {
        if model.sameEverywhere {
            line(chosen: false)
        } else {
            Button { navigator.settingsSelection.instructionsHost = host.id } label: {
                line(chosen: model.edited(in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)?.id == host.id)
            }
            .buttonStyle(.shRow(radius: 0))
            .accessibilityHint("Edits \(host.name)'s own files")
        }
    }

    private func line(chosen: Bool) -> some View {
        let sh = Color.sh
        let chip = state
        return HStack(spacing: SH.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHListMetrics.leadingWidth)
                .accessibilityHidden(true)
            Text(host.name)
                .font(.shMono(SHTextStyle.ui.size))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let word = chip.word {
                Text(word).font(.sh(.caption)).foregroundStyle(chip.tone.color).lineLimit(1)
            }
            if chosen {
                Image(systemName: "checkmark")
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(sh.lantern)
                    .accessibilityLabel("Editing")
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsHostRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// With Same on every host on, the host's chip; per host, what it holds.
    private var state: InstructionsChip {
        if model.sameEverywhere {
            let chip = model.chip(for: host, file: .agents, in: hosts)
            return InstructionsChip(chip.tone, chip.word ?? "matches")
        }
        if let snapshot = model.files(of: host).snapshot {
            return InstructionsChip(.quiet, InstructionsPresentation.filesHeld(snapshot))
        }
        return model.chip(for: host, file: .agents, in: hosts)
    }
}

/// In place of the files when no host's can be read, or the host chosen can't: why.
private struct InstructionsUnavailable: View {
    let model: ClientInstructions
    let hosts: [SettingsHost]
    let edited: SettingsHost?

    var body: some View {
        if let edited {
            switch model.files(of: edited) {
            case .checking, .loaded:
                ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
            case .offline:
                SettingsFootnote("\(edited.name) is offline. Its instructions show here once it's back.")
            case .unsupported:
                SettingsFootnote("\(edited.name)'s Shepherd is too old to share its instructions. Update it to edit them here.")
            case .failed(let reason):
                SettingsFootnote(reason, tone: .failed)
            }
        } else if hosts.isEmpty {
            SettingsFootnote("Add a host in Settings ▸ Hosts to edit its instructions here.")
        } else if hosts.contains(where: { model.files(of: $0) == .checking }) {
            ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
        } else if hosts.allSatisfy({ !$0.isConnected }) {
            SettingsFootnote("No host is online. The instructions show here once one is back.")
        } else {
            SettingsFootnote("Your hosts' Shepherd is too old to share instructions. Update it to edit them here.")
        }
    }
}

/// The phone's editor (MobileInstructionsEdit): the file under an inline header naming it and
/// where a save goes ("every host · edited"), Save trailing, and the key row over the keyboard.
struct InstructionsEditorScreen: View {
    @Environment(MobileNavigator.self) private var navigator
    let file: InstructionFile
    @Environment(MobileHosts.self) private var hosts
    @State private var focus = InstructionsEditorFocus()

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.instructions
        let settingsHosts = store.hosts
        let selectedHost = navigator.settingsSelection.instructionsHost
        let edited = model.edited(in: settingsHosts, selectedHost: selectedHost)
        let isEdited = model.isEdited(file, in: settingsHosts, selectedHost: selectedHost)
        Group {
            if let edited, model.files(of: edited).snapshot != nil {
                InstructionsTextEditor(
                    text: Binding(get: { model.text(file, in: settingsHosts, selectedHost: selectedHost) }, set: { model.setText($0, file: file, in: settingsHosts, selectedHost: selectedHost) }),
                    saved: model.saved(file, in: settingsHosts, selectedHost: selectedHost) ?? "",
                    metrics: .phone, focus: focus, accessibilityLabel: file.fileName
                )
            } else {
                ScrollView {
                    InstructionsUnavailable(model: model, hosts: settingsHosts, edited: edited)
                        .padding(MobileLayout.gutter)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = model.problem {
                SHBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.sh(.secondary))
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.vertical, SH.Space.s)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focus.editing { InstructionsKeyRow(focus: focus) }
        }
        .background(Color.sh.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: SH.Space.xxs / 2) {
                    Text(file.fileName)
                        .font(.shMono(SHTextStyle.ui.size, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                    Text(model.scope(in: settingsHosts, selectedHost: selectedHost) + (isEdited ? " · edited" : ""))
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(Color.sh.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.busy {
                    ProgressView().progressViewStyle(SHSpinnerStyle())
                } else {
                    Button("Save") { Task { await model.save(file, in: settingsHosts, selectedHost: selectedHost) } }
                        .disabled(!isEdited)
                        .accessibilityLabel(model.saveTitle(in: settingsHosts, selectedHost: selectedHost))
                }
            }
        }
        .shAnimation(.content, value: model.problem)
        .task { await store.watch() }
    }
}

// MARK: iPad

/// The iPad's page (iPadSettingsInstructions): Every host | Per host with each host's state,
/// History and Save, the files as tabs, the editor, and the order pi reads them in.
private struct InstructionsPadPage: View {
    @Environment(MobileNavigator.self) private var navigator
    let store: SettingsStore
    @State private var file: InstructionFile = .agents
    @State private var focus = InstructionsEditorFocus()
    @State private var showsHistory = false

    var body: some View {
        let model = store.instructions
        let hosts = store.hosts
        let edited = model.edited(in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)
        let snapshot = edited.flatMap { model.files(of: $0).snapshot }
        VStack(alignment: .leading, spacing: MobileLayout.instructionsPadSpacing) {
            // History's popover hangs off its button, so the actions are built once: only the
            // scope wraps under its picker when the column is narrow.
            HStack(alignment: .top, spacing: SH.Space.l) {
                // iPadSettingsInstructions: the scope control over each host's state.
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    scopePicker(model)
                    scopeState(model, hosts: hosts)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions(model, hosts: hosts, ready: snapshot != nil)
            }
            if let problem = model.problem {
                SHBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.sh(.secondary))
                }
            }
            if let snapshot {
                InstructionsFileTabs(file: $file, note: { InstructionsPresentation.fileNote($0, text: model.text($0, in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)) })
                editor(model, hosts: hosts, path: snapshot.path(of: file))
                if !focus.editing {
                    InstructionsReadOrder(file: file)
                    Text(InstructionsCopy.readOrderNote(file))
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                InstructionsUnavailable(model: model, hosts: hosts, edited: edited)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, MobileLayout.instructionsPadSides)
        .padding(.vertical, MobileLayout.instructionsPadSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shAnimation(.content, value: focus.editing)
    }

    /// Every host | Per host.
    private func scopePicker(_ model: ClientInstructions) -> some View {
        InstructionsScopePicker(sameEverywhere: Binding(get: { model.sameEverywhere }, set: { model.sameEverywhere = $0 }))
    }

    /// Each host's state, or which host is edited.
    private func scopeState(_ model: ClientInstructions, hosts: [SettingsHost]) -> some View {
        HStack(spacing: SH.Space.l) {
            if model.sameEverywhere {
                if let line = model.syncLine(in: hosts) {
                    Text(line).shText(.caption).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                }
                if !model.differing(in: hosts).isEmpty {
                    Button("Sync now") { Task { await model.syncNow(in: hosts) } }
                        .buttonStyle(.shLink(font: .sh(.caption)))
                        .disabled(model.busy)
                }
            } else {
                Menu {
                    ForEach(hosts) { host in
                        Button { navigator.settingsSelection.instructionsHost = host.id } label: {
                            if host.id == model.edited(in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)?.id { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                        }
                    }
                } label: {
                    SettingsMenuLabel(model.edited(in: hosts, selectedHost: navigator.settingsSelection.instructionsHost)?.name ?? "No host", mono: true)
                }
                .accessibilityLabel("Host to edit")
            }
        }
    }

    /// History and Save.
    private func actions(_ model: ClientInstructions, hosts: [SettingsHost], ready: Bool) -> some View {
        let selectedHost = navigator.settingsSelection.instructionsHost
        return HStack(spacing: SH.Space.m) {
            Button("History") { showsHistory = true }
                .buttonStyle(.sh(.secondary, size: .l))
                .disabled(!ready)
                .popover(isPresented: $showsHistory, arrowEdge: .top) {
                    InstructionsHistoryList(entries: model.history(file, in: hosts, selectedHost: selectedHost)) { entry in
                        showsHistory = false
                        Task { await model.restore(entry, in: hosts, selectedHost: selectedHost) }
                    }
                }
            Button(model.saveTitle(in: hosts, selectedHost: selectedHost)) { Task { await model.save(file, in: hosts, selectedHost: selectedHost) } }
                .buttonStyle(.sh(.primary, size: .l))
                .disabled(!model.isEdited(file, in: hosts, selectedHost: selectedHost) || model.busy)
        }
        .fixedSize()
    }

    /// The editor card: the file's path and "● edited" over the file.
    private func editor(_ model: ClientInstructions, hosts: [SettingsHost], path: String) -> some View {
        let sh = Color.sh
        let selectedHost = navigator.settingsSelection.instructionsHost
        return VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text(path)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: SH.Space.m)
                if model.isEdited(file, in: hosts, selectedHost: selectedHost) {
                    Text("● edited").font(.sh(.caption)).foregroundStyle(sh.lanternText)
                }
            }
            .padding(.vertical, SH.Space.m)
            .padding(.horizontal, SH.Space.l)
            .background(sh.bgSunken)
            SHHairline()
            InstructionsTextEditor(
                text: Binding(get: { model.text(file, in: hosts, selectedHost: selectedHost) }, set: { model.setText($0, file: file, in: hosts, selectedHost: selectedHost) }),
                saved: model.saved(file, in: hosts, selectedHost: selectedHost) ?? "",
                metrics: .pad, focus: focus, accessibilityLabel: file.fileName
            )
            .frame(minHeight: MobileLayout.instructionsEditorMinHeight, maxHeight: .infinity)
        }
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
    }
}

/// Every host | Per host (iPadSettingsInstructions): a 300pt control on `bgSunken` with a
/// `lineSubtle` line, the chosen side raised.
private struct InstructionsScopePicker: View {
    @Binding var sameEverywhere: Bool

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            segment("Every host", chosen: sameEverywhere) { sameEverywhere = true }
            segment("Per host", chosen: !sameEverywhere) { sameEverywhere = false }
        }
        .padding(SH.Space.xxs)
        .frame(width: MobileLayout.instructionsScopeWidth)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: MobileLayout.instructionsScopeRadius))
        .shBorder(Color.sh.lineSubtle, radius: MobileLayout.instructionsScopeRadius)
        .shAnimation(.content, value: sameEverywhere)
        .accessibilityRepresentation {
            Picker("Instructions", selection: $sameEverywhere) {
                Text("Every host").tag(true)
                Text("Per host").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        let sh = Color.sh
        return Button(action: action) {
            Text(title)
                .font(.shSans(MobileLayout.instructionsScopeTextSize, .regular))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsScopeSegmentHeight)
                .background(chosen ? sh.bgRaised : .clear, in: RoundedRectangle(cornerRadius: MobileLayout.instructionsScopeSegmentRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The files as tabs (22pt apart over a hairline, iPadSettingsInstructions): the name in mono 13,
/// the open one in `textPrimary` over a 2pt `lantern` underline, the other `textTertiary`.
private struct InstructionsFileTabs: View {
    @Binding var file: InstructionFile
    let note: (InstructionFile) -> String

    var body: some View {
        HStack(alignment: .bottom, spacing: MobileLayout.instructionsTabSpacing) {
            ForEach(InstructionFile.allCases, id: \.self) { option in
                tab(option)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { SHHairline() }
    }

    private func tab(_ option: InstructionFile) -> some View {
        let sh = Color.sh
        let chosen = option == file
        return Button { file = option } label: {
            Text(option.fileName)
                .font(.shMono(MobileLayout.instructionsTabTextSize, .regular))
                .foregroundStyle(chosen ? sh.textPrimary : sh.textTertiary)
                .frame(minHeight: SH.Height.touch)
                .overlay(alignment: .bottom) {
                    if chosen { Rectangle().fill(sh.lantern).frame(height: MobileLayout.instructionsTabUnderline) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(note(option))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// "READ IN THIS ORDER · LATER WINS", then the chain the agent reads, the open file's link marked.
private struct InstructionsReadOrder: View {
    let file: InstructionFile

    private static let steps: [(title: String, file: InstructionFile?)] = [
        ("System prompt", nil), ("Shepherd's AGENTS.md", .agents), ("parent folders", nil), ("repo AGENTS.md", nil),
        ("Shepherd's APPEND_SYSTEM.md", .appendSystem),
    ]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Read in this order · later wins").shSectionLabel()
            SHWrapStack(spacing: SH.Space.s, lineSpacing: SH.Space.s) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Text("→").font(.sh(.caption)).foregroundStyle(sh.textTertiary).accessibilityHidden(true)
                    }
                    chip(step.title, marked: step.file == file)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read in this order, later wins: " + Self.steps.map { $0.title }.joined(separator: ", "))
    }

    private func chip(_ title: String, marked: Bool) -> some View {
        let sh = Color.sh
        return Text(title)
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(marked ? sh.textPrimary : sh.textSecondary)
            .padding(.vertical, SH.Space.xs)
            .padding(.horizontal, SH.Space.m)
            .background(marked ? sh.lanternTint : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(marked ? sh.lanternText : sh.lineSubtle, radius: SH.Radius.s)
    }
}

/// History's popover: the open file's saves on the host edited, newest first, each but the
/// current one with Restore.
private struct InstructionsHistoryList: View {
    let entries: [InstructionHistoryEntry]
    let restore: (InstructionHistoryEntry) -> Void

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("History").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
            if entries.isEmpty {
                Text("No saves yet. Each save is kept here, to restore.")
                    .shText(.caption).foregroundStyle(sh.textTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { SHHairline() }
                            row(entry, current: index == 0)
                        }
                    }
                }
            }
        }
        .padding(SH.Space.l)
        .frame(width: MobileLayout.instructionsHistoryWidth)
        .frame(maxHeight: MobileLayout.instructionsHistoryMaxHeight)
        .background(sh.bgRaised)
    }

    private func row(_ entry: InstructionHistoryEntry, current: Bool) -> some View {
        let sh = Color.sh
        let when = InstructionsPresentation.historyDate(entry.savedAt)
        return HStack(spacing: SH.Space.m) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(entry.summary).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(2)
                Text(entry.origin.map { "\(when) · from \($0)" } ?? when)
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if current {
                Text("current").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            } else {
                Button("Restore") { restore(entry) }.buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .padding(.vertical, SH.Space.m)
    }
}

/// The page's words.
private enum InstructionsCopy {
    static let explanation = "The agent reads these at the start of every session Shepherd starts, on every host."

    static func scopeNote(sameEverywhere: Bool) -> String {
        sameEverywhere ? "Save once, written to every host." : "Each host keeps its own."
    }

    /// Under the read order: why the open file sits where it does.
    static func readOrderNote(_ file: InstructionFile) -> String {
        switch file {
        case .agents:
            "Shepherd's AGENTS.md comes before any folder's or repo's AGENTS.md, so a repo's own file can refine it."
        case .appendSystem:
            "APPEND_SYSTEM.md is added to the end of the agent’s system prompt, so these rules beat anything in an AGENTS.md. Keep it short."
        }
    }
}

extension InstructionsChip.Tone {
    /// The chip's color: `done`, `lanternText`, `textTertiary`, `running` or `failed`.
    @MainActor var color: Color {
        switch self {
        case .done: Color.sh.done
        case .attention: Color.sh.lanternText
        case .quiet: Color.sh.textTertiary
        case .working: Color.sh.running
        case .failed: Color.sh.failed
        }
    }
}
