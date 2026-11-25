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

    /// What each file is for, as its row's hint says.
    static func purpose(_ file: InstructionFile) -> String {
        file == .agents ? "how you work" : "overrides everything else"
    }

    var body: some View {
        Group {
            if model.editing { editor } else { list }
        }
        .task { await model.refresh() }
    }

    private var list: some View {
        SettingsPage(title: "Instructions") {
            if let problem = model.local?.historyProblem {
                SHInlineProblem(problem)
            }
            SettingsGroup(title: "Every agent reads", footnote: "Synced to every Mac in your fleet. A repo can add its own AGENTS.md.") {
                ForEach(InstructionFile.allCases, id: \.self) { file in
                    SettingsRow(title: file.fileName, subtitle: "\(Self.size(model.text(file))) · \(Self.purpose(file))", mono: true) {
                        HStack(spacing: SH.Space.s) {
                            SettingsOpenIn(text: Binding(get: { model.text(file) }, set: { model.setText($0, file: file) }), name: file.fileName)
                            Button("Edit") {
                                model.file = file
                                model.editing = true
                            }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .accessibilityLabel("Edit \(file.fileName)")
                        }
                    }
                }
            }
        }
    }

    private var editor: some View {
        SettingsPage(title: model.file.fileName) {
            InstructionsMainColumn(model: model)
        }
    }

    static func size(_ text: String) -> String {
        let bytes = text.utf8.count
        return bytes == 1 ? "1 byte" : "\(bytes) bytes"
    }
}

// MARK: Files

/// The open file's editor.
struct InstructionsMainColumn: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
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
            if let problem = model.local?.historyProblem ?? model.problem {
                SHInlineProblem(problem).shTransition(.disclosure)
            }
            InstructionsEditorCard(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The open file in the Settings editor card: its name, "● edited", History, Revert and Save, then the editor.
private struct InstructionsEditorCard: View {
    @Bindable var model: InstructionsModel
    @State private var showsHistory = false

    private var file: InstructionFile { model.file }
    private var edited: Bool { model.isEdited(file) }

    var body: some View {
        SettingsEditorCard(name: file.fileName, edited: edited,
                           openIn: Binding(get: { model.text(file) }, set: { model.setText($0, file: file) })) {
            history
            revertAndSave
        } content: {
            content
        }
        .help(model.path(of: file) ?? "")
    }

    /// The open file's saves, each one restorable (a save another Mac made is there too).
    private var history: some View {
        Button("History") { showsHistory.toggle() }
            .buttonStyle(.sh(.secondary, size: .s))
            .disabled(model.local?.historyProblem != nil)
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
            .buttonStyle(.sh(.secondary, size: .s))
            .disabled(!edited || model.busy)
        Button { Task { await model.save() } } label: { Text("Save") }
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
                Text("Reading This Mac's files…")
                    .font(.sh(.caption))
                    .shShimmer(active: true)
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
