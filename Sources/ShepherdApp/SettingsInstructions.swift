import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Instructions (SettingsInstructions, SettingsInstructionsHosts): the root
/// instructions Shepherd hands every pi it starts, `AGENTS.md` and `APPEND_SYSTEM.md`, on this
/// Mac and on each remote host. A wide page: the header, Same on every host, a chip per machine,
/// then the open file's editor beside a 330pt side column (how pi reads the files; per host, each
/// host's files and the chosen host's history).
struct InstructionsSettings: View {
    @Bindable var model: InstructionsModel

    static let explanation = "The agent’s root files, read at the start of every session Shepherd starts: `AGENTS.md` for how "
        + "you work, `APPEND_SYSTEM.md` for rules that override everything else. Repos can still add their own AGENTS.md."
    static let perHostExplanation = "Per host: each machine keeps its own root files."

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsWideBlockSpacing) {
            SettingsHeader(title: "Instructions", explanation: model.sameEverywhere ? Self.explanation : Self.perHostExplanation)
                .frame(maxWidth: AppLayout.settingsWideHeaderWidth, alignment: .leading)
            SHGroupCard(fill: Color.sh.bgWindow) {
                SettingsRow(title: "Same on every host",
                            subtitle: model.sameEverywhere
                                ? "Save once; Shepherd writes both files to every host. Offline hosts catch up when they're back."
                                : "Off: each host keeps its own files. Pick a host to edit it.") {
                    SettingsSwitch(label: "Same on every host", isOn: $model.sameEverywhere)
                }
            }
            // Ages on the chips ("synced 2m ago") and in the side column move on by themselves.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: AppLayout.settingsWideBlockSpacing) {
                    InstructionsHostChips(model: model, now: context.date)
                    HStack(alignment: .top, spacing: AppLayout.instructionsColumnSpacing) {
                        InstructionsMainColumn(model: model)
                        InstructionsSideColumn(model: model, now: context.date)
                            .frame(width: AppLayout.instructionsSideWidth)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .shAnimation(.content, value: model.sameEverywhere)
        .task { await model.refresh() }
    }
}

// MARK: Hosts

/// One chip per machine, This Mac first, 8pt apart and wrapping. With Same on every host on they
/// report the sync, and a host that drifted can be synced now; per host they pick the machine
/// to edit.
private struct InstructionsHostChips: View {
    var model: InstructionsModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHFlowLayout(spacing: SH.Space.m) {
                chip(.local)
                ForEach(model.hosts, id: \.id) { host in
                    chip(.remote(host.id))
                }
            }
            let drifted = model.sameEverywhere ? model.differingHosts : []
            if !drifted.isEmpty {
                HStack(spacing: SH.Space.m) {
                    SettingsNote(text: InstructionsPresentation.drifted(drifted.map { model.name(of: .remote($0)) }))
                    Button("Sync now") { Task { await model.syncDiffering() } }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .disabled(model.busy)
                        .help("Write This Mac's files there")
                }
                .shTransition(.disclosure)
            }
        }
    }

    private func chip(_ machine: InstructionsModel.Machine) -> some View {
        InstructionsHostChip(
            name: model.name(of: machine),
            chip: model.chip(for: machine, now: now),
            selected: model.machine == machine,
            select: model.sameEverywhere ? nil : { model.machine = machine }
        )
    }
}

/// A machine's chip: a `desktopcomputer` glyph, the name in mono, a state dot, and the state's
/// word unless the dot says it all. The chosen machine has a `textPrimary` line on `bgSelected`.
struct InstructionsHostChip: View {
    let name: String
    let chip: InstructionsChip
    let selected: Bool
    /// Per host the chip picks the machine to edit; with Same on every host on it only reports.
    var select: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let select {
            Button(action: select) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .shFocusRing(radius: SH.Radius.m)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Edits \(name)'s files")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        let sh = Color.sh
        let tone = Self.color(chip.tone)
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        return HStack(spacing: SH.Space.m) {
            Image(systemName: "desktopcomputer")
                .font(.shSans(AppLayout.instructionsChipGlyphSize))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.shMono(AppLayout.instructionsChipNameSize, selected ? .semibold : .medium))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
            Circle()
                .fill(tone)
                .frame(width: AppLayout.instructionsChipDot, height: AppLayout.instructionsChipDot)
                .accessibilityHidden(true)
            if let word = chip.word {
                Text(word)
                    .font(.shSans(AppLayout.instructionsChipWordSize))
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: AppLayout.instructionsChipHeight)
        .background(selected ? sh.bgSelected : hovering && select != nil ? sh.bgHover : .clear, in: shape)
        .shBorder(selected ? sh.textPrimary : sh.lineStrong, radius: SH.Radius.m)
        .contentShape(shape)
        .shAnimation(.hover, value: hovering)
    }

    @MainActor static func color(_ tone: InstructionsChip.Tone) -> Color {
        switch tone {
        case .done: .sh.done
        case .attention: .sh.lanternText
        case .quiet: .sh.textTertiary
        case .working: .sh.running
        case .failed: .sh.failed
        }
    }
}

// MARK: Files

/// The file tabs, the open file's editor (or, per host, its comparison with This Mac), and what
/// to do about a difference.
private struct InstructionsMainColumn: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            InstructionsFileTabs(model: model)
            if let copy = model.adoptable(model.file) {
                // What came over from your pi is read by every agent already; this file is empty, so say where it is and offer it here.
                SHNoteCard(glyph: "square.and.arrow.down", link: "Use it here", action: { model.adoptImported(model.file) }) {
                    (Text("Your pi’s \(copy.name)").fontWeight(.semibold).foregroundColor(Color.sh.textPrimary)
                        + Text(" came over into Shepherd’s pi (\((copy.path as NSString).abbreviatingWithTildeInPath)), where every agent reads it. ")
                        + Text("Shepherd’s own \(model.file.fileName) is empty; use the copy here to edit it as Shepherd’s, without doubling it."))
                        .shText(size: SHPiSignInMetrics.noteProseSize, lineHeight: SHPiSignInMetrics.proseLeading)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .shTransition(.disclosure)
            }
            InstructionsEditorCard(model: model)
            if let problem = model.problem {
                SHInlineProblem(problem).shTransition(.disclosure)
            }
            if let hostID = model.comparing {
                InstructionsResolve(model: model, hostID: hostID).shTransition(.disclosure)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// `AGENTS.md` and `APPEND_SYSTEM.md` as underline tabs over a `lineSubtle` rule, each with
/// what it is for and its size.
private struct InstructionsFileTabs: View {
    var model: InstructionsModel

    var body: some View {
        HStack(alignment: .bottom, spacing: AppLayout.instructionsTabSpacing) {
            ForEach(InstructionFile.allCases, id: \.self) { file in
                tab(file)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { SHHairline() }
    }

    private func tab(_ file: InstructionFile) -> some View {
        let sh = Color.sh
        let chosen = model.file == file
        let note = InstructionsPresentation.fileNote(file, text: model.text(file, on: model.machine))
        return Button { model.file = file } label: {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(file.fileName)
                    .font(.shMono(AppLayout.instructionsTabNameSize, chosen ? .semibold : .medium))
                    .foregroundStyle(chosen ? sh.textPrimary : sh.textSecondary)
                Text(note)
                    .font(.shSans(AppLayout.instructionsTabNoteSize))
                    .foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xxs)
            .padding(.top, SH.Space.m)
            .padding(.bottom, SH.Space.m + SH.Space.xxs)
            .overlay(alignment: .bottom) {
                if chosen {
                    Rectangle().fill(sh.textPrimary).frame(height: AppLayout.instructionsTabUnderline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shFocusRing(radius: SH.Radius.xs)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The open file in a card: a header (its path, "● edited", History, Revert and Save; or, for a
/// host that differs, the comparison and Diff · its file), then the editor, the diff, or why the
/// file can't be shown.
private struct InstructionsEditorCard: View {
    @Bindable var model: InstructionsModel
    @State private var showsHistory = false

    private var file: InstructionFile { model.file }
    private var machine: InstructionsModel.Machine { model.machine }
    private var edited: Bool { model.isEdited(file, on: machine) }

    var body: some View {
        VStack(spacing: 0) {
            header
            SHHairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: AppLayout.instructionsEditorMinHeight, maxHeight: .infinity)
        .shCard(fill: Color.sh.bgWindow, line: Color.sh.lineStrong)
        .shAnimation(.hover, value: edited)
    }

    private var header: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            if let hostID = model.comparing {
                let name = model.name(of: .remote(hostID))
                let size = AppLayout.instructionsCompareSize
                let host = Text(verbatim: name).font(.shMono(size))
                let between = Text("compared with").foregroundStyle(sh.textTertiary)
                let mac = Text("This Mac").font(.shMono(size))
                Text("\(host) \(between) \(mac)")
                    .font(.shSans(size))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if !model.showsDiff, edited { editedMark }
                Spacer(minLength: SH.Space.m)
                SHSegmentedPicker("Compare", selection: $model.showsDiff, options: [(true, "Diff"), (false, "\(name)'s file")], size: .s)
                if !model.showsDiff { revertAndSave }
            } else {
                let path = model.path(of: file, on: machine) ?? model.name(of: machine)
                Text(path)
                    .font(.shMono(AppLayout.instructionsPathSize))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if edited { editedMark }
                Spacer(minLength: SH.Space.m)
                if model.sameEverywhere { history }
                revertAndSave
            }
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SH.Height.controlS + 2 * SH.Space.m)
        .background(sh.bgSunken)
    }

    private var editedMark: some View {
        Text("● edited")
            .font(.shSans(AppLayout.instructionsEditedSize))
            .foregroundStyle(Color.sh.lanternText)
            .lineLimit(1)
            .fixedSize()
            .shTransition(.disclosure)
    }

    /// This Mac's saves of the open file, each one restorable.
    private var history: some View {
        Button("History") { showsHistory.toggle() }
            .buttonStyle(.sh(.ghost, size: .s))
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                ScrollView(.vertical) {
                    InstructionsHistoryList(model: model, machine: .local, now: Date())
                        .padding(.horizontal, SH.Space.l)
                        .padding(.vertical, SH.Space.m)
                }
                .scrollIndicators(.hidden)
                .frame(width: AppLayout.instructionsHistoryPopoverWidth)
                .frame(maxHeight: AppLayout.instructionsHistoryPopoverMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.sh.bgRaised)
            }
    }

    /// Revert and the primary Save, which names where it writes; both wait for an edit.
    @ViewBuilder private var revertAndSave: some View {
        Button("Revert") { model.revert() }
            .buttonStyle(.sh(.ghost, size: .s))
            .disabled(!edited || model.busy)
        Button { Task { await model.save() } } label: {
            HStack(spacing: SH.Space.s) {
                Text(model.saveTitle)
                Text("⌘S")
                    .font(.shMono(AppLayout.instructionsShortcutSize))
                    .opacity(AppLayout.instructionsShortcutOpacity)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.sh(.primary, size: .s))
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.canSave)
    }

    @ViewBuilder private var content: some View {
        if let hostID = model.comparing, model.showsDiff {
            InstructionsDiffView(lines: InstructionsText.diff(from: model.saved(file, on: .local) ?? "",
                                                              to: model.saved(file, on: .remote(hostID)) ?? ""))
        } else if let saved = model.saved(file, on: machine) {
            let file = file
            let machine = machine
            InstructionsEditor(
                text: Binding(get: { model.text(file, on: machine) }, set: { model.setText($0, file: file, on: machine) }),
                saved: saved,
                accessibilityLabel: "\(file.fileName) on \(model.name(of: machine))"
            )
            .id(InstructionsModel.DraftKey(machine: machine, file: file))
        } else {
            InstructionsUnavailable(model: model)
        }
    }
}

/// Why a machine's files can't be shown: offline, too old, being read, or it couldn't answer.
private struct InstructionsUnavailable: View {
    var model: InstructionsModel

    var body: some View {
        let sh = Color.sh
        VStack(spacing: SH.Space.m) {
            if reading {
                ProgressView().progressViewStyle(.shSpinner).accessibilityHidden(true)
            }
            Text(message)
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .remote(let hostID) = model.machine, case .failed = model.files(of: hostID) {
                Button("Try again") { Task { await model.reload(hostID) } }
                    .buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .padding(SH.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reading: Bool {
        guard case .remote(let hostID) = model.machine else { return true }
        return model.files(of: hostID) == .checking
    }

    private var message: String {
        guard case .remote(let hostID) = model.machine else { return "Reading This Mac's files…" }
        let name = model.name(of: model.machine)
        return switch model.files(of: hostID) {
        case .offline: "\(name) is offline. Its files show here once it's connected."
        case .unsupported: "\(name) runs a Shepherd from before Instructions. Update it there to edit its files from here."
        case .failed(let reason): "Couldn't read \(name)'s files: \(reason)"
        case .checking, .loaded: "Reading \(name)'s files…"
        }
    }
}

/// A host's copy against This Mac's, as review diffs read: mono on 22pt lines, the line's number,
/// then removed lines `−` on `failedTint`, added lines `+` on `doneTint`, context unmarked.
private struct InstructionsDiffView: View {
    let lines: [InstructionsDiffLine]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        InstructionsDiffRow(line: line).id(index)
                    }
                }
                .padding(.vertical, SH.Space.m)
            }
            // The first difference in view, with a line of context above it.
            .onAppear {
                if let first = lines.firstIndex(where: { $0.kind != .context }) { reader.scrollTo(max(0, first - 1), anchor: .top) }
            }
        }
    }
}

private struct InstructionsDiffRow: View {
    let line: InstructionsDiffLine

    var body: some View {
        let sh = Color.sh
        HStack(spacing: 0) {
            Text("\(line.number)")
                .font(.shMono(AppLayout.instructionsNumberSize))
                .foregroundStyle(sh.textTertiary)
                .frame(width: AppLayout.instructionsGutterWidth, alignment: .trailing)
                .padding(.trailing, SH.Space.m)
            Text(sign)
                .font(.shMono(AppLayout.instructionsDiffTextSize))
                .foregroundStyle(line.kind == .added ? sh.done : sh.failed)
                .frame(width: AppLayout.instructionsDiffSignWidth, alignment: .leading)
            Text(line.text)
                .font(.shMono(AppLayout.instructionsDiffTextSize))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(line.text)
            Spacer(minLength: SH.Space.l)
        }
        .frame(minHeight: AppLayout.instructionsDiffLineHeight)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var sign: String {
        switch line.kind {
        case .context: ""
        case .added: "+"
        case .removed: "\u{2212}"
        }
    }

    private var background: Color {
        switch line.kind {
        case .context: .clear
        case .added: .sh.doneTint
        case .removed: .sh.failedTint
        }
    }

    private var accessibilityText: String {
        let lead = switch line.kind {
        case .context: "Line \(line.number)"
        case .added: "Added line \(line.number)"
        case .removed: "Removed line \(line.number)"
        }
        let text = line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "\(lead), blank" : "\(lead): \(text)"
    }
}

/// Per host, for a host whose copy differs: copy either way, or keep it different (remembered,
/// so the same difference is never flagged again).
private struct InstructionsResolve: View {
    var model: InstructionsModel
    let hostID: UUID

    var body: some View {
        let name = model.name(of: .remote(hostID))
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSectionHeader("Resolve", style: .settings).padding(.horizontal, SH.Space.xxs)
            SHFlowLayout(spacing: SH.Space.m) {
                Button("Copy This Mac's to \(name)") { Task { await model.copyThisMacs(to: hostID) } }
                    .buttonStyle(.sh(.secondary))
                Button("Copy \(name)'s to all hosts") { Task { await model.copyToAllHosts(from: hostID) } }
                    .buttonStyle(.sh(.secondary))
                Button("Keep \(name) different") { model.keepDifferent(hostID) }
                    .buttonStyle(.sh(.ghost))
            }
            .disabled(model.busy)
            SettingsNote(text: "A copy replaces \(model.file.fileName) there; the version it replaces stays in that host's history. "
                + "Keep a host different when a line only makes sense on it: Shepherd shows the difference once, then stops asking.")
                .padding(.horizontal, SH.Space.xxs)
        }
    }
}

// MARK: Side column

/// With Same on every host on, the order pi reads its instructions in; per host, each host's
/// files, the other file's status, and the chosen host's history.
private struct InstructionsSideColumn: View {
    var model: InstructionsModel
    let now: Date

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if model.sameEverywhere {
                    InstructionsReadingOrder(file: model.file)
                } else {
                    InstructionsHostsOverview(model: model, now: now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shTransition(.content)
        }
        .scrollIndicators(.hidden)
    }
}

/// How the agent reads them: five steps in order, each a small card joined to the next, the open
/// file's own step marked.
private struct InstructionsReadingOrder: View {
    let file: InstructionFile

    private var steps: [(title: String, note: String, file: InstructionFile?)] {
        [
            ("Agent’s system prompt", "built in", nil),
            ("Shepherd's AGENTS.md", (file == .agents ? "this file · " : "") + "every repo", .agents),
            ("AGENTS.md in parent folders", "if any", nil),
            ("the repo's AGENTS.md", "most specific context", nil),
            ("Shepherd's APPEND_SYSTEM.md", (file == .appendSystem ? "this file · " : "") + "appended last · wins", .appendSystem),
        ]
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSectionHeader("How the agent reads them", style: .settings).padding(.horizontal, SH.Space.xxs)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(sh.lineStrong)
                            .frame(width: AppLayout.instructionsStepConnectorWidth, height: AppLayout.instructionsStepConnectorHeight)
                            .padding(.leading, AppLayout.instructionsStepConnectorInset)
                            .accessibilityHidden(true)
                    }
                    stepCard(index + 1, title: step.title, note: step.note, marked: step.file == file)
                }
            }
            SettingsNote(text: "Later files win. pi's own files in Shepherd's pi home still load, each just before Shepherd's. "
                + "A session reads them when it starts: running agents keep the version they started with, "
                + "new agents and automations get this one.")
                .padding(.horizontal, SH.Space.xxs)
        }
    }

    private func stepCard(_ number: Int, title: String, note: String, marked: Bool) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Text("\(number)")
                .font(.shMono(AppLayout.instructionsNumberSize))
                .foregroundStyle(sh.textTertiary)
                .frame(width: AppLayout.instructionsStepNumberWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shMono(AppLayout.instructionsStepTitleSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(note)
                    .font(.shSans(AppLayout.instructionsStepNoteSize))
                    .foregroundStyle(sh.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SH.Space.m + SH.Space.xxs)
        .shCard(fill: marked ? sh.lanternTint : sh.bgRaised, line: marked ? sh.lanternText : sh.lineSubtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title), \(note)")
    }
}

/// Per host: a row per machine with where its files live and how the open file compares, the
/// other file's status in a line, and the chosen machine's saves of the open file.
private struct InstructionsHostsOverview: View {
    var model: InstructionsModel
    let now: Date

    var body: some View {
        let other = InstructionFile.allCases.first { $0 != model.file } ?? .appendSystem
        VStack(alignment: .leading, spacing: AppLayout.instructionsSideSpacing) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHSectionHeader("Files on each host", style: .settings).padding(.horizontal, SH.Space.xxs)
                VStack(spacing: 0) {
                    hostRow(.local)
                    ForEach(model.hosts, id: \.id) { host in
                        hostRow(.remote(host.id))
                    }
                }
            }
            if !model.hosts.isEmpty, let line = model.otherFileLine {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHSectionHeader(other.fileName, style: .settings).padding(.horizontal, SH.Space.xxs)
                    Text(line)
                        .shText(size: AppLayout.instructionsOtherFileSize, lineHeight: AppLayout.settingsFootnoteLineHeight)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SH.Space.xxs)
                }
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHSectionHeader("History · \(model.name(of: model.machine))", style: .settings).padding(.horizontal, SH.Space.xxs)
                InstructionsHistoryList(model: model, machine: model.machine, now: now)
            }
        }
    }

    private func hostRow(_ machine: InstructionsModel.Machine) -> some View {
        let sh = Color.sh
        let row = model.row(for: machine, now: now)
        let name = model.name(of: machine)
        let directory = model.directory(of: machine)
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: "desktopcomputer")
                .font(.shSans(AppLayout.instructionsHostGlyphSize))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name)
                    .font(.shMono(AppLayout.instructionsHostNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if let directory {
                    Text(directory)
                        .font(.shMono(AppLayout.instructionsHostDirectorySize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: SH.Space.m)
            VStack(alignment: .trailing, spacing: SH.Space.xxs) {
                Text(row.detail)
                    .font(.shSans(AppLayout.instructionsHostDetailSize))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if let note = row.note {
                    Text(note)
                        .font(.shSans(AppLayout.instructionsHostNoteSize))
                        .foregroundStyle(InstructionsHostChip.color(row.noteTone))
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: AppLayout.instructionsHostRowMinHeight)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// A machine's saves of the open file, newest first: the date, what changed, and Restore (the
/// newest is the file as it is, so it reads "current" instead).
private struct InstructionsHistoryList: View {
    var model: InstructionsModel
    let machine: InstructionsModel.Machine
    let now: Date

    var body: some View {
        let sh = Color.sh
        let entries = model.history(on: machine)
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text(model.saved(model.file, on: machine) == nil ? "Not read yet." : "No saves yet.")
                    .font(.shSans(AppLayout.instructionsHistoryTextSize))
                    .foregroundStyle(sh.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: AppLayout.instructionsHistoryRowMinHeight, alignment: .leading)
                    .overlay(alignment: .top) { SHHairline() }
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: SH.Space.m + SH.Space.xxs) {
                    Text(InstructionsPresentation.historyDate(entry.savedAt, now: now))
                        .font(.shMono(AppLayout.instructionsHistoryTextSize))
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: AppLayout.instructionsHistoryDateWidth, alignment: .leading)
                    Text(model.summary(of: entry))
                        .font(.shSans(AppLayout.instructionsHistoryTextSize))
                        .foregroundStyle(sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.summary(of: entry))
                    Spacer(minLength: SH.Space.m)
                    if index == 0 {
                        Text("current")
                            .font(.shSans(AppLayout.instructionsHistoryTextSize))
                            .foregroundStyle(sh.textTertiary)
                    } else {
                        Button("Restore") { Task { await model.restore(entry, on: machine) } }
                            .buttonStyle(.shLink(font: .shSans(AppLayout.instructionsHistoryTextSize)))
                            .disabled(model.busy)
                            .accessibilityLabel("Restore the version saved \(InstructionsPresentation.historyDate(entry.savedAt, now: now))")
                    }
                }
                .frame(minHeight: AppLayout.instructionsHistoryRowMinHeight)
                .overlay(alignment: .top) { SHHairline() }
            }
        }
    }
}
