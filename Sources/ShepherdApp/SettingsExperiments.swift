import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Experiments (SettingsExperiments): features still being tried, each off until the
/// user turns it on. Its one experiment is Suggested instructions: agents draft a line for the
/// root instructions after learning something the hard way, and the user adds it, edits it
/// first, or dismisses it. A wide page: the experiment and what waits for the user, beside a
/// 320pt side column (how it works, what was added, and a note about experiments).
struct ExperimentsSettings: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    /// The Design tool's switch.
    var settings: AppSettings
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
                            if model.settings.enabled || !model.snapshot.waiting.isEmpty {
                                WaitingSuggestions(model: model, instructions: instructions, now: context.date)
                                    .nwTransition(.disclosure)
                            }
                            if let problem = model.problem {
                                NWInlineProblem(problem).nwTransition(.disclosure)
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
        .nwAnimation(.disclosure, value: model.settings.enabled)
        .nwAnimation(.list, value: model.snapshot.waiting.map(\.id))
        .task { await model.refresh() }
    }
}

// MARK: The experiments

/// The Design tool's card: its tile, name, description and switch. It has no options; on, the
/// sidebar gains Designs, Recents shows designs, and New thread offers "Start a design".
private struct DesignToolCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let nw = Color.nw
        HStack(alignment: .top, spacing: NW.Space.l + NW.Space.xxs) {
            RoundedRectangle(cornerRadius: NW.Radius.m)
                .fill(nw.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay {
                    Image(systemName: "pencil.tip")
                        .font(.nwSans(AppLayout.experimentGlyphSize))
                        .foregroundStyle(nw.lanternText)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text("Design tool")
                    .font(.nwSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                Text("Describe a page or flow and a design agent draws it as HTML boards on a canvas you pan and zoom. "
                     + "Adds Designs to the sidebar and “Start a design” to New thread.")
                    .nwText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NW.Space.xxl)
            SettingsSwitch(label: "Design tool", isOn: $settings.designToolEnabled)
        }
        .padding(.vertical, NW.Space.l + NW.Space.xxs)
        .padding(.horizontal, NW.Space.xl)
        .nwCard(fill: nw.bgWindow, line: nw.lineStrong)
    }
}

/// Suggested instructions' card: its tile, name, "on since" tag, description and switch, and
/// while it is on, what it learns from, what it may suggest for, and where the lines go.
private struct SuggestedInstructionsCard: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    let openInstructions: () -> Void

    var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: NW.Space.l + NW.Space.xxs) {
                RoundedRectangle(cornerRadius: NW.Radius.m)
                    .fill(nw.lanternTint)
                    .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                    .overlay {
                        Image(systemName: "flask")
                            .font(.nwSans(AppLayout.experimentGlyphSize))
                            .foregroundStyle(nw.lanternText)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    HStack(spacing: NW.Space.m) {
                        Text("Suggested instructions")
                            .font(.nwSans(AppLayout.experimentNameSize, .semibold))
                            .foregroundStyle(nw.textPrimary)
                        if let since = SuggestionsPresentation.sinceTag(model.settings) {
                            Text(since)
                                .font(.nwMono(AppLayout.experimentTagSize))
                                .foregroundStyle(nw.lanternText)
                                .padding(.horizontal, NW.Space.s)
                                .frame(height: AppLayout.experimentTagHeight)
                                .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                                .nwTransition(.disclosure)
                        }
                    }
                    Text("When an agent learns something the hard way (a re-run, a failed check, a correction from you) it "
                         + "drafts one line for your root instructions. Nothing is written until you add it.")
                        .nwText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                        .foregroundStyle(nw.textSecondary)
                        .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NW.Space.xxl)
                SettingsSwitch(label: "Suggested instructions",
                               isOn: Binding(get: { model.settings.enabled }, set: { on in Task { await model.setEnabled(on) } }))
                    .disabled(model.busy)
            }
            .padding(.vertical, NW.Space.l + NW.Space.xxs)
            .padding(.horizontal, NW.Space.xl)

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
                            .buttonStyle(.nwLink(font: .nwSans(AppLayout.experimentOptionNoteSize)))
                    }
                }
                .disabled(model.busy)
                .background(nw.bgBase)
                .nwTransition(.disclosure)
            }
        }
        .nwCard(fill: nw.bgWindow, line: nw.lineStrong)
    }

    private func checkbox(_ title: String, on: Bool, change: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { value in Task { await change(value) } })) {
            Text(title)
                .font(.nwSans(AppLayout.suggestionNameSize))
                .foregroundStyle(Color.nw.textPrimary)
        }
        .toggleStyle(.nwCheckbox)
    }
}

/// One of an experiment's options: a 13/500 title over a 12 note, the controls trailing, a
/// hairline above each (the first one parts the options from the card's top).
private struct ExperimentOptionRow<Control: View>: View {
    let title: String
    let note: String
    @ViewBuilder var control: Control

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.xxl) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(.nwSans(AppLayout.experimentOptionTitleSize, .medium))
                    .foregroundStyle(nw.textPrimary)
                Text(note)
                    .nwText(size: AppLayout.experimentOptionNoteSize, lineHeight: AppLayout.experimentOptionNoteLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppLayout.experimentCheckboxSpacing) { control }
        }
        // As a Settings row: the content at least 48pt, 10pt inside the top and bottom.
        .frame(minHeight: AppLayout.experimentOptionMinHeight)
        .padding(.vertical, NWCardRowMetrics.settingsVerticalPadding)
        .padding(.horizontal, NW.Space.xl)
        .overlay(alignment: .top) { NWHairline() }
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
        VStack(alignment: .leading, spacing: NW.Space.m) {
            NWSectionHeader(SuggestionsPresentation.waitingTitle(waiting.count), style: .settings) {
                if waiting.count > 1 {
                    Button("Add all") { Task { await model.addAll() } }
                        .buttonStyle(.nwLink(font: .nwSans(AppLayout.suggestionOriginSize)))
                        .disabled(model.busy)
                }
            }
            .padding(.horizontal, NW.Space.xxs)
            if waiting.isEmpty {
                Text("Nothing is waiting. When an agent learns something the hard way, its line shows up here.")
                    .nwText(size: AppLayout.settingsFootnoteSize, lineHeight: AppLayout.settingsFootnoteLineHeight)
                    .foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, NW.Space.xxs)
            }
            ForEach(waiting) { suggestion in
                SuggestionCard(model: model, suggestion: suggestion,
                               hosts: SuggestionsPresentation.hostsWord(sameEverywhere: instructions.sameEverywhere), now: now)
                    .nwTransition(.list)
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                    .font(.nwSans(AppLayout.suggestionGlyphSize))
                    .foregroundStyle(nw.textSecondary)
                    .accessibilityHidden(true)
                Text(suggestion.source.name)
                    .font(.nwSans(AppLayout.suggestionNameSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                Text(SuggestionsPresentation.origin(suggestion, now: now))
                    .font(.nwSans(AppLayout.suggestionOriginSize))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.m)
                target
            }
            if let editing {
                TextField("Line", text: Binding(get: { editing }, set: { model.setEdit($0, for: suggestion) }))
                    .textFieldStyle(.nw(mono: true))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit { Task { await model.add(suggestion) } }
            } else {
                Text(Self.addedLine(suggestion.line))
                    .nwText(size: AppLayout.suggestionLineSize, mono: true, lineHeight: AppLayout.suggestionLineHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NW.Space.s)
                    .padding(.horizontal, NW.Space.m + NW.Space.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(nw.doneTint, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .accessibilityLabel("Adds: \(SuggestionsPresentation.plainLine(suggestion.line))")
            }
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Text(suggestion.reason)
                    .nwText(size: AppLayout.suggestionReasonSize, lineHeight: AppLayout.suggestionReasonLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editing != nil {
                    Button("Cancel") { model.cancelEdit(suggestion) }
                        .buttonStyle(.nw(.ghost, size: .s))
                } else {
                    Button("Dismiss") { Task { await model.dismiss(suggestion) } }
                        .buttonStyle(.nw(.ghost, size: .s))
                    Button("Edit first") { model.edit(suggestion) }
                        .buttonStyle(.nw(.ghost, size: .s))
                }
                Button(SuggestionsPresentation.addTitle(file)) { Task { await model.add(suggestion) } }
                    .buttonStyle(.nw(.secondary, size: .s))
            }
            .disabled(model.busy)
        }
        .padding(.vertical, NW.Space.l)
        .padding(.horizontal, NW.Space.l + NW.Space.xxs)
        .nwCard(fill: nw.bgRaised, line: nw.lineSubtle)
        .accessibilityElement(children: .contain)
    }

    /// The chip that says where the line goes, and retargets its file.
    private var target: some View {
        let nw = Color.nw
        return Menu {
            ForEach(InstructionFile.allCases, id: \.self) { option in
                Button { model.retarget(suggestion, to: option) } label: {
                    if option == file { Label(option.fileName, systemImage: "checkmark") } else { Text(option.fileName) }
                }
            }
        } label: {
            HStack(spacing: NW.Space.s) {
                Image(systemName: "doc.text")
                    .font(.nwSans(AppLayout.suggestionTargetGlyphSize))
                    .foregroundStyle(nw.textSecondary)
                Text(file.fileName)
                    .font(.nwMono(AppLayout.suggestionTargetSize))
                    .foregroundStyle(nw.textPrimary)
                Text("·")
                    .font(.nwSans(AppLayout.suggestionTargetSize))
                    .foregroundStyle(nw.textTertiary)
                Image(systemName: "desktopcomputer")
                    .font(.nwSans(AppLayout.suggestionTargetGlyphSize))
                    .foregroundStyle(nw.textSecondary)
                Text(hosts)
                    .font(.nwSans(AppLayout.suggestionTargetSize))
                    .foregroundStyle(nw.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.nwSans(AppLayout.suggestionChevronSize, .semibold))
                    .foregroundStyle(nw.textTertiary)
            }
            .padding(.horizontal, NW.Space.m)
            .frame(height: AppLayout.suggestionTargetHeight)
            .nwBorder(nw.lineStrong, radius: NW.Radius.s)
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
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
        result.foregroundColor = Color.nw.done
        var body = AttributedString(line)
        body.foregroundColor = Color.nw.textPrimary
        let units = line.utf16
        for span in InstructionsText.highlight(line: line) {
            guard let lower = units.index(units.startIndex, offsetBy: span.range.lowerBound, limitedBy: units.endIndex),
                  let upper = units.index(units.startIndex, offsetBy: span.range.upperBound, limitedBy: units.endIndex),
                  let from = AttributedString.Index(lower, within: body),
                  let to = AttributedString.Index(upper, within: body) else { continue }
            switch span.role {
            case .bullet, .headingMarker: body[from..<to].foregroundColor = Color.nw.lanternText
            case .code: body[from..<to].foregroundColor = Color.nw.synString
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: AppLayout.experimentsSideSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                NWSectionHeader("How it works", style: .settings).padding(.horizontal, NW.Space.xxs)
                VStack(spacing: 0) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m + NW.Space.xxs) {
                            Text("\(index + 1)")
                                .font(.nwMono(AppLayout.instructionsNumberSize))
                                .foregroundStyle(nw.textSecondary)
                                .frame(width: AppLayout.experimentStepRing, height: AppLayout.experimentStepRing)
                                .nwBorder(nw.lineStrong, in: Circle())
                            let lead = Text(step.lead).font(.nwSans(AppLayout.experimentStepTextSize, .semibold)).foregroundStyle(nw.textPrimary)
                            let rest = Text(step.rest).foregroundStyle(nw.textSecondary)
                            Text("\(lead) \(rest)")
                                .nwText(size: AppLayout.experimentStepTextSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, NW.Space.m)
                        .overlay(alignment: .top) { if index > 0 { NWHairline() } }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !model.snapshot.added.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWSectionHeader("Added from suggestions", style: .settings).padding(.horizontal, NW.Space.xxs)
                    VStack(spacing: 0) {
                        ForEach(model.snapshot.added) { added in
                            HStack(spacing: NW.Space.m + NW.Space.xxs) {
                                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                    Text(SuggestionsPresentation.plainLine(added.line))
                                        .font(.nwSans(AppLayout.addedLineSize))
                                        .foregroundStyle(nw.textPrimary)
                                        .lineLimit(2)
                                    Text(SuggestionsPresentation.addedNote(added))
                                        .font(.nwSans(AppLayout.addedNoteSize))
                                        .foregroundStyle(nw.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: NW.Space.m)
                                Button("Undo") { Task { await model.undo(added) } }
                                    .buttonStyle(.nwLink(font: .nwSans(AppLayout.suggestionOriginSize)))
                                    .disabled(model.busy)
                                    .accessibilityLabel("Undo: take “\(SuggestionsPresentation.plainLine(added.line))” out of \(added.file.fileName)")
                            }
                            .padding(.vertical, NW.Space.s)
                            .frame(minHeight: AppLayout.addedRowMinHeight)
                            .overlay(alignment: .top) { NWHairline() }
                            .nwTransition(.list)
                        }
                    }
                }
                .nwTransition(.disclosure)
            }
            VStack(alignment: .leading, spacing: NW.Space.m) {
                NWSectionHeader("About experiments", style: .settings).padding(.horizontal, NW.Space.xxs)
                SettingsNote(text: "Experiments can change or go away. Turning this one off keeps the lines you added and drops what's waiting.")
                    .padding(.horizontal, NW.Space.xxs)
                Button { openURL(ExperimentsSettings.feedbackURL) } label: {
                    Label("Send feedback", systemImage: "bubble.left")
                }
                .buttonStyle(.nw(.secondary, size: .s))
                .padding(.horizontal, NW.Space.xxs)
                .help("Opens a new issue for Shepherd on GitHub")
            }
        }
        .nwAnimation(.list, value: model.snapshot.added.map(\.id))
    }
}
