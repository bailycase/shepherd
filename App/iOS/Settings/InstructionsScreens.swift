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
        .background(Color.nw.bgWindow)
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
        let edited = model.edited(in: hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text(InstructionsCopy.explanation)
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NW.Space.xs)
                    NWListCard {
                        SettingsSwitchRow("Same on every host", note: InstructionsCopy.scopeNote(sameEverywhere: model.sameEverywhere),
                                          isOn: model.sameEverywhere) { model.sameEverywhere = $0 }
                    }
                }
                if let problem = model.problem {
                    NWBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
                    }
                }
                if let edited, model.files(of: edited).snapshot != nil {
                    SettingsSection("Files") {
                        NWListCard {
                            ForEach(InstructionFile.allCases, id: \.self) { file in
                                Button { navigator.open(.settings(.instructionsFile(file))) } label: {
                                    InstructionsFileRow(file: file, note: InstructionsPresentation.fileNote(file, text: model.text(file, in: hosts), sentence: true),
                                                        edited: model.isEdited(file, in: hosts))
                                }
                                .buttonStyle(.nwRow(radius: 0))
                            }
                        }
                    }
                } else {
                    InstructionsUnavailable(model: model, hosts: hosts, edited: edited)
                }
                if !hosts.isEmpty {
                    SettingsSection("Hosts") {
                        NWListCard {
                            ForEach(hosts) { host in
                                InstructionsHostLine(model: model, host: host, hosts: hosts)
                            }
                        }
                        if !model.differing(in: hosts).isEmpty {
                            Button("Sync now") { Task { await model.syncNow(in: hosts) } }
                                .buttonStyle(.nw(.secondary))
                                .disabled(model.busy)
                                .padding(.top, NW.Space.xs)
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
        .nwAnimation(.content, value: model.sameEverywhere)
    }
}

/// A file's row: a page glyph, the file (mono 15/600) over what it is and its size, "edited"
/// while a draft waits, and a chevron.
private struct InstructionsFileRow: View {
    let file: InstructionFile
    let note: String
    let edited: Bool

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            Image(systemName: "doc.text")
                .font(.nw(.ui, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWListMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(file.fileName)
                    .font(.nwMono(NWTextStyle.ui.size, .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                Text(note)
                    .nwText(.caption)
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if edited {
                Text("edited").font(.nw(.caption)).foregroundStyle(nw.lanternText)
            }
            Image(systemName: "chevron.right")
                .font(.nw(.caption, weight: .semibold))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsFileRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A host's row: a display glyph, the host (mono 15), and its state trailing: with Same on
/// every host on, how it compares ("synced 2m ago", "differs · 2 lines", "offline · will
/// sync"); per host, the files it holds, the host being edited checked, and a tap to edit it.
private struct InstructionsHostLine: View {
    let model: ClientInstructions
    let host: SettingsHost
    let hosts: [SettingsHost]

    var body: some View {
        if model.sameEverywhere {
            line(chosen: false)
        } else {
            Button { model.chosenHost = host.id } label: {
                line(chosen: model.edited(in: hosts)?.id == host.id)
            }
            .buttonStyle(.nwRow(radius: 0))
            .accessibilityHint("Edits \(host.name)'s own files")
        }
    }

    private func line(chosen: Bool) -> some View {
        let nw = Color.nw
        let chip = state
        return HStack(spacing: NW.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.nw(.caption, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWListMetrics.leadingWidth)
                .accessibilityHidden(true)
            Text(host.name)
                .font(.nwMono(NWTextStyle.ui.size))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let word = chip.word {
                Text(word).font(.nw(.caption)).foregroundStyle(chip.tone.color).lineLimit(1)
            }
            if chosen {
                Image(systemName: "checkmark")
                    .font(.nw(.ui, weight: .semibold))
                    .foregroundStyle(nw.lantern)
                    .accessibilityLabel("Editing")
            }
        }
        .padding(.horizontal, NW.Space.l)
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
                ProgressView().progressViewStyle(NWSpinnerStyle()).frame(maxWidth: .infinity)
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
            ProgressView().progressViewStyle(NWSpinnerStyle()).frame(maxWidth: .infinity)
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
    let file: InstructionFile
    @Environment(MobileHosts.self) private var hosts
    @State private var focus = InstructionsEditorFocus()

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.instructions
        let settingsHosts = store.hosts
        let edited = model.edited(in: settingsHosts)
        let isEdited = model.isEdited(file, in: settingsHosts)
        Group {
            if let edited, model.files(of: edited).snapshot != nil {
                InstructionsTextEditor(
                    text: Binding(get: { model.text(file, in: settingsHosts) }, set: { model.setText($0, file: file, in: settingsHosts) }),
                    saved: model.saved(file, in: settingsHosts) ?? "",
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
                NWBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.vertical, NW.Space.s)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focus.editing { InstructionsKeyRow(focus: focus) }
        }
        .background(Color.nw.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: NW.Space.xxs / 2) {
                    Text(file.fileName)
                        .font(.nwMono(NWTextStyle.ui.size, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                    Text(model.scope(in: settingsHosts) + (isEdited ? " · edited" : ""))
                        .font(.nw(.micro, weight: .regular))
                        .foregroundStyle(Color.nw.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.busy {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                } else {
                    Button("Save") { Task { await model.save(file, in: settingsHosts) } }
                        .disabled(!isEdited)
                        .accessibilityLabel(model.saveTitle(in: settingsHosts))
                }
            }
        }
        .nwAnimation(.content, value: model.problem)
        .task { await store.watch() }
    }
}

// MARK: iPad

/// The iPad's page (iPadSettingsInstructions): Every host | Per host with each host's state,
/// History and Save, the files as tabs, the editor, and the order pi reads them in.
private struct InstructionsPadPage: View {
    let store: SettingsStore
    @State private var file: InstructionFile = .agents
    @State private var focus = InstructionsEditorFocus()
    @State private var showsHistory = false

    var body: some View {
        let model = store.instructions
        let hosts = store.hosts
        let edited = model.edited(in: hosts)
        let snapshot = edited.flatMap { model.files(of: $0).snapshot }
        VStack(alignment: .leading, spacing: MobileLayout.instructionsPadSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NW.Space.l) {
                    scope(model, hosts: hosts)
                    Spacer(minLength: NW.Space.l)
                    actions(model, hosts: hosts, ready: snapshot != nil)
                }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    scope(model, hosts: hosts)
                    actions(model, hosts: hosts, ready: snapshot != nil)
                }
            }
            if let problem = model.problem {
                NWBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
                }
            }
            if let snapshot {
                InstructionsFileTabs(file: $file, note: { InstructionsPresentation.fileNote($0, text: model.text($0, in: hosts)) })
                editor(model, hosts: hosts, path: snapshot.path(of: file))
                if !focus.editing {
                    InstructionsReadOrder(file: file)
                    Text(InstructionsCopy.readOrderNote(file))
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textTertiary)
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
        .nwAnimation(.content, value: focus.editing)
    }

    /// Every host | Per host, then each host's state, or which host is edited.
    private func scope(_ model: ClientInstructions, hosts: [SettingsHost]) -> some View {
        HStack(spacing: NW.Space.l) {
            InstructionsScopePicker(sameEverywhere: Binding(get: { model.sameEverywhere }, set: { model.sameEverywhere = $0 }))
            if model.sameEverywhere {
                if let line = model.syncLine(in: hosts) {
                    Text(line).nwText(.caption).foregroundStyle(Color.nw.textTertiary).lineLimit(2)
                }
                if !model.differing(in: hosts).isEmpty {
                    Button("Sync now") { Task { await model.syncNow(in: hosts) } }
                        .buttonStyle(.nwLink(font: .nw(.caption)))
                        .disabled(model.busy)
                }
            } else {
                Menu {
                    ForEach(hosts) { host in
                        Button { model.chosenHost = host.id } label: {
                            if host.id == model.edited(in: hosts)?.id { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                        }
                    }
                } label: {
                    SettingsMenuLabel(model.edited(in: hosts)?.name ?? "No host", mono: true)
                }
                .accessibilityLabel("Host to edit")
            }
        }
    }

    /// History and Save.
    private func actions(_ model: ClientInstructions, hosts: [SettingsHost], ready: Bool) -> some View {
        HStack(spacing: NW.Space.m) {
            Button("History") { showsHistory = true }
                .buttonStyle(.nw(.secondary, size: .l))
                .disabled(!ready)
                .popover(isPresented: $showsHistory, arrowEdge: .top) {
                    InstructionsHistoryList(entries: model.history(file, in: hosts)) { entry in
                        showsHistory = false
                        Task { await model.restore(entry, in: hosts) }
                    }
                }
            Button(model.saveTitle(in: hosts)) { Task { await model.save(file, in: hosts) } }
                .buttonStyle(.nw(.primary, size: .l))
                .disabled(!model.isEdited(file, in: hosts) || model.busy)
        }
        .fixedSize()
    }

    /// The editor card: the file's path and "● edited" over the file.
    private func editor(_ model: ClientInstructions, hosts: [SettingsHost], path: String) -> some View {
        let nw = Color.nw
        return VStack(spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Text(path)
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: NW.Space.m)
                if model.isEdited(file, in: hosts) {
                    Text("● edited").font(.nw(.caption)).foregroundStyle(nw.lanternText)
                }
            }
            .padding(.vertical, NW.Space.m)
            .padding(.horizontal, NW.Space.l)
            .background(nw.bgSunken)
            NWHairline()
            InstructionsTextEditor(
                text: Binding(get: { model.text(file, in: hosts) }, set: { model.setText($0, file: file, in: hosts) }),
                saved: model.saved(file, in: hosts) ?? "",
                metrics: .pad, focus: focus, accessibilityLabel: file.fileName
            )
            .frame(minHeight: MobileLayout.instructionsEditorMinHeight, maxHeight: .infinity)
        }
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(nw.lineStrong, radius: NW.Radius.l)
    }
}

/// Every host | Per host (iPadSettingsInstructions): a 300pt control on `bgSelected`, the chosen
/// side raised.
private struct InstructionsScopePicker: View {
    @Binding var sameEverywhere: Bool

    var body: some View {
        HStack(spacing: NW.Space.xxs) {
            segment("Every host", chosen: sameEverywhere) { sameEverywhere = true }
            segment("Per host", chosen: !sameEverywhere) { sameEverywhere = false }
        }
        .padding(NW.Space.xxs)
        .frame(width: MobileLayout.instructionsScopeWidth)
        .background(Color.nw.bgSelected, in: RoundedRectangle(cornerRadius: MobileLayout.instructionsScopeRadius))
        .nwAnimation(.content, value: sameEverywhere)
        .accessibilityRepresentation {
            Picker("Instructions", selection: $sameEverywhere) {
                Text("Every host").tag(true)
                Text("Per host").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        let nw = Color.nw
        return Button(action: action) {
            Text(title)
                .font(.nwSans(MobileLayout.instructionsScopeTextSize, chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? nw.textPrimary : nw.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsScopeSegmentHeight)
                .background(chosen ? nw.bgRaised : .clear, in: RoundedRectangle(cornerRadius: MobileLayout.instructionsScopeSegmentRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The files as tabs (22pt apart over a hairline): the name in mono 13, the open one semibold in
/// `textPrimary` with a 2pt underline, over what it is and its size.
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
        .background(alignment: .bottom) { NWHairline() }
    }

    private func tab(_ option: InstructionFile) -> some View {
        let nw = Color.nw
        let chosen = option == file
        return Button { file = option } label: {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(option.fileName)
                    .font(.nwMono(MobileLayout.instructionsTabTextSize, chosen ? .semibold : .medium))
                    .foregroundStyle(chosen ? nw.textPrimary : nw.textSecondary)
                Text(note(option))
                    .font(.nw(.micro, weight: .regular))
                    .foregroundStyle(nw.textTertiary)
            }
            .padding(.horizontal, NW.Space.xxs)
            .padding(.top, NW.Space.m)
            .padding(.bottom, NW.Space.m + NW.Space.xxs)
            .overlay(alignment: .bottom) {
                if chosen { Rectangle().fill(nw.textPrimary).frame(height: MobileLayout.instructionsTabUnderline) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// "READ IN THIS ORDER · LATER WINS", then the chain pi reads, the open file's link marked.
private struct InstructionsReadOrder: View {
    let file: InstructionFile

    private static let steps: [(title: String, file: InstructionFile?)] = [
        ("pi prompt", nil), ("Shepherd's AGENTS.md", .agents), ("parent folders", nil), ("repo AGENTS.md", nil),
        ("Shepherd's APPEND_SYSTEM.md", .appendSystem),
    ]

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text("Read in this order · later wins").nwSectionLabel()
            NWWrapStack(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Text("→").font(.nw(.caption)).foregroundStyle(nw.textTertiary).accessibilityHidden(true)
                    }
                    chip(step.title, marked: step.file == file)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read in this order, later wins: " + Self.steps.map { $0.title }.joined(separator: ", "))
    }

    private func chip(_ title: String, marked: Bool) -> some View {
        let nw = Color.nw
        return Text(title)
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(marked ? nw.textPrimary : nw.textSecondary)
            .padding(.vertical, NW.Space.xs)
            .padding(.horizontal, NW.Space.m)
            .background(marked ? nw.lanternTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .nwBorder(marked ? nw.lanternText : nw.lineSubtle, radius: NW.Radius.s)
    }
}

/// History's popover: the open file's saves on the host edited, newest first, each but the
/// current one with Restore.
private struct InstructionsHistoryList: View {
    let entries: [InstructionHistoryEntry]
    let restore: (InstructionHistoryEntry) -> Void

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text("History").font(.nw(.headline)).foregroundStyle(nw.textPrimary)
            if entries.isEmpty {
                Text("No saves yet. Each save is kept here, to restore.")
                    .nwText(.caption).foregroundStyle(nw.textTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { NWHairline() }
                            row(entry, current: index == 0)
                        }
                    }
                }
            }
        }
        .padding(NW.Space.l)
        .frame(width: MobileLayout.instructionsHistoryWidth)
        .frame(maxHeight: MobileLayout.instructionsHistoryMaxHeight)
        .background(nw.bgRaised)
    }

    private func row(_ entry: InstructionHistoryEntry, current: Bool) -> some View {
        let nw = Color.nw
        let when = InstructionsPresentation.historyDate(entry.savedAt)
        return HStack(spacing: NW.Space.m) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(entry.summary).font(.nw(.ui)).foregroundStyle(nw.textPrimary).lineLimit(2)
                Text(entry.origin.map { "\(when) · from \($0)" } ?? when)
                    .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if current {
                Text("current").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
            } else {
                Button("Restore") { restore(entry) }.buttonStyle(.nw(.secondary, size: .s))
            }
        }
        .padding(.vertical, NW.Space.m)
    }
}

/// The page's words.
private enum InstructionsCopy {
    static let explanation = "Every pi session Shepherd starts reads these, on every host. A repo's own AGENTS.md still applies."

    static func scopeNote(sameEverywhere: Bool) -> String {
        sameEverywhere ? "Save once, written to every host." : "Each host keeps its own."
    }

    /// Under the read order: why the open file sits where it does.
    static func readOrderNote(_ file: InstructionFile) -> String {
        switch file {
        case .agents:
            "Shepherd's AGENTS.md comes before any folder's or repo's AGENTS.md, so a repo's own file can refine it."
        case .appendSystem:
            "APPEND_SYSTEM.md is added to the end of pi's system prompt, so these rules beat anything in an AGENTS.md. Keep it short."
        }
    }
}

extension InstructionsChip.Tone {
    /// The chip's color: `done`, `lanternText`, `textTertiary`, `running` or `failed`.
    @MainActor var color: Color {
        switch self {
        case .done: Color.nw.done
        case .attention: Color.nw.lanternText
        case .quiet: Color.nw.textTertiary
        case .working: Color.nw.running
        case .failed: Color.nw.failed
        }
    }
}
