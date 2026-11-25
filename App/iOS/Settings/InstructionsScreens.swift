import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Instructions on iPhone and iPad (MobileInstructions, MobileInstructionsEdit,
// iPadSettingsInstructions; home track): the root AGENTS.md and APPEND_SYSTEM.md every pi
// session Shepherd starts reads (`instructions.v1`; never pi's ~/.pi/agent). They are the
// fleet's: one copy, edited through the first Mac that answers, and the Macs' own sync carries a
// save to every other Mac, so these screens have no host to pick and nothing to fan out.
// `ClientInstructions` holds every rule; these screens draw it.

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task { if !inColumn { await store.watch() } }
    }
}

// MARK: iPhone

/// The phone's page (MobileInstructions): what the files are, and the two of them, each opening the editor.
private struct InstructionsPhonePage: View {
    let store: SettingsStore
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let model = store.instructions
        let hosts = store.hosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                SettingsHeading("Instructions")
                SettingsLead(InstructionsCopy.explanation).padding(.top, -MobileLayout.settingsLeadPull)
                if let problem = model.historyProblem(in: hosts) {
                    SHBanner(.failed, title: problem)
                } else if let problem = model.problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.settingsPill)
                    }
                }
                if model.edited(in: hosts) != nil {
                    SettingsSection("Read in this order · later wins") {
                        SettingsCard(inset: MobileLayout.settingsRowInset + MobileLayout.settingsLeadingWidth + SH.Space.l) {
                            ForEach(InstructionFile.allCases, id: \.self) { file in
                                Button { navigator.open(.settings(.instructionsFile(file))) } label: {
                                    InstructionsFileRow(file: file, note: InstructionsPresentation.fileNote(file, text: model.text(file, in: hosts), sentence: true),
                                                        edited: model.isEdited(file))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                        }
                    }
                    let saves = InstructionFile.allCases.flatMap { file in
                        model.history(file, in: hosts).dropFirst().prefix(MobileLayout.instructionsHistoryPerFile).map { (file, $0) }
                    }
                    if !saves.isEmpty {
                        SettingsSection("History") {
                            SettingsCard {
                                ForEach(saves, id: \.1.id) { file, entry in
                                    InstructionsSaveRow(file: file, entry: entry) { Task { await model.restore(entry, in: hosts) } }
                                }
                            }
                        }
                    }
                } else {
                    InstructionsUnavailable(model: model, hosts: hosts)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
    }
}

/// One earlier save (MobileInstructions' History): the file over when it was saved, and Restore.
private struct InstructionsSaveRow: View {
    let file: InstructionFile
    let entry: InstructionHistoryEntry
    let restore: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(file.fileName).font(.shMono(SHTextStyle.ui.size)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Text("Saved " + InstructionsPresentation.historyDate(entry.savedAt))
                    .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore", action: restore).buttonStyle(.settingsLink)
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, SH.Space.xs)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
    }
}

/// A file's row: a page glyph, the file (mono 15) over what it is and its size, "edited" while a draft
/// waits, and a chevron.
private struct InstructionsFileRow: View {
    let file: InstructionFile
    let note: String
    let edited: Bool

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Image(systemName: "doc.text")
                .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                .foregroundStyle(sh.textSecondary)
                .frame(width: MobileLayout.settingsLeadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(file.fileName)
                    .font(.shMono(SHTextStyle.ui.size, .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Text(note)
                    .font(.shSans(MobileLayout.settingsCaptionSize))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if edited {
                Text("edited").font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.lanternText)
            }
            SettingsChevron()
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsFileRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// In place of the files when no Mac's can be read: why.
private struct InstructionsUnavailable: View {
    let model: ClientInstructions
    let hosts: [SettingsHost]

    var body: some View {
        if hosts.isEmpty {
            SettingsFootnote("Add a Mac in Settings ▸ Fleet to start.")
        } else if hosts.contains(where: { model.files(of: $0) == .checking }) {
            SHBusyLabel("Reading the instructions…").frame(maxWidth: .infinity)
        } else if hosts.allSatisfy({ !$0.isConnected }) {
            SettingsFootnote("No Mac is online. The instructions show here once one is back.")
        } else if let reason = hosts.lazy.compactMap({ model.files(of: $0) }).compactMap({ if case .failed(let reason) = $0 { reason } else { nil } }).first {
            SettingsFootnote(reason, tone: .failed)
        } else {
            SettingsFootnote("Your Macs' Shepherd is too old to share instructions. Update it to edit them here.")
        }
    }
}

/// The phone's editor (MobileInstructionsEdit): the file under an inline header naming it and
/// saying it is the fleet's ("the fleet · edited"), Save trailing, and the key row over the keyboard.
struct InstructionsEditorScreen: View {
    let file: InstructionFile
    @Environment(MobileHosts.self) private var hosts
    @State private var focus = InstructionsEditorFocus()

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.instructions
        let settingsHosts = store.hosts
        let isEdited = model.isEdited(file)
        Group {
            if model.edited(in: settingsHosts) != nil {
                InstructionsTextEditor(
                    text: Binding(get: { model.text(file, in: settingsHosts) }, set: { model.setText($0, file: file, in: settingsHosts) }),
                    saved: model.saved(file, in: settingsHosts) ?? "",
                    metrics: .phone, focus: focus, accessibilityLabel: file.fileName
                )
            } else {
                ScrollView {
                    InstructionsUnavailable(model: model, hosts: settingsHosts)
                        .padding(MobileLayout.gutter)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if let problem = model.historyProblem(in: settingsHosts) {
                    SHBanner(.failed, title: problem)
                } else if let problem = model.problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.settingsPill)
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.s)
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
                    Text(InstructionsCopy.scope + (isEdited ? " · edited" : ""))
                        .font(.shSans(MobileLayout.settingsCaptionSize))
                        .foregroundStyle(Color.sh.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.busy {
                    SHBusyLabel("Saving…")
                } else {
                    Button("Save") { Task { await model.save(file, in: settingsHosts) } }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.primary)
                        .disabled(!isEdited)
                }
            }
        }
        .shAnimation(.content, value: model.problem)
        .task { await store.watch() }
    }
}

// MARK: iPad

/// The iPad's page (iPadSettingsInstructions): what the files are, History and Save, the files as
/// tabs, the editor, and the order pi reads them in.
private struct InstructionsPadPage: View {
    let store: SettingsStore
    @State private var file: InstructionFile = .agents
    @State private var focus = InstructionsEditorFocus()
    @State private var showsHistory = false

    var body: some View {
        let model = store.instructions
        let hosts = store.hosts
        let snapshot = model.edited(in: hosts).flatMap { model.files(of: $0).snapshot }
        VStack(spacing: 0) {
            PadColumnBar(title: "Instructions", subtitle: InstructionsCopy.padNote, inset: MobileLayout.settingsPadPageInset) {
                actions(model, hosts: hosts, historyAvailable: snapshot != nil && snapshot?.historyProblem == nil)
            }
        VStack(alignment: .leading, spacing: MobileLayout.instructionsPadSpacing) {
            if let problem = snapshot?.historyProblem {
                SHBanner(.failed, title: problem)
            } else if let problem = model.problem {
                SHBanner(.failed, title: problem) {
                    Button("OK") { model.dismissProblem() }.buttonStyle(.settingsPill)
                }
            }
            if let snapshot {
                InstructionsFileTabs(file: $file, note: { InstructionsPresentation.fileNote($0, text: model.text($0, in: hosts)) })
                editor(model, hosts: hosts, path: snapshot.path(of: file))
                if !focus.editing {
                    InstructionsReadOrder(file: file)
                    Text(InstructionsCopy.readOrderNote(file))
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                InstructionsUnavailable(model: model, hosts: hosts)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, MobileLayout.settingsPadPageInset)
        .padding(.bottom, MobileLayout.instructionsPadSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .shAnimation(.content, value: focus.editing)
    }

    /// History and Save, as the bar's glass.
    private func actions(_ model: ClientInstructions, hosts: [SettingsHost], historyAvailable: Bool) -> some View {
        HStack(spacing: SH.Space.m) {
            PadBarButton(title: "History", disabled: !historyAvailable) { showsHistory = true }
                .popover(isPresented: $showsHistory, arrowEdge: .top) {
                    InstructionsHistoryList(entries: model.history(file, in: hosts)) { entry in
                        showsHistory = false
                        Task { await model.restore(entry, in: hosts) }
                    }
                }
            PadBarPrimary(title: "Save to all hosts", disabled: !model.isEdited(file) || model.busy) { Task { await model.save(file, in: hosts) } }
        }
        .fixedSize()
    }

    /// The editor card: the file's path and "● edited" over the file.
    private func editor(_ model: ClientInstructions, hosts: [SettingsHost], path: String) -> some View {
        let sh = Color.sh
        return VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text(path)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: SH.Space.m)
                if model.isEdited(file) {
                    Text("● edited").font(.sh(.caption)).foregroundStyle(sh.lanternText)
                }
            }
            .padding(.vertical, SH.Space.m)
            .padding(.horizontal, SH.Space.l)
            .background(sh.bgSunken)
            SHHairline()
            InstructionsTextEditor(
                text: Binding(get: { model.text(file, in: hosts) }, set: { model.setText($0, file: file, in: hosts) }),
                saved: model.saved(file, in: hosts) ?? "",
                metrics: .pad, focus: focus, accessibilityLabel: file.fileName
            )
            .frame(minHeight: MobileLayout.instructionsEditorMinHeight, maxHeight: .infinity)
        }
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
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
                Button("Restore") { restore(entry) }.buttonStyle(.settingsPill)
            }
        }
        .padding(.vertical, SH.Space.m)
    }
}

/// The page's words.
private enum InstructionsCopy {
    static let explanation = "Shared across the fleet. Every Mac gets each save."
    /// Under the editor's file name on the phone.
    static let scope = "Every host"
    /// Beside History and Save on the iPad.
    static let padNote = "Shared across the fleet. Every Mac gets each save."

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
