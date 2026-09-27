import SwiftUI
import ShepherdUI
import ShepherdSessions
import ShepherdRemote

/// Settings ▸ Pi ▸ From your pi (SettingsPiFromPi, SettingsPiExtensions; DESIGN.md › Pi ▸ From
/// your pi): where Shepherd's copy came from, each item with how it stands and Re-import, the
/// files copied, and the user's extensions with their switches.
struct FromYourPiSettings: View {
    let model: YourPiModel
    var openInstructions: () -> Void = {}
    var openSkills: () -> Void = {}

    var body: some View {
        let survey = model.survey ?? YourPiSurvey()
        SettingsPage(title: "From your pi",
                     explanation: "What Shepherd brought over from the pi in your terminal. Shepherd keeps its own copy, so nothing here changes your pi.") {
            if let folder = survey.folder {
                source(survey, folder: folder)
                broughtOver(survey)
                copied(survey)
                extensions(survey, folder: folder)
            } else {
                SettingsGroup(title: "Your pi") {
                    SettingsRow(title: "No pi found", subtitle: "Shepherd found no pi of yours to copy. Sign in on Sign-in.") { EmptyView() }
                }
            }
        }
        .task { await model.refresh() }
    }

    // MARK: Source

    private func source(_ survey: YourPiSurvey, folder: String) -> some View {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        return NWGroupCard(fill: Color.nw.bgWindow, radius: NWCardRowMetrics.settingsCardRadius) {
            SettingsActionRow {
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    HStack(spacing: NW.Space.m) {
                        Text("Source").font(.nw(.body, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                        Text((folder as NSString).abbreviatingWithTildeInPath).font(.nwMono(12.5)).foregroundStyle(Color.nw.textPrimary)
                            .help(folder)
                    }
                    Text("The pi in your terminal, found through your login shell.").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                    if let problem = survey.problems.first { NWInlineProblem(problem) }
                }
            } actions: {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .accessibilityLabel("Show your pi in Finder")
            }
            SettingsActionRow {
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text("Last brought over").font(.nw(.body, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                    Text(Self.lastBroughtOver(survey.copiedAt)).font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                }
            } actions: {
                Button("Re-import all") { Task { await model.reimportAll() } }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(!model.busy.isEmpty)
            }
        }
        .nwControlScale(.settings)
    }

    // MARK: Brought over

    private func broughtOver(_ survey: YourPiSurvey) -> some View {
        let logins = survey.logins.filter { $0.yours != nil }
        return SettingsGroup(title: "Brought over", footnote: "Copies. Re-import replaces Shepherd’s copy with your pi’s; your pi is never written to.") {
            if !logins.isEmpty {
                NWCardLabel("Logins")
                ForEach(logins) { login in
                    reimportRow(PiSignInCatalog.name(login.provider), badge: PiSignInCatalog.badge(login.provider),
                                detail: Self.loginDetail(login, survey: survey), item: .login(login.provider),
                                freshness: survey.freshness["login:\(login.provider)"],
                                why: survey.freshness["login:\(login.provider)"] == .newerInYourPi
                                    ? survey.yourSignInsChanged.map { "Your pi’s sign-in changed on \(Self.day($0))." } : nil)
                }
            }
            NWCardLabel("Settings")
            reimportRow("Custom providers", detail: survey.customProviders.isEmpty ? [.init("None in your pi.")]
                            : [.init("models.json", mono: true), .init("· " + survey.customProviders.joined(separator: ", "))],
                        item: .customProviders, freshness: survey.freshness["customProviders"], enabled: !survey.customProviders.isEmpty)
            reimportRow("Default model", detail: Self.defaultModelDetail(survey), item: .defaultModel,
                        freshness: survey.freshness["defaultModel"],
                        why: survey.defaultModel.flatMap { theirs in
                            theirs != survey.shepherdDefaultModel ? "Your pi now uses \(NativeModelChoices.shortName(theirs))." : nil
                        },
                        enabled: survey.defaultModel != nil)
            reimportRow("Trusted folders", detail: Self.trustDetail(survey), item: .trust, freshness: survey.freshness["trust"],
                        enabled: survey.trustedFolders > 0)
        }
    }

    private func reimportRow(_ title: String, badge: String? = nil, detail: [NWReimportRow.Detail], item: YourPiImport.Item,
                             freshness: PiFreshness?, why: String? = nil, enabled: Bool = true) -> some View {
        let row = YourPiModel.rowID(item)
        return NWReimportRow(title, badge: badge, detail: detail, why: why,
                             freshness: model.busy.contains(row) ? .reimporting : model.reimported.contains(row) ? .reimported
                                : freshness.map(Self.freshness),
                             problem: model.problems[row], reimport: enabled ? { Task { await model.reimport(item) } } : nil)
    }

    // MARK: Copied

    private func copied(_ survey: YourPiSurvey) -> some View {
        SettingsGroup(title: "Copied", footnote: "Copied into Shepherd’s pi. Edits in your pi reach Shepherd only when you Re-import.") {
            copiedRow("Instructions", detail: YourPiText.instructions(survey), kind: .instructions) {
                Button("Edit in Instructions", action: openInstructions).buttonStyle(.nw(.secondary, size: .s))
            }
            copiedRow("Skills", detail: YourPiText.skills(survey.copies(.skills)), kind: .skills) {
                Button("Show in Finder") { reveal(survey.copies(.skills).first, fallback: "skills") }.buttonStyle(.nw(.secondary, size: .s))
            }
            copiedRow("Prompts", detail: nil, chips: survey.copies(.prompts).map { "/" + $0.name }, kind: .prompts) {
                Button("Show in Finder") { reveal(survey.copies(.prompts).first, fallback: "prompts") }.buttonStyle(.nw(.secondary, size: .s))
            }
            if !survey.copies(.themes).isEmpty {
                copiedRow("Themes", detail: nil, chips: survey.copies(.themes).map(\.name), kind: .themes) {
                    Button("Show in Finder") { reveal(survey.copies(.themes).first, fallback: "themes") }.buttonStyle(.nw(.secondary, size: .s))
                }
            }
        }
    }

    private func copiedRow<Action: View>(_ title: String, detail: String?, chips: [String] = [], kind: YourPiResourceKind,
                                         @ViewBuilder action: () -> Action) -> some View {
        let row = YourPiModel.rowID(.files(kind))
        return SettingsActionRow {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title).font(.nw(.body, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                if let detail {
                    NWMarkupText(detail, size: NWTextStyle.ui.size, codeSize: 11.5, lineHeight: 1.45).foregroundStyle(Color.nw.textSecondary)
                }
                if !chips.isEmpty {
                    HStack(spacing: NW.Space.xs) {
                        ForEach(chips.prefix(6), id: \.self) { NWTag($0, mono: true) }
                        if chips.count > 6 { NWTag("+\(chips.count - 6)") }
                    }
                } else if detail == nil {
                    Text("None copied.").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                }
                if let problem = model.problems[row] { NWInlineProblem(problem) }
            }
        } actions: {
            action()
            Button("Re-import") { Task { await model.reimport(.files(kind)) } }
                .buttonStyle(.nw(.ghost, size: .s))
                .disabled(model.busy.contains(row))
                .accessibilityLabel("Re-import \(title.lowercased()) from your pi")
        }
        .nwControlScale(.standard)
    }

    private func reveal(_ copy: YourPiCopy?, fallback: String) {
        let url = copy.map { model.pi.home.appendingPathComponent($0.destination) } ?? model.pi.home.appendingPathComponent(fallback)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Extensions

    private func extensions(_ survey: YourPiSurvey, folder: String) -> some View {
        SettingsGroup(title: "Extensions", footnote: "Code, so each one came over switched off. Shepherd’s own extensions are on the Pi page.",
                      trailing: "\(survey.extensions.count) in \((folder as NSString).abbreviatingWithTildeInPath)/extensions") {
            ForEach(survey.extensions) { item in
                NWExtensionRow(item.copy.name, path: YourPiText.extensionPath(item), summary: item.summary,
                               state: item.failure.map { .failed($0, lines: item.failureLines) } ?? (item.on ? .on : .off),
                               isOn: Binding(get: { item.on }, set: { on in Task { await model.setExtension(item.copy.destination, on: on) } })) {
                    Task { await model.setExtension(item.copy.destination, on: true) }
                }
            }
            SettingsRow(title: "Copy again",
                        subtitle: survey.extensions.isEmpty ? "Your pi has no extensions Shepherd copied."
                            : "Copies your extensions again, keeping each one's switch.",
                        problem: model.problems[YourPiModel.rowID(.files(.extensions))]) {
                Button("Re-import") { Task { await model.reimport(.files(.extensions)) } }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(model.busy.contains(YourPiModel.rowID(.files(.extensions))))
            }
        }
    }

    // MARK: Words

    static func freshness(_ freshness: PiFreshness) -> NWFreshness {
        switch freshness {
        case .sameAsYourPi: .same
        case .newerInYourPi: .newer
        case .changedHere: .changed
        }
    }

    /// "Subscription · Claude Pro or Max", "API key · sk-••••91c2".
    static func loginDetail(_ login: YourPiSurvey.Login, survey: YourPiSurvey) -> [NWReimportRow.Detail] {
        switch login.yours {
        case .subscription?: [.init("Subscription · " + (PiSignInCatalog.subscription(login.provider)?.plan ?? "signed in"))]
        case .apiKey?:
            if let display = survey.yourKeys[login.provider] {
                if let masked = display.masked { [.init("API key ·"), .init(masked, mono: true)] }
                else if let name = display.variables.first { [.init("API key · reads"), .init("$" + name, mono: true)] }
                else { [.init("API key · runs a command")] }
            } else {
                [.init("API key")]
            }
        case .other(let type)?: [.init("Signed in (\(type))")]
        case nil: []
        }
    }

    static func defaultModelDetail(_ survey: YourPiSurvey) -> [NWReimportRow.Detail] {
        guard let theirs = survey.defaultModel else { return [.init("None set in your pi.")] }
        guard let mine = survey.shepherdDefaultModel, mine != theirs else { return [.init(NativeModelChoices.shortName(theirs), mono: true)] }
        return [.init(NativeModelChoices.shortName(mine), mono: true), .init("here")]
    }

    /// "4 folders · ~/code/shepherd and 3 more".
    static func trustDetail(_ survey: YourPiSurvey) -> [NWReimportRow.Detail] {
        guard survey.trustedFolders > 0 else { return [.init("None in your pi.")] }
        var parts: [NWReimportRow.Detail] = [.init(YourPiText.count(survey.trustedFolders, "folder") + (survey.trustedFolderPaths.isEmpty ? "" : " ·"))]
        if let first = survey.trustedFolderPaths.first {
            parts.append(.init((first as NSString).abbreviatingWithTildeInPath, mono: true))
            if survey.trustedFolderPaths.count > 1 { parts.append(.init("and \(survey.trustedFolderPaths.count - 1) more")) }
        }
        return parts
    }

    /// "Today at 9:41 AM, on first launch. Nothing is synced after that."
    static func lastBroughtOver(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not yet. The first launch brings it over." }
        let day = Calendar.current.isDate(date, inSameDayAs: now) ? "Today"
            : Calendar.current.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) ? "Yesterday"
            : date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) at \(date.formatted(date: .omitted, time: .shortened)), on first launch. Nothing is synced after that."
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
