import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Experiments (SettingsExperiments): features still being tried, each off until the
/// user turns it on. Suggested instructions, the Design tool, conversation Goals, Projects and Computer use each
/// keep their own switch. A wide page: the experiment and what waits for the user, beside a
/// 320pt side column (how it works, what was added, and a note about experiments).
struct ExperimentsSettings: View {
    var model: SuggestionsModel
    var instructions: InstructionsModel
    /// This Mac's experiment switches.
    var settings: AppSettings
    /// Opens Settings ▸ Instructions (where the lines go).
    let openInstructions: () -> Void
    /// The drill-in open, owned by the view model so Esc and the back button reach it.
    @Binding var page: ExperimentsPage?
    @State private var permissions = ComputerUsePermissions()
    @Bindable private var bindable: AppSettings

    static let feedbackURL = URL(string: "https://github.com/shepherd-app/shepherd/issues/new?title=Suggested%20instructions%3A%20")!

    init(model: SuggestionsModel, instructions: InstructionsModel, settings: AppSettings, page: Binding<ExperimentsPage?> = .constant(nil),
         openInstructions: @escaping () -> Void) {
        self.model = model
        self.instructions = instructions
        self.settings = settings
        _page = page
        self.openInstructions = openInstructions
        bindable = settings
    }

    var body: some View {
        Group {
            switch page {
            case .waiting?:
                SettingsPage(title: SuggestionsPresentation.waitingTitle(model.snapshot.waiting.count)) {
                    if let message = model.unavailable {
                        recoveryBanner(message)
                    } else {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            WaitingSuggestions(model: model, instructions: instructions, now: context.date)
                        }
                    }
                }
            case .apps?:
                SettingsPage(title: "Allowed apps") {
                    SettingsGroup(title: "macOS permissions", footnote: "Granted in System Settings ▸ Privacy & Security.") {
                        // Only what still needs allowing: an allowed permission has nothing to change here.
                        if !permissions.accessibility {
                            SettingsRow(title: "Accessibility", subtitle: "Lets Shepherd click and type in other apps") {
                                permission(name: "Accessibility", request: permissions.requestAccessibility)
                            }
                        }
                        if !permissions.screenRecording {
                            SettingsRow(title: "Screen Recording", subtitle: "Lets Shepherd see the windows it works in") {
                                permission(name: "Screen Recording", request: permissions.requestScreenRecording)
                            }
                        }
                    }
                }
            case nil:
                list
            }
        }
        .task { await model.refresh() }
        .onAppear { permissions.refresh() }
        // Allowed apps has nothing left once both are allowed.
        .onChange(of: permissions.accessibility && permissions.screenRecording) { _, allowed in
            if allowed, page == .apps { page = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }

    private var learnsFrom: String {
        let sources = model.settings.sources
        switch (sources.contains(.thread), sources.contains(.automation)) {
        case (true, true): return "Threads and automations"
        case (true, false): return "Threads"
        case (false, true): return "Automations"
        default: return "Nothing"
        }
    }

    private func recoveryBanner(_ message: String) -> some View {
        SHBanner(.failed, title: "Suggested instructions unavailable", message: message) {
            Button("Refresh") { Task { await model.refresh() } }.buttonStyle(.sh(.secondary, size: .s))
        }
    }

    private var suggestionsGroup: some View {
        SettingsGroup(title: "") {
            SettingsRow(title: "Suggested instructions", subtitle: "Learn rules from your corrections") {
                SettingsSwitch(label: "Suggested instructions",
                               isOn: Binding(get: { model.settings.enabled }, set: { on in Task { await model.setEnabled(on) } }))
                    .disabled(model.busy)
            }
            if model.settings.enabled || !model.snapshot.waiting.isEmpty {
                let waiting = model.snapshot.waiting.count
                SettingsDrillRow(title: "Waiting", subtitle: waiting == 0 ? "Nothing to review" : "\(waiting) line\(waiting == 1 ? "" : "s") to review",
                                 value: waiting == 0 ? nil : "\(waiting)", action: { page = .waiting })
            }
            if model.settings.enabled {
                SettingsRow(title: "Learn from") {
                    SHPopupMenu(learnsFrom, minWidth: 0) {
                        Toggle("Threads", isOn: Binding(get: { model.settings.sources.contains(.thread) },
                                                        set: { on in Task { await model.setLearns(from: .thread, on) } }))
                        Toggle("Automations", isOn: Binding(get: { model.settings.sources.contains(.automation) },
                                                            set: { on in Task { await model.setLearns(from: .automation, on) } }))
                    }
                    .accessibilityLabel("Learn from")
                }
                SettingsRow(title: "Can suggest for", subtitle: "APPEND_SYSTEM.md overrides everything else") {
                    SHPopupMenu(InstructionFile.allCases.filter { model.settings.files.contains($0) }.map(\.fileName).joined(separator: ", ").nonEmpty ?? "Nothing",
                                mono: true, minWidth: 0) {
                        ForEach(InstructionFile.allCases, id: \.self) { file in
                            Toggle(file.fileName, isOn: Binding(get: { model.settings.files.contains(file) },
                                                                set: { on in Task { await model.setSuggests(for: file, on) } }))
                        }
                    }
                    .accessibilityLabel("Can suggest for")
                }
                SettingsRow(title: "Where lines go", subtitle: "Settings › Instructions, shared by the whole fleet") {
                    Button("Open Instructions", action: openInstructions).buttonStyle(.sh(.secondary, size: .s))
                }
            }
            if let problem = model.problem {
                SettingsRow(title: "", problem: problem) { EmptyView() }
            }
        }
        .disabled(model.busy)
    }

    private var list: some View {
        SettingsPage(title: "Experiments") {
            if let message = model.unavailable {
                recoveryBanner(message)
            } else {
                suggestionsGroup
            }
            SettingsGroup(title: "", footnote: "Experiments can change or go away.") {
                SettingsRow(title: "Design tool", subtitle: "Boards and design systems") {
                    SettingsSwitch(label: "Design tool", isOn: $bindable.designToolEnabled)
                }
                SettingsRow(title: "Goals", subtitle: "Keep an agent going until a check passes") {
                    SettingsSwitch(label: "Goals", isOn: $bindable.goalsEnabled)
                }
                SettingsRow(title: "Projects", subtitle: "One conversation that runs many threads") {
                    SettingsSwitch(label: "Projects", isOn: $bindable.projectsEnabled)
                }
                SettingsRow(title: "Computer use", subtitle: "Threads can click and type in your apps") {
                    SettingsSwitch(label: "Computer use", isOn: $bindable.computerUseEnabled)
                }
                if settings.computerUseEnabled, !(permissions.accessibility && permissions.screenRecording) {
                    SettingsDrillRow(title: "Allowed apps", subtitle: "Accessibility and Screen Recording", value: "Needs you",
                                     action: { page = .apps })
                }
            }
        }
        .shAnimation(.disclosure, value: model.settings.enabled)
    }

    private func permission(name: String, request: @escaping () -> Void) -> some View {
        Button("Allow…", action: request)
            .buttonStyle(.sh(.secondary, size: .s))
            .accessibilityLabel("Allow \(name)")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
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

/// What macOS has allowed Shepherd to do in other apps. Read when the card appears and when the
/// app becomes active, since the user grants these in System Settings.
@MainActor @Observable
final class ComputerUsePermissions {
    private(set) var accessibility = false
    private(set) var screenRecording = false

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        open("Privacy_ScreenCapture")
    }

    private func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
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
                                        note: "Lines go to Settings › Instructions, which the whole fleet shares.") {
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
                    .shText(size: SHTextStyle.caption.size, lineHeight: AppLayout.settingsFootnoteLineHeight)
                    .foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xxs)
            }
            ForEach(waiting) { suggestion in
                SuggestionCard(model: model, suggestion: suggestion,
                               hosts: SuggestionsPresentation.hostsWord, now: now)
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
