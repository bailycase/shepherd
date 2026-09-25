import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Experiments on iPhone and iPad (MobileExperiments; home track): features still
// being tried, each off until turned on. Its one experiment is Suggested instructions: agents
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
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textSecondary)
                        .padding(.horizontal, NW.Space.xs)
                    SuggestedInstructionsCard(isOn: on, enabled: serving) { turnOn in
                        model.post(settingsHosts) { $0.enabled = turnOn }
                    }
                    if !serving {
                        SettingsFootnote(settingsHosts.contains(where: \.isConnected)
                            ? "Your hosts' Shepherd is too old for experiments. Update it to try them here."
                            : "No host is online. Experiments show here once one is back.")
                    }
                }
                if let problem = model.problem {
                    NWBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
                    }
                }
                if on, let settings = model.settings(settingsHosts) {
                    SettingsSection("Learn from") {
                        NWListCard {
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
                        NWListHeader("Waiting for you") {
                            if waiting.count > 1 {
                                Button("Add all") { Task { await model.addAll(settingsHosts) } }
                                    .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                                    .disabled(model.busy)
                            }
                        }
                        if waiting.isEmpty {
                            SettingsFootnote("Nothing is waiting. When an agent learns something the hard way, its line shows up here.")
                        } else {
                            NWListCard {
                                ForEach(waiting) { item in
                                    Button { navigator.open(.settings(.suggestion(item.id))) } label: {
                                        WaitingRow(item: item, showsHost: model.hosts(settingsHosts).count > 1)
                                    }
                                    .buttonStyle(.nwRow(radius: 0))
                                }
                            }
                        }
                    }
                }
                if on {
                    Button("Open Instructions") { store.open(.instructions, inColumn: inColumn, navigator: navigator) }
                        .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                        .padding(.horizontal, NW.Space.xs)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.nw.bgWindow)
        .nwAnimation(.disclosure, value: on)
        .nwAnimation(.list, value: waiting.map(\.id))
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
        let nw = Color.nw
        HStack(alignment: .top, spacing: NW.Space.l) {
            Image(systemName: "flask")
                .font(.nw(.ui, weight: .medium))
                .foregroundStyle(nw.lanternText)
                .frame(width: MobileLayout.experimentTile, height: MobileLayout.experimentTile)
                .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text("Suggested instructions")
                    .font(.nw(.ui, weight: .semibold))
                    .foregroundStyle(nw.textPrimary)
                Text("Agents draft a line for your root AGENTS.md when they learn something the hard way. Nothing is written until you add it.")
                    .nwText(size: MobileLayout.settingsNoteSize, lineHeight: MobileLayout.settingsNoteLineHeight)
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Suggested instructions", isOn: Binding(get: { isOn }, set: toggle))
                .toggleStyle(.nwSwitch)
                .labelsHidden()
                .disabled(!enabled)
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: NWListMetrics.cardRadius)
    }
}

/// A source the experiment may learn from, checked while chosen.
private struct SourceRow: View {
    let kind: SuggestionSource.Kind
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: NW.Space.l) {
                Text(kind == .thread ? "Threads" : "Automations")
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.nw(.ui, weight: .semibold))
                        .foregroundStyle(Color.nw.running)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.experimentSourceRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(radius: 0))
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
        let nw = Color.nw
        let suggestion = item.suggestion
        let origin = [suggestion.source.name, suggestion.file.fileName, showsHost ? item.hostName : nil].compactMap { $0 }
        HStack(alignment: .top, spacing: NW.Space.l) {
            Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                .font(.nw(.ui, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWListMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(SuggestionLine.added(SuggestionsPresentation.plainLine(suggestion.line)))
                    .nwText(size: NWTextStyle.code.size, mono: true, lineHeight: MobileLayout.suggestionLineHeight)
                    .fixedSize(horizontal: false, vertical: true)
                Text(origin.joined(separator: " · "))
                    .font(.nw(.caption))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.nw(.caption, weight: .semibold))
                .foregroundStyle(nw.textTertiary)
                .padding(.top, NW.Space.xxs)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NW.Space.l)
        .padding(.horizontal, NW.Space.l)
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
        .background(Color.nw.bgWindow)
        .navigationTitle("Suggestion")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.watch() }
    }

    @ViewBuilder
    private func content(_ item: ClientSuggestions.Waiting, model: ClientSuggestions, hosts: [SettingsHost]) -> some View {
        let nw = Color.nw
        let suggestion = item.suggestion
        let target = file ?? suggestion.file
        let text = line ?? suggestion.line
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: suggestion.source.kind == .automation ? "bolt" : "bubble.left")
                    .font(.nw(.caption, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .accessibilityHidden(true)
                Text(suggestion.source.name)
                    .font(.nw(.ui, weight: .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: NW.Space.m)
                NWHostBadge(item.hostName)
            }
            Text(SuggestionsPresentation.origin(suggestion))
                .font(.nw(.caption))
                .foregroundStyle(nw.textTertiary)
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
                .font(.nw(.code))
                .foregroundStyle(nw.textPrimary)
                .focused($editing)
                .submitLabel(.done)
                .padding(NW.Space.l)
                .background(nw.doneTint, in: RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
                .accessibilityLabel("The line to add")
            SettingsFootnote("Edit it first if you like.")
        }
        if !suggestion.reason.isEmpty {
            SettingsSection("Why") {
                Text(suggestion.reason)
                    .nwText(.body)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xs)
            }
        }
        SettingsSection("Goes to") {
            NWListCard {
                SettingsControlRow("File", note: "On \(item.hostName). Nothing is written until you add it.") {
                    SettingsPicker("File", selection: target, options: InstructionFile.allCases, title: \.fileName) { file = $0 }
                }
            }
        }
        if let problem = model.problem {
            NWBanner(.failed, title: problem) {
                Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
            }
        }
        VStack(spacing: NW.Space.m) {
            Button(SuggestionsPresentation.addTitle(target)) {
                Task {
                    await model.add(item, line: text == suggestion.line ? nil : text, file: target == suggestion.file ? nil : target,
                                    in: hosts)
                    if model.problem == nil { dismiss() }
                }
            }
            .buttonStyle(.nw(.primary, size: .l))
            .frame(maxWidth: .infinity)
            Button("Dismiss") {
                Task {
                    await model.dismiss(item, in: hosts)
                    if model.problem == nil { dismiss() }
                }
            }
            .buttonStyle(.nw(.ghost, size: .l))
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
