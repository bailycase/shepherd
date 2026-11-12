import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Instructions (SettingsInstructions): the root instructions Shepherd hands every pi it
/// starts, `AGENTS.md` and `APPEND_SYSTEM.md`. They are the fleet's: one copy that every Mac holds,
/// so the page has no host to pick. A wide page: the header, then the open file's editor beside a
/// 330pt side column (how pi reads the files).
struct InstructionsSettings: View {
    @Bindable var model: InstructionsModel

    static let explanation = "The agent’s root files, read at the start of every session Shepherd starts: `AGENTS.md` for how "
        + "you work, `APPEND_SYSTEM.md` for rules that override everything else. Repos can still add their own AGENTS.md."

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsWideBlockSpacing) {
            SettingsHeader(title: "Instructions", explanation: Self.explanation)
                .frame(maxWidth: AppLayout.settingsWideHeaderWidth, alignment: .leading)
            HStack(alignment: .top, spacing: AppLayout.instructionsColumnSpacing) {
                InstructionsMainColumn(model: model)
                InstructionsSideColumn(file: model.file)
                    .frame(width: AppLayout.instructionsSideWidth)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .task { await model.refresh() }
    }
}

// MARK: Files

/// The file tabs and the open file's editor.
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
        let note = InstructionsPresentation.fileNote(file, text: model.text(file))
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

/// The open file in a card: a header (its path, "● edited", History, Revert and Save), then the editor.
private struct InstructionsEditorCard: View {
    @Bindable var model: InstructionsModel
    @State private var showsHistory = false

    private var file: InstructionFile { model.file }
    private var edited: Bool { model.isEdited(file) }

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
            let path = model.path(of: file) ?? "This Mac"
            Text(path)
                .font(.shMono(AppLayout.instructionsPathSize))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if edited { editedMark }
            Spacer(minLength: SH.Space.m)
            history
            revertAndSave
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

    /// The open file's saves, each one restorable (a save another Mac made is there too).
    private var history: some View {
        Button("History") { showsHistory.toggle() }
            .buttonStyle(.sh(.ghost, size: .s))
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                ScrollView(.vertical) {
                    InstructionsHistoryList(model: model, now: Date())
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

    /// Revert and the primary Save; both wait for an edit.
    @ViewBuilder private var revertAndSave: some View {
        Button("Revert") { model.revert() }
            .buttonStyle(.sh(.ghost, size: .s))
            .disabled(!edited || model.busy)
        Button { Task { await model.save() } } label: {
            HStack(spacing: SH.Space.s) {
                Text("Save")
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
        if let saved = model.saved(file) {
            let file = file
            InstructionsEditor(
                text: Binding(get: { model.text(file) }, set: { model.setText($0, file: file) }),
                saved: saved,
                accessibilityLabel: file.fileName
            )
            .id(file)
        } else {
            VStack(spacing: SH.Space.m) {
                ProgressView().progressViewStyle(.shSpinner).accessibilityHidden(true)
                Text("Reading This Mac's files…")
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Side column

/// How pi reads the files.
private struct InstructionsSideColumn: View {
    let file: InstructionFile

    var body: some View {
        ScrollView(.vertical) {
            InstructionsReadingOrder(file: file)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// The open file's saves, newest first: the date, what changed, and Restore (the newest is the
/// file as it is, so it reads "current" instead).
private struct InstructionsHistoryList: View {
    var model: InstructionsModel
    let now: Date

    var body: some View {
        let sh = Color.sh
        let entries = model.history()
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text(model.saved(model.file) == nil ? "Not read yet." : "No saves yet.")
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
                    Text(entry.summary)
                        .font(.shSans(AppLayout.instructionsHistoryTextSize))
                        .foregroundStyle(sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.summary)
                    Spacer(minLength: SH.Space.m)
                    if index == 0 {
                        Text("current")
                            .font(.shSans(AppLayout.instructionsHistoryTextSize))
                            .foregroundStyle(sh.textTertiary)
                    } else {
                        Button("Restore") { Task { await model.restore(entry) } }
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


/// A machine's chip: a `desktopcomputer` glyph, the name in mono, a state dot, and the state's
/// word unless the dot says it all. The chosen machine has a `textPrimary` line on `bgSelected`.
/// Projects' host choice draws it (Settings ▸ Instructions no longer has chips: its files are the fleet's).
struct InstructionsHostChip: View {
    let name: String
    let chip: InstructionsChip
    let selected: Bool
    /// A chip that picks a machine, or only reports when nil.
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
