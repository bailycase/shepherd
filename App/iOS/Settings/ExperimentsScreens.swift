import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Experiments on iPhone and iPad (MobileExperiments; home track): features still
// being tried, each off until turned on. Goals, Projects, the Design tool and Missions are per-host
// switches, each where the host takes it (`HostSettingChange.capability`). Suggested instructions: agents
// draft a line for the root instructions when they learn something the hard way, and nothing is
// written until you add it. It spans every host (`suggestions.v1`): turning it on or choosing
// what it learns from changes every host, and the lines waiting are every host's, newest first.
// `ClientSuggestions` holds every rule; these screens draw it.

/// Settings ▸ Experiments.
struct ExperimentsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.suggestions
        let settingsHosts = store.hosts
        let serving = !model.hosts(settingsHosts).isEmpty
        let on = model.isOn(settingsHosts)
        let waiting = model.waiting(settingsHosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text("Still being tried out. Each is off until you turn it on.")
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.xs)
                    SuggestedInstructionsCard(isOn: on, enabled: serving) { turnOn in
                        model.post(settingsHosts) { $0.enabled = turnOn }
                    }
                    if !serving {
                        SettingsFootnote(settingsHosts.contains(where: \.isConnected)
                            ? "Your hosts' Shepherd is too old for suggested instructions. Update it to try them here."
                            : "No host is online. Suggested instructions appears once one is back.")
                    }
                }
                ForEach(store.experimentHosts) { host in
                    SettingsSection(store.hosts.count > 1 ? "On \(host.name)" : "On this host") {
                        if let settings = store.hostSettings.settings(of: host) {
                            HostExperiments(host: host, settings: settings, hostSettings: store.hostSettings)
                        } else {
                            SettingsFootnote("Reading experiments on \(host.name)…")
                        }
                    }
                }
                if let problem = store.hostSettings.problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { store.hostSettings.dismissProblem() }.buttonStyle(.sh(.secondary))
                    }
                }
                if let problem = model.problem {
                    SHBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.sh(.secondary))
                    }
                }
                if on, let settings = model.settings(settingsHosts) {
                    SettingsSection("Learn from") {
                        SHListCard {
                            ForEach([SuggestionSource.Kind.thread, .automation], id: \.self) { kind in
                                SourceRow(kind: kind, chosen: settings.sources.contains(kind)) {
                                    model.post(settingsHosts) { $0.sources.formSymmetricDifference([kind]) }
                                }
                            }
                        }
                    }
                }
                if on || !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        SHListHeader("Waiting for you") {
                            if waiting.count > 1 {
                                Button("Add all") { Task { await model.addAll(settingsHosts) } }
                                    .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                                    .disabled(model.busy)
                            }
                        }
                        if waiting.isEmpty {
                            SettingsFootnote("Nothing is waiting. When an agent learns something the hard way, its line shows up here.")
                        } else {
                            SHListCard {
                                ForEach(waiting) { item in
                                    Button { navigator.open(.settings(.suggestion(item.id))) } label: {
                                        WaitingRow(item: item, showsHost: model.hosts(settingsHosts).count > 1)
                                    }
                                    .buttonStyle(.shRow(radius: 0))
                                }
                            }
                        }
                    }
                }
                if on {
                    Button("Open Instructions") { store.open(.instructions, inColumn: inColumn, navigator: navigator) }
                        .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                        .padding(.horizontal, SH.Space.xs)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.sh.bgWindow)
        .shAnimation(.disclosure, value: on)
        .shAnimation(.list, value: waiting.map(\.id))
        .navigationTitle("Experiments")
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .task { if !inColumn { await store.watch() } }
    }
}

/// Suggested instructions' card: a flask on its lantern tile, the name over what it does, and
/// its switch.
private struct SuggestedInstructionsCard: View {
    let isOn: Bool
    let enabled: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: "flask")
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(sh.lanternText)
                .frame(width: MobileLayout.experimentTile, height: MobileLayout.experimentTile)
                .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text("Suggested instructions")
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Agents draft a line for your root AGENTS.md when they learn something the hard way. Nothing is written until you add it.")
                    .shText(size: MobileLayout.settingsNoteSize, lineHeight: MobileLayout.settingsNoteLineHeight)
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Suggested instructions", isOn: Binding(get: { isOn }, set: toggle))
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .disabled(!enabled)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHListMetrics.cardRadius)
    }
}

/// One host's switchable experiments, each shown only where the host takes its switch: Goals,
/// Projects, the Design tool and Missions (locked on while a mission runs there).
private struct HostExperiments: View {
    let host: SettingsHost
    let settings: HostSettings
    let hostSettings: ClientHostSettings

    var body: some View {
        let post: (HostSettingChange) -> Void = { hostSettings.post($0, on: host) }
        if host.serves(RemoteProtocol.goalExperimentCapability) {
            HostExperimentCard(title: "Goals", host: host.name, isOn: settings.goalsEnabled,
                               text: "Keep a conversation working toward a condition you set with /goal. No time or token budgets. Turning this off pauses active goals without clearing them.") {
                SHGoalGlyph()
            } toggle: { post(.goalsEnabled($0)) }
        }
        if host.serves(RemoteProtocol.projectsExperimentCapability) {
            HostExperimentCard(title: "Projects", host: host.name, isOn: settings.projectsEnabled,
                               text: "Coordinate work across threads and spaces. Turning this off pauses project work and keeps your projects and files.") {
                Image(systemName: "square.stack.3d.up")
            } toggle: { post(.projectsEnabled($0)) }
        }
        if host.serves(RemoteProtocol.designToolExperimentCapability) {
            HostExperimentCard(title: "Design tool", host: host.name, isOn: settings.designToolEnabled,
                               text: "Describe a page or flow and a design agent draws it as HTML boards on a canvas. Adds Designs to the host's sidebar and “Start a design” to New thread.") {
                Image(systemName: "paintbrush.pointed")
            } toggle: { post(.designToolEnabled($0)) }
        }
        if host.serves(RemoteProtocol.missionsExperimentCapability) {
            let locked = settings.missionsEnabled && settings.missionsActive
            HostExperimentCard(title: "Missions", host: host.name, isOn: settings.missionsEnabled,
                               text: "Describe an end state across your repositories; a planner maps it, agents do the work, and you publish the pull requests. Turning this off hides Missions and keeps your missions and files.",
                               lockedNote: locked ? "Pause or stop running missions on \(host.name) before turning this off." : nil) {
                Image(systemName: "flag.checkered")
            } toggle: { post(.missionsEnabled($0)) }
        }
        SettingsFootnote("Changes apply on \(host.name) at once.")
    }
}

/// An experiment's card for one host: its tile, its name over what it does, and its switch.
private struct HostExperimentCard<Glyph: View>: View {
    let title: String
    let host: String
    let isOn: Bool
    let text: String
    var lockedNote: String?
    @ViewBuilder let glyph: () -> Glyph
    let toggle: (Bool) -> Void

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            glyph()
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(sh.lanternText)
                .frame(width: MobileLayout.experimentTile, height: MobileLayout.experimentTile)
                .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title)
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text(text)
                    .shText(size: MobileLayout.settingsNoteSize, lineHeight: MobileLayout.settingsNoteLineHeight)
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lockedNote {
                    Text(lockedNote)
                        .shText(size: MobileLayout.settingsNoteSize, lineHeight: MobileLayout.settingsNoteLineHeight)
                        .foregroundStyle(AgentState.attention.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("\(title) on \(host)", isOn: Binding(get: { isOn }, set: toggle))
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .disabled(lockedNote != nil)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHListMetrics.cardRadius)
    }
}

/// A source the experiment may learn from, checked while chosen.
private struct SourceRow: View {
    let kind: SuggestionSource.Kind
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SH.Space.l) {
                Text(kind == .thread ? "Threads" : "Automations")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(Color.sh.running)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.experimentSourceRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: 0))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A line waiting on a host: where it came from (a speech bubble for a thread, a bolt for an
/// automation), the line as it would be added, where it came from and where it goes, and a
/// chevron that opens it.
private struct WaitingRow: View {
    let item: ClientSuggestions.Waiting
    let showsHost: Bool

    var body: some View {
        let sh = Color.sh
        let suggestion = item.suggestion
        let origin = [suggestion.source.name, suggestion.file.fileName, showsHost ? item.hostName : nil].compactMap { $0 }
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHListMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(SuggestionLine.added(SuggestionsPresentation.plainLine(suggestion.line)))
                    .shText(size: SHTextStyle.code.size, mono: true, lineHeight: MobileLayout.suggestionLineHeight)
                    .fixedSize(horizontal: false, vertical: true)
                Text(origin.joined(separator: " · "))
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.sh(.caption, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .padding(.top, SH.Space.xxs)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.l)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Adds: \(SuggestionsPresentation.plainLine(suggestion.line)). From \(origin.joined(separator: ", "))")
    }
}

/// One suggested line (MobileExperiments' chevron): where it came from and why, the line to edit
/// first, the file it goes to, and Add or Dismiss. Once it is added or dismissed, here or
/// elsewhere, the screen says so.
struct SuggestionScreen: View {
    let id: UUID
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var line: String?
    @State private var file: InstructionFile?
    @FocusState private var editing: Bool

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.suggestions
        let settingsHosts = store.hosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if let item = model.waiting(id, in: settingsHosts) {
                    content(item, model: model, hosts: settingsHosts)
                } else {
                    SettingsFootnote("This line was added or dismissed.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .navigationTitle("Suggestion")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.watch() }
    }

    @ViewBuilder
    private func content(_ item: ClientSuggestions.Waiting, model: ClientSuggestions, hosts: [SettingsHost]) -> some View {
        let sh = Color.sh
        let suggestion = item.suggestion
        let target = file ?? suggestion.file
        let text = line ?? suggestion.line
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
                Text(suggestion.source.name)
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: SH.Space.m)
                SHHostBadge(item.hostName)
            }
            Text(SuggestionsPresentation.origin(suggestion))
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
        }
        SettingsSection("The line") {
            // It stays one line: Return ends the edit instead of breaking it.
            TextField("Line", text: Binding(get: { text }, set: { value in
                if value.contains("\n") {
                    line = value.replacingOccurrences(of: "\n", with: "")
                    editing = false
                } else {
                    line = value
                }
            }), axis: .vertical)
                .font(.sh(.code))
                .foregroundStyle(sh.textPrimary)
                .focused($editing)
                .submitLabel(.done)
                .padding(SH.Space.l)
                .background(sh.doneTint, in: RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
                .accessibilityLabel("The line to add")
            SettingsFootnote("Edit it first if you like.")
        }
        if !suggestion.reason.isEmpty {
            SettingsSection("Why") {
                Text(suggestion.reason)
                    .shText(.body)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
            }
        }
        SettingsSection("Goes to") {
            SHListCard {
                SettingsControlRow("File", note: "On \(item.hostName). Nothing is written until you add it.") {
                    SettingsPicker("File", selection: target, options: InstructionFile.allCases, title: \.fileName) { file = $0 }
                }
            }
        }
        if let problem = model.problem {
            SHBanner(.failed, title: problem) {
                Button("OK") { model.dismissProblem() }.buttonStyle(.sh(.secondary))
            }
        }
        VStack(spacing: SH.Space.m) {
            Button(SuggestionsPresentation.addTitle(target)) {
                Task {
                    await model.add(item, line: text == suggestion.line ? nil : text, file: target == suggestion.file ? nil : target,
                                    in: hosts)
                    if model.problem == nil { dismiss() }
                }
            }
            .buttonStyle(.sh(.primary, size: .l))
            .frame(maxWidth: .infinity)
            Button("Dismiss") {
                Task {
                    await model.dismiss(item, in: hosts)
                    if model.problem == nil { dismiss() }
                }
            }
            .buttonStyle(.sh(.ghost, size: .l))
        }
        .disabled(model.busy)
    }
}

/// A suggested line as the lists draw it.
enum SuggestionLine {
    /// "+ " in `done`, then the line's light Markdown: a bullet in `lanternText`, code spans in
    /// `synString`, the rest `textPrimary`.
    @MainActor static func added(_ line: String) -> AttributedString {
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
