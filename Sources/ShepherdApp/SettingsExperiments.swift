import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Experiments (SettingsExperiments): features still being tried, each off until the
/// user turns it on. Suggested instructions, the Design tool, conversation Goals and Projects each
/// keep their own switch. A wide page: the experiment and what waits for the user, beside a
/// 320pt side column (how it works, what was added, and a note about experiments).
struct ExperimentsSettings: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    /// This Mac's experiment switches.
    var settings: AppSettings
    /// A mission is planning, running or publishing: Missions can't be turned off under it.
    var missionsActive = false
    /// Opens Settings ▸ Instructions (where the lines go).
    let openInstructions: () -> Void

    static let feedbackURL = URL(string: "https://github.com/bailycase/shepherd/issues/new?title=Suggested%20instructions%3A%20")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsWideBlockSpacing) {
            SettingsHeader(title: "Experiments", explanation: "Features we're still trying out. Each is off until you turn it on.")
                .frame(maxWidth: AppLayout.settingsWideHeaderWidth, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: AppLayout.experimentsColumnSpacing) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: AppLayout.experimentsBlockSpacing) {
                            SuggestedInstructionsCard(model: model, instructions: instructions, openInstructions: openInstructions)
                            DesignToolCard(settings: settings)
                            GoalExperimentCard(settings: settings)
                            ProjectsExperimentCard(settings: settings)
                            MissionsExperimentCard(settings: settings, active: missionsActive)
                            if model.settings.enabled || !model.snapshot.waiting.isEmpty {
                                WaitingSuggestions(model: model, instructions: instructions, now: context.date)
                                    .shTransition(.disclosure)
                            }
                            if let problem = model.problem {
                                SHInlineProblem(problem).shTransition(.disclosure)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    ScrollView(.vertical) {
                        ExperimentsSideColumn(model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: AppLayout.experimentsSideWidth)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .shAnimation(.disclosure, value: model.settings.enabled)
        .shAnimation(.list, value: model.snapshot.waiting.map(\.id))
        .task { await model.refresh() }
    }
}

// MARK: The experiments

/// The Design tool's card: its tile, name, description and switch. It has no options; on, the
/// sidebar gains Designs, Recents shows designs, and New thread offers "Start a design".
private struct DesignToolCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay {
                    Image(systemName: "pencil.tip")
                        .font(.shSans(AppLayout.experimentGlyphSize))
                        .foregroundStyle(sh.lanternText)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Design tool")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Describe a page or flow and a design agent draws it as HTML boards on a canvas you pan and zoom. "
                     + "Adds Designs to the sidebar and “Start a design” to New thread.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Design tool", isOn: $settings.designToolEnabled)
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }
}

/// Goals uses the existing two-ring mark and experiment card, with no budget options.
private struct GoalExperimentCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay { SHGoalGlyph().foregroundStyle(sh.lanternText) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Goals")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Keep a conversation working toward a condition you set with /goal. No time or token budgets. Turning this off pauses active goals without clearing them.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Goals", isOn: $settings.goalsEnabled)
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }
}

/// Projects uses the product's Project mark and the experiment card, with no options. Off hides every Project entry point and
/// pauses project work; the projects and their files stay.
private struct ProjectsExperimentCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay { SHProjectGlyphView(tint: sh.lanternText, size: AppLayout.experimentGlyphSize) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Projects")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Coordinate work across threads and spaces. Turning this off pauses project work and keeps your projects and files.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Projects", isOn: $settings.projectsEnabled)
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }
}

/// Missions' card. Off hides the Missions destination and its sidebar section; missions and their
/// receipts are kept, and their threads never join the thread lists either way. It can't be turned
/// off while a mission works, so no planning, work or publication runs out of sight.
struct MissionsExperimentCard: View {
    @Bindable var settings: AppSettings
    let active: Bool

    /// On and something is working: the switch holds.
    var locked: Bool { settings.missionsEnabled && active }

    var body: some View {
        let nw = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(nw.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay {
                    SHGlyph.mission.image
                        .font(.shSans(AppLayout.experimentGlyphSize))
                        .foregroundStyle(nw.lanternText)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Missions")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                Text("Describe an end state across your repositories; a planner maps it, agents do the work, independent checks validate it, and you publish the pull requests. "
                     + "Adds Missions to the sidebar. Turning this off hides them and keeps your missions and files.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if locked {
                    Text("Pause or stop running missions before turning this off.")
                        .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                        .foregroundStyle(nw.lanternText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Missions", isOn: $settings.missionsEnabled)
                .disabled(locked)
                .help(locked ? "Pause or stop running missions before turning this off." : "Missions")
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: nw.bgWindow, line: nw.lineStrong)
    }
}

/// Suggested instructions' card: its tile, name, "on since" tag, description and switch, and
/// while it is on, what it learns from, what it may suggest for, and where the lines go.
private struct SuggestedInstructionsCard: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    let openInstructions: () -> Void

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
                RoundedRectangle(cornerRadius: SH.Radius.m)
                    .fill(sh.lanternTint)
                    .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                    .overlay {
                        Image(systemName: "flask")
                            .font(.shSans(AppLayout.experimentGlyphSize))
                            .foregroundStyle(sh.lanternText)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    HStack(spacing: SH.Space.m) {
                        Text("Suggested instructions")
                            .font(.shSans(AppLayout.experimentNameSize, .semibold))
                            .foregroundStyle(sh.textPrimary)
                        if let since = SuggestionsPresentation.sinceTag(model.settings) {
                            Text(since)
                                .font(.shMono(AppLayout.experimentTagSize))
                                .foregroundStyle(sh.lanternText)
                                .padding(.horizontal, SH.Space.s)
                                .frame(height: AppLayout.experimentTagHeight)
                                .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                                .shTransition(.disclosure)
                        }
                    }
                    Text("When an agent learns something the hard way (a re-run, a failed check, a correction from you) it "
                         + "drafts one line for your root instructions. Nothing is written until you add it.")
                        .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                        .foregroundStyle(sh.textSecondary)
                        .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SH.Space.xxl)
                SettingsSwitch(label: "Suggested instructions",
                               isOn: Binding(get: { model.settings.enabled }, set: { on in Task { await model.setEnabled(on) } }))
                    .disabled(model.busy)
            }
            .padding(.vertical, SH.Space.l + SH.Space.xxs)
            .padding(.horizontal, SH.Space.xl)

            if model.settings.enabled {
                VStack(spacing: 0) {
                    ExperimentOptionRow(title: "Learn from", note: "Where agents may notice a lesson.") {
                        checkbox("Threads", on: model.settings.sources.contains(.thread)) { await model.setLearns(from: .thread, $0) }
                        checkbox("Automations", on: model.settings.sources.contains(.automation)) { await model.setLearns(from: .automation, $0) }
                    }
                    ExperimentOptionRow(title: "Can suggest for",
                                        note: "APPEND_SYSTEM.md overrides everything else, so it stays off unless you want it.") {
                        ForEach(InstructionFile.allCases, id: \.self) { file in
                            checkbox(file.fileName, on: model.settings.files.contains(file)) { await model.setSuggests(for: file, $0) }
                        }
                    }
                    ExperimentOptionRow(title: "Hosts",
                                        note: "Lines go where Settings › Instructions sends them: right now that's "
                                            + (instructions.sameEverywhere ? "every host." : "This Mac alone.")) {
                        Button("Open Instructions", action: openInstructions)
                            .buttonStyle(.shLink(font: .shSans(AppLayout.experimentOptionNoteSize)))
                    }
                }
                .disabled(model.busy)
                .background(sh.bgBase)
                .shTransition(.disclosure)
            }
        }
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }

    private func checkbox(_ title: String, on: Bool, change: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { value in Task { await change(value) } })) {
            Text(title)
                .font(.shSans(AppLayout.suggestionNameSize))
                .foregroundStyle(Color.sh.textPrimary)
        }
        .toggleStyle(.shCheckbox)
    }
}

/// One of an experiment's options: a 13/500 title over a 12 note, the controls trailing, a
/// hairline above each (the first one parts the options from the card's top).
private struct ExperimentOptionRow<Control: View>: View {
    let title: String
    let note: String
    @ViewBuilder var control: Control

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxl) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shSans(AppLayout.experimentOptionTitleSize, .medium))
                    .foregroundStyle(sh.textPrimary)
                Text(note)
                    .shText(size: AppLayout.experimentOptionNoteSize, lineHeight: AppLayout.experimentOptionNoteLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppLayout.experimentCheckboxSpacing) { control }
        }
        // As a Settings row: the content at least 48pt, 10pt inside the top and bottom.
        .frame(minHeight: AppLayout.experimentOptionMinHeight)
        .padding(.vertical, SHCardRowMetrics.settingsVerticalPadding)
        .padding(.horizontal, SH.Space.xl)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Waiting for you

/// The drafted lines, newest first, with Add all.
private struct WaitingSuggestions: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    let now: Date

    var body: some View {
        let waiting = model.snapshot.waiting
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSectionHeader(SuggestionsPresentation.waitingTitle(waiting.count), style: .settings) {
                if waiting.count > 1 {
                    Button("Add all") { Task { await model.addAll() } }
                        .buttonStyle(.shLink(font: .shSans(AppLayout.suggestionOriginSize)))
                        .disabled(model.busy)
                }
            }
            .padding(.horizontal, SH.Space.xxs)
            if waiting.isEmpty {
                Text("Nothing is waiting. When an agent learns something the hard way, its line shows up here.")
                    .shText(size: AppLayout.settingsFootnoteSize, lineHeight: AppLayout.settingsFootnoteLineHeight)
                    .foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xxs)
            }
            ForEach(waiting) { suggestion in
                SuggestionCard(model: model, suggestion: suggestion,
                               hosts: SuggestionsPresentation.hostsWord(sameEverywhere: instructions.sameEverywhere), now: now)
                    .shTransition(.list)
            }
        }
    }
}

/// One drafted line: where it came from and where it would go, the line as it would be added,
/// why, and what to do with it.
private struct SuggestionCard: View {
    var model: SuggestionsModel
    let suggestion: InstructionSuggestion
    let hosts: String
    let now: Date

    @FocusState private var fieldFocused: Bool

    private var file: InstructionFile { model.file(for: suggestion) }
    private var editing: String? { model.edits[suggestion.id] }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                    .font(.shSans(AppLayout.suggestionGlyphSize))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
                Text(suggestion.source.name)
                    .font(.shSans(AppLayout.suggestionNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Text(SuggestionsPresentation.origin(suggestion, now: now))
                    .font(.shSans(AppLayout.suggestionOriginSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                target
            }
            if let editing {
                TextField("Line", text: Binding(get: { editing }, set: { model.setEdit($0, for: suggestion) }))
                    .textFieldStyle(.sh(mono: true))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit { Task { await model.add(suggestion) } }
            } else {
                Text(Self.addedLine(suggestion.line))
                    .shText(size: AppLayout.suggestionLineSize, mono: true, lineHeight: AppLayout.suggestionLineHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SH.Space.s)
                    .padding(.horizontal, SH.Space.m + SH.Space.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sh.doneTint, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                    .accessibilityLabel("Adds: \(SuggestionsPresentation.plainLine(suggestion.line))")
            }
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(suggestion.reason)
                    .shText(size: AppLayout.suggestionReasonSize, lineHeight: AppLayout.suggestionReasonLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editing != nil {
                    Button("Cancel") { model.cancelEdit(suggestion) }
                        .buttonStyle(.sh(.ghost, size: .s))
                } else {
                    Button("Dismiss") { Task { await model.dismiss(suggestion) } }
                        .buttonStyle(.sh(.ghost, size: .s))
                    Button("Edit first") { model.edit(suggestion) }
                        .buttonStyle(.sh(.ghost, size: .s))
                }
                Button(SuggestionsPresentation.addTitle(file)) { Task { await model.add(suggestion) } }
                    .buttonStyle(.sh(.secondary, size: .s))
            }
            .disabled(model.busy)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .shCard(fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
    }

    /// The chip that says where the line goes, and retargets its file.
    private var target: some View {
        let sh = Color.sh
        return Menu {
            ForEach(InstructionFile.allCases, id: \.self) { option in
                Button { model.retarget(suggestion, to: option) } label: {
                    if option == file { Label(option.fileName, systemImage: "checkmark") } else { Text(option.fileName) }
                }
            }
        } label: {
            HStack(spacing: SH.Space.s) {
                Image(systemName: SHGlyph.document.symbolName)
                    .font(.shSans(AppLayout.suggestionTargetGlyphSize))
                    .foregroundStyle(sh.textSecondary)
                Text(file.fileName)
                    .font(.shMono(AppLayout.suggestionTargetSize))
                    .foregroundStyle(sh.textPrimary)
                Text("·")
                    .font(.shSans(AppLayout.suggestionTargetSize))
                    .foregroundStyle(sh.textTertiary)
                Image(systemName: "desktopcomputer")
                    .font(.shSans(AppLayout.suggestionTargetGlyphSize))
                    .foregroundStyle(sh.textSecondary)
                Text(hosts)
                    .font(.shSans(AppLayout.suggestionTargetSize))
                    .foregroundStyle(sh.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.shSans(AppLayout.suggestionChevronSize, .semibold))
                    .foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: AppLayout.suggestionTargetHeight)
            .shBorder(sh.lineStrong, radius: SH.Radius.s)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Adds to \(file.fileName), \(hosts)")
        .help("Choose the file this line goes to")
    }

    /// "+ " in `done`, then the line's light Markdown: its bullet in `lanternText`, code spans in
    /// `synString`, the rest `textPrimary`.
    @MainActor static func addedLine(_ line: String) -> AttributedString {
        var result = AttributedString("+ ")
        result.foregroundColor = Color.sh.done
        var body = AttributedString(line)
        body.foregroundColor = Color.sh.textPrimary
        let units = line.utf16
        for span in InstructionsText.highlight(line: line) {
            guard let lower = units.index(units.startIndex, offsetBy: span.range.lowerBound, limitedBy: units.endIndex),
                  let upper = units.index(units.startIndex, offsetBy: span.range.upperBound, limitedBy: units.endIndex),
                  let from = AttributedString.Index(lower, within: body),
                  let to = AttributedString.Index(upper, within: body) else { continue }
            switch span.role {
            case .bullet, .headingMarker: body[from..<to].foregroundColor = Color.sh.lanternText
            case .code: body[from..<to].foregroundColor = Color.sh.synString
            case .heading: break
            }
        }
        result.append(body)
        return result
    }
}

// MARK: Side column

/// How it works, what was added from suggestions, and a note about experiments.
private struct ExperimentsSideColumn: View {
    var model: SuggestionsModel
    @Environment(\.openURL) private var openURL

    private static let steps: [(lead: String, rest: String)] = [
        ("An agent hits something it had to learn", "a re-run, a red check, or you telling it no."),
        ("It drafts one line", "for a root file, with the reason."),
        ("You decide", "Add it, edit it first, or dismiss it. Dismissed lines aren't suggested again."),
    ]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: AppLayout.experimentsSideSpacing) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHSectionHeader("How it works", style: .settings).padding(.horizontal, SH.Space.xxs)
                VStack(spacing: 0) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m + SH.Space.xxs) {
                            Text("\(index + 1)")
                                .font(.shMono(AppLayout.instructionsNumberSize))
                                .foregroundStyle(sh.textSecondary)
                                .frame(width: AppLayout.experimentStepRing, height: AppLayout.experimentStepRing)
                                .shBorder(sh.lineStrong, in: Circle())
                            let lead = Text(step.lead).font(.shSans(AppLayout.experimentStepTextSize, .semibold)).foregroundStyle(sh.textPrimary)
                            let rest = Text(step.rest).foregroundStyle(sh.textSecondary)
                            Text("\(lead) \(rest)")
                                .shText(size: AppLayout.experimentStepTextSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, SH.Space.m)
                        .overlay(alignment: .top) { if index > 0 { SHHairline() } }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !model.snapshot.added.isEmpty {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHSectionHeader("Added from suggestions", style: .settings).padding(.horizontal, SH.Space.xxs)
                    VStack(spacing: 0) {
                        ForEach(model.snapshot.added) { added in
                            HStack(spacing: SH.Space.m + SH.Space.xxs) {
                                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                    Text(SuggestionsPresentation.plainLine(added.line))
                                        .font(.shSans(AppLayout.addedLineSize))
                                        .foregroundStyle(sh.textPrimary)
                                        .lineLimit(2)
                                    Text(SuggestionsPresentation.addedNote(added))
                                        .font(.shSans(AppLayout.addedNoteSize))
                                        .foregroundStyle(sh.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: SH.Space.m)
                                Button("Undo") { Task { await model.undo(added) } }
                                    .buttonStyle(.shLink(font: .shSans(AppLayout.suggestionOriginSize)))
                                    .disabled(model.busy)
                                    .accessibilityLabel("Undo: take “\(SuggestionsPresentation.plainLine(added.line))” out of \(added.file.fileName)")
                            }
                            .padding(.vertical, SH.Space.s)
                            .frame(minHeight: AppLayout.addedRowMinHeight)
                            .overlay(alignment: .top) { SHHairline() }
                            .shTransition(.list)
                        }
                    }
                }
                .shTransition(.disclosure)
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHSectionHeader("About experiments", style: .settings).padding(.horizontal, SH.Space.xxs)
                SettingsNote(text: "Experiments can change or go away. Turning this one off keeps the lines you added and drops what's waiting.")
                    .padding(.horizontal, SH.Space.xxs)
                Button { openURL(ExperimentsSettings.feedbackURL) } label: {
                    Label("Send feedback", systemImage: "bubble.left")
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .padding(.horizontal, SH.Space.xxs)
                .help("Opens a new issue for Shepherd on GitHub")
            }
        }
        .shAnimation(.list, value: model.snapshot.added.map(\.id))
    }
}
