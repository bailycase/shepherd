import SwiftUI
import ShepherdUI
import ShepherdSessions
import ShepherdRemote

/// Settings ▸ Models ▸ Your pi (SettingsPiFromPi): a sub-page of Models. Where Shepherd’s copy came from, each item
/// with how it stands and Re-import. The extensions it copies are switched in Settings ▸ Models ▸ Extensions.
struct FromYourPiSettings: View {
    let model: YourPiModel
    var openExtensions: () -> Void = {}

    var body: some View {
        let survey = model.survey ?? YourPiSurvey()
        SettingsPage(title: "Your pi") {
            if survey.folder != nil, survey.stateProblem == nil {
                SettingsGroup(title: "", footnote: survey.problems.first) {
                    SettingsRow(title: "Copy everything again", subtitle: Self.lastCopied(survey.copiedAt)) {
                        Button("Re-import all") { Task { await model.reimportAll() } }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .disabled(!model.busy.isEmpty)
                    }
                }
                SettingsGroup(title: "Brought over") {
                    let logins = survey.logins.filter { $0.yours != nil }
                    reimportRow("Logins", hint: logins.isEmpty ? "None in your pi" : "\(logins.count) sign-in\(logins.count == 1 ? "" : "s")",
                                item: .logins, enabled: !logins.isEmpty)
                    reimportRow("Custom providers", hint: survey.customProviders.isEmpty ? "None in your pi" : "models.json",
                                item: .customProviders, enabled: !survey.customProviders.isEmpty)
                    reimportRow("Default model", hint: survey.defaultModel.map { NativeModelChoices.shortName($0) } ?? "None set in your pi",
                                item: .defaultModel, enabled: survey.defaultModel != nil)
                    reimportRow("Instructions", hint: YourPiText.instructionsName(survey), item: .files(.instructions))
                    reimportRow("Skills", hint: Self.countText(survey.copies(.skills).count, "skill"), item: .files(.skills))
                    reimportRow("Prompts", hint: Self.countText(survey.copies(.prompts).count, "template"), item: .files(.prompts))
                    reimportRow("Themes", hint: Self.countText(survey.copies(.themes).count, "theme"), item: .files(.themes))
                    // Switched on and off with those added in Shepherd, in Settings ▸ Models ▸ Extensions.
                    reimportRow("Extensions", hint: Self.countText(survey.copies(.extensions).filter { !YourPiImport.isAdded($0.destination) }.count, "extension"),
                                item: .files(.extensions))
                }
            } else {
                SettingsGroup(title: "", footnote: survey.problems.first) {
                    if survey.stateProblem != nil {
                        SettingsRow(title: "Import history unavailable") { EmptyView() }
                    } else {
                        SettingsRow(title: "No pi found", subtitle: "Shepherd found no pi of yours to copy. Sign in on Models.") { EmptyView() }
                    }
                }
            }
        }
        .task { await model.refresh() }
    }

    private func reimportRow(_ title: String, hint: String, item: YourPiImport.Item, enabled: Bool = true) -> some View {
        let row = YourPiModel.rowID(item)
        return SettingsRow(title: title, subtitle: hint, problem: model.problems[row]) {
            Button(model.reimported.contains(row) ? "Done" : "Re-import") { Task { await model.reimport(item) } }
                .buttonStyle(.sh(.secondary, size: .s))
                .disabled(!enabled || model.busy.contains(row))
                .accessibilityLabel("Re-import \(title.lowercased()) from your pi")
        }
    }

    static func lastCopied(_ date: Date?) -> String {
        date.map { "Last copied \(day($0))" } ?? "Not copied yet"
    }

    static func countText(_ count: Int, _ noun: String) -> String {
        count == 0 ? "None copied" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: Words

    static func freshness(_ freshness: PiFreshness) -> SHFreshness {
        switch freshness {
        case .sameAsYourPi: .same
        case .newerInYourPi: .newer
        case .changedHere: .changed
        }
    }

    /// "Subscription · Claude Pro or Max", "API key · sk-••••91c2".
    static func loginDetail(_ login: YourPiSurvey.Login, survey: YourPiSurvey) -> [SHReimportRow.Detail] {
        switch login.yours {
        case .subscription?: [.init("Subscription · " + (PiSignInCatalog.subscription(login.provider)?.plan ?? "signed in"))]
        case .apiKey?:
            if let display = survey.yourKeys[login.provider] {
                if let masked = display.masked { [.init("API key ·"), .init(masked, mono: true)] }
                else if let name = display.variables.first { [.init("API key · reads"), .init("$" + name, mono: true)] }
                else { [.init("API key · command not supported")] }
            } else {
                [.init("API key")]
            }
        case .other(let type)?: [.init("Signed in (\(type))")]
        case nil: []
        }
    }

    static func defaultModelDetail(_ survey: YourPiSurvey) -> [SHReimportRow.Detail] {
        guard let theirs = survey.defaultModel else { return [.init("None set in your pi.")] }
        guard let mine = survey.shepherdDefaultModel, mine != theirs else { return [.init(NativeModelChoices.shortName(theirs), mono: true)] }
        return [.init(NativeModelChoices.shortName(mine), mono: true), .init("here")]
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
