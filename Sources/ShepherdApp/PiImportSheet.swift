import SwiftUI
import ShepherdUI
import ShepherdSessions
import ShepherdRemote

/// The first launch's sheet as it stands (PiImport*; docs/design/dialogs-and-palette.md › Dialogs and sheets › Bringing
/// over your pi): the copy's steps while it runs, then how it ended. Plain values, derived by
/// pure functions (`PiImportSheetTests`).
struct PiImportSheetState: Identifiable, Equatable {
    /// How the sheet ends: the five outcomes.
    enum Stage: Equatable {
        case progress, done, missing, newUser, failed

        /// Restored agents keep waiting while it shows: it asks for a sign-in.
        var holdsAgents: Bool { self == .missing || self == .newUser || self == .failed }
    }

    enum StepState: Equatable { case pending, running, done, failed }

    /// A provider that still needs a sign-in, and why.
    struct Missing: Equatable, Identifiable {
        var id: String
        var detail: String
    }

    let id = UUID()
    var stage: Stage = .progress
    /// Their pi's folder; nil for a new user.
    var from: String?
    var steps: [YourPiImportStep: StepState] = [:]
    var report = YourPiImportReport()
    var survey = YourPiSurvey()
    var missing: [Missing] = []
    /// Retry is copying the sign-ins again.
    var retrying = false
    /// The default model that came over, which Shepherd's pi has no model for (its provider is one
    /// an extension registers, switched off): a thread on it fails at start, so the sheet asks for
    /// another, from `catalog`. Nil once one is chosen.
    var unresolvedDefault: String?
    /// What Shepherd's pi can start now (`PiModelCatalog`), for the default's menu.
    var catalog: [String] = []
    /// Copied logins the first launch found no longer work (a refresh token that rotated in the
    /// terminal's pi), by provider, with the provider's reason: each needs signing in again.
    var brokenLogins: [String: String] = [:]

    init(from: String?) {
        self.from = from
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.stage == b.stage && a.from == b.from && a.steps == b.steps && a.report == b.report && a.survey == b.survey
            && a.missing == b.missing && a.retrying == b.retrying && a.unresolvedDefault == b.unresolvedDefault && a.catalog == b.catalog
            && a.brokenLogins == b.brokenLogins
    }

    // MARK: How it ends

    /// The stage a finished first copy shows; nil for no sheet at all (a new user already
    /// signed in with nothing missing). `unresolvedDefault` (a default model Shepherd's pi can't
    /// start) is something missing too.
    static func stage(report: YourPiImportReport, survey: YourPiSurvey, missing: [Missing], unresolvedDefault: String? = nil) -> Stage? {
        if report.from == nil {
            return survey.canStartAgents && missing.isEmpty ? nil : .newUser
        }
        if report.signInsUnreadable != nil { return .failed }
        return missing.isEmpty && unresolvedDefault == nil ? .done : .missing
    }

    /// Providers the restored agents' and default `models` use that nothing in Shepherd's pi
    /// covers, then the copied logins that no longer work (`broken`, by provider with its reason).
    static func missing(survey: YourPiSurvey, models: [String], broken: [String: String] = [:]) -> [Missing] {
        var rows = survey.missingSignIns(for: models).map { provider in
            let theirs = survey.logins.first { $0.provider == provider }?.yours
            return Missing(id: provider, detail: theirs == nil ? "Your pi isn’t signed in to it" : "Your pi’s sign-in couldn’t be copied")
        }
        for provider in broken.keys.sorted() where !rows.contains(where: { $0.id == provider }) {
            rows.append(Missing(id: provider, detail: "Your pi’s sign-in no longer works: \(broken[provider] ?? "")"))
        }
        return rows
    }

    /// The default `model` Shepherd's pi can't start: one not in its `catalog`. A catalog pi
    /// couldn't give (empty) proves nothing, and neither does a model with no provider part.
    static func unresolvedDefault(_ model: String?, catalog: [String]) -> String? {
        guard let model, !catalog.isEmpty, model.contains("/"), !catalog.contains(model) else { return nil }
        return model
    }

    /// Whether `provider` is covered now (a sign-in landed, or a key in the environment), and
    /// not one whose copied login was found broken.
    func signedIn(_ provider: String) -> Bool {
        brokenLogins[provider] == nil && !survey.missingSignIns(for: ["\(provider)/any"]).contains(provider)
    }

    /// Done enables once every sign-in landed and the default model is one Shepherd's pi can start.
    var allSignedIn: Bool { missing.allSatisfy { signedIn($0.id) } && unresolvedDefault == nil }

    /// What the Something missing stage asks for, as its title and subtitle.
    var missingTitle: String {
        unresolvedDefault == nil ? Self.missingTitle(missing.count) : missing.isEmpty ? "Your default model needs you" : "Something’s missing"
    }

    var missingSubtitle: String {
        unresolvedDefault == nil ? Self.missingSubtitle(missing.count)
            : "Everything else came over. Shepherd’s copy of pi can’t start a thread on what’s listed here, so set it right before the first one."
    }

    /// "Shepherd’s pi has no provider cpa. Your extensions came over switched off; one of them may add it."
    static func unresolvedDetail(_ model: String) -> String {
        let provider = model.split(separator: "/", maxSplits: 1).first.map(String.init) ?? model
        return "Shepherd’s pi has no provider \(provider). Your extensions came over switched off; one of them may add it."
    }

    /// What the copy passed over or couldn't read, one sentence each (the log has the same).
    var problems: [String] { report.problems + report.skipped }

    /// "10 things were passed over", "1 problem".
    static func problemsTitle(problems: Int, skipped: Int) -> String {
        var parts: [String] = []
        if problems > 0 { parts.append(problems == 1 ? "1 file couldn’t be read" : "\(problems) files couldn’t be read") }
        if skipped > 0 { parts.append(skipped == 1 ? "1 thing was passed over" : "\(skipped) things were passed over") }
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String?
        var count: String?
        var state: SHStepState
    }

    /// The steps card: one row per item, pending ones with their titles alone; an item their pi
    /// has none of is left out once the copy knows. Unreadable sign-ins are one failed row.
    var rows: [Row] {
        var rows: [Row] = []
        let report = report
        let subscriptions = report.logins.filter { $0.kind == .subscription }
        let keys = report.logins.filter { if case .apiKey = $0.kind { true } else { false } }
        for step in YourPiImportStep.allCases {
            let state = steps[step] ?? .pending
            let finished = state == .done
            func add(_ title: String, detail: String? = nil, count: String? = nil) {
                rows.append(Row(id: step.rawValue, title: title, detail: detail, count: finished ? count : nil, state: Self.mark(state)))
            }
            switch step {
            case .logins:
                if report.signInsUnreadable != nil {
                    rows.append(Row(id: "loginsAndKeys", title: "Logins and API keys", detail: "auth.json isn’t valid JSON", state: .failed))
                } else if !finished || !subscriptions.isEmpty || report.logins.contains(where: { if case .other = $0.kind { true } else { false } }) {
                    add("Logins", detail: finished ? Self.names(subscriptions.map(\.provider)) : nil,
                        count: YourPiText.count(subscriptions.count, "subscription"))
                }
            case .apiKeys:
                if report.signInsUnreadable == nil, !finished || !keys.isEmpty {
                    add("API keys", detail: finished ? Self.names(keys.map(\.provider)) : nil, count: YourPiText.count(keys.count, "key"))
                }
            case .customProviders:
                if !finished || !report.customProviders.isEmpty {
                    add("Custom providers", detail: "models.json", count: YourPiText.count(report.customProviders.count, "provider"))
                }
            case .defaultModel:
                if !finished || report.defaultModel != nil {
                    add("Default model", count: report.defaultModel.map(NativeModelChoices.shortName))
                }
            case .trustedFolders:
                if !finished || report.trustedFolders > 0 {
                    add("Trusted folders", count: YourPiText.count(report.trustedFolders, "folder"))
                }
            case .files:
                let files = report.copied.filter { $0.kind != .extensions }
                if !finished || !files.isEmpty {
                    add("Instructions, skills and prompts", detail: "Copied into Shepherd", count: Self.filesCount(report))
                }
            case .extensions:
                let count = report.copied(.extensions).count
                if !finished || count > 0 {
                    add("Extensions", detail: "Listed, switched off", count: "\(count) found")
                }
            }
        }
        return rows
    }

    static func mark(_ state: StepState) -> SHStepState {
        switch state {
        case .pending: .pending
        case .running: .now
        case .done: .done
        case .failed: .failed
        }
    }

    /// "Anthropic, OpenAI Codex, Kimi".
    static func names(_ providers: [String]) -> String? {
        providers.isEmpty ? nil : providers.map(PiSignInCatalog.name).joined(separator: ", ")
    }

    /// "AGENTS.md · 12 · 5": the instructions file, then how many skills and prompts.
    static func filesCount(_ report: YourPiImportReport) -> String {
        var parts: [String] = []
        if let context = report.copied(.instructions).first(where: { YourPiFiles.contextFileNames.contains($0.name) }) {
            parts.append(context.name)
        }
        parts.append("\(report.copied(.skills).count)")
        parts.append("\(report.copied(.prompts).count)")
        return parts.joined(separator: " · ")
    }

    /// What came over, in one line (`PiImportSummary`): counts first, as the board draws them.
    var summary: [SHImportSummary.Part] {
        let logins = report.logins.filter { if case .apiKey = $0.kind { false } else { true } }.count
        let keys = report.logins.count - logins
        var parts: [SHImportSummary.Part] = []
        if report.signInsUnreadable == nil {
            if logins > 0 { parts.append(.init(logins == 1 ? "login" : "logins", count: logins)) }
            if keys > 0 { parts.append(.init(keys == 1 ? "API key" : "API keys", count: keys)) }
        }
        if !report.customProviders.isEmpty { parts.append(.init("custom providers")) }
        if let model = report.defaultModel {
            parts.append(.init("default model", value: stage == .done ? NativeModelChoices.shortName(model) : nil))
        }
        if report.trustedFolders > 0 {
            parts.append(.init(report.trustedFolders == 1 ? "trusted folder" : "trusted folders", count: report.trustedFolders))
        }
        let skills = report.copied(.skills).count, prompts = report.copied(.prompts).count
        let instructions = !report.copied(.instructions).isEmpty
        if stage == .done {
            if instructions { parts.append(.init("instructions")) }
            if skills > 0 { parts.append(.init(skills == 1 ? "skill" : "skills", count: skills, comma: instructions)) }
            if prompts > 0 { parts.append(.init(prompts == 1 ? "prompt" : "prompts", count: prompts, comma: instructions || skills > 0)) }
        } else if instructions || skills > 0 || prompts > 0 {
            parts.append(.init("instructions, skills, prompts"))
        }
        return parts
    }

    /// "Two sign-ins need you", "A sign-in needs you".
    static func missingTitle(_ count: Int) -> String {
        let words = ["", "A sign-in needs", "Two sign-ins need", "Three sign-ins need", "Four sign-ins need", "Five sign-ins need"]
        return (count < words.count ? words[count] : "\(count) sign-ins need") + " you"
    }

    static func missingSubtitle(_ count: Int) -> String {
        count == 1 ? "Everything else came over. Shepherd’s copy of pi isn’t signed in to this one, so sign in to it here."
            : "Everything else came over. Shepherd’s copy of pi isn’t signed in to these, so sign in to them here."
    }
}

/// Bringing over your pi (`PiImportSheet`): in progress, done, something missing, a new user, or
/// failed. Nothing on it shows a credential's value.
struct PiImportSheet: View {
    let state: PiImportSheetState
    /// Opens the sign-in sheet over this one (`key` for Use an API key's providers).
    let signIn: (String, Bool) -> Void
    let retry: () -> Void
    let reviewExtensions: () -> Void
    let close: () -> Void
    /// Another default model, picked from what Shepherd's pi can start (Something missing).
    var chooseDefault: (String) -> Void = { _ in }
    @State private var showsProblems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.stage {
            case .progress: progress
            case .done: done
            case .missing: missing
            case .newUser: newUser
            case .failed: failed
            }
        }
        .frame(width: state.stage == .newUser ? SHPiSignInMetrics.importWideWidth : SHPiSignInMetrics.importWidth)
        .background(Color.sh.bgWindow)
        .shAnimation(.disclosure, value: state.stage)
        .interactiveDismissDisabled(state.stage == .progress)
    }

    private var from: String {
        ((state.from ?? "~/.pi/agent") as NSString).abbreviatingWithTildeInPath
    }

    private var stepsCard: some View {
        SHSheetCard {
            ForEach(state.rows) { row in
                SHImportStepRow(row.title, detail: row.detail, count: row.count, state: row.state)
            }
        }
    }

    // MARK: Stages

    @ViewBuilder private var progress: some View {
        SHSheetHeader("Bringing over your pi…", leading: .glyph("square.and.arrow.down", .neutral)) {
            (Text("Once, from ") + Text(from).font(.shMono(SHPiSignInMetrics.subtitleMonoSize)).foregroundColor(Color.sh.textPrimary)
                + Text(". The pi in your terminal isn’t changed."))
                .shText(size: SHPiSignInMetrics.sheetSubtitleSize, lineHeight: SHPiSignInMetrics.proseLeading)
                .foregroundStyle(Color.sh.textSecondary)
        }
        stepsCard
            .padding(.top, SHPiSignInMetrics.bodyTop)
            .padding(.horizontal, SHPiSignInMetrics.sheetInset)
            .padding(.bottom, SHPiSignInMetrics.sheetInset)
    }

    @ViewBuilder private var done: some View {
        SHSheetHeader("Your pi is in Shepherd", leading: .glyph("checkmark", .done)) {
            SHImportSummary(state.summary)
        }
        VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
            Text("Shepherd now runs its own copy of pi. The pi in your terminal is untouched.")
                .shText(size: SHPiSignInMetrics.leadSize, lineHeight: SHPiSignInMetrics.leadLeading)
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            let extensions = state.report.copied(.extensions).count
            if extensions > 0 {
                SHNoteCard(glyph: "puzzlepiece.extension", link: "Review extensions", action: reviewExtensions) {
                    (Text(YourPiText.count(extensions, "extension")).fontWeight(.semibold).foregroundColor(Color.sh.textPrimary)
                        + Text(" came over switched off. They’re code that runs with full access, so you turn each one on yourself."))
                        .shText(size: SHPiSignInMetrics.noteProseSize, lineHeight: SHPiSignInMetrics.proseLeading)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            problems
        }
        .padding(.top, SH.Space.xl)
        .padding(.leading, SHPiSignInMetrics.sheetInset + SHPiSignInMetrics.sheetTile + SHPiSignInMetrics.bodyGap)
        .padding(.trailing, SHPiSignInMetrics.sheetInset)
        .padding(.bottom, SHPiSignInMetrics.bodyBottom)
        SHSheetFooter {
            Button("Done", action: close).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
        }
    }

    /// What the copy passed over or couldn't read (skills of one name, a package never installed,
    /// an unreadable file): a count that opens the sentences, so a green check never hides them.
    @ViewBuilder private var problems: some View {
        let problems = state.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Button {
                    showsProblems.toggle()
                } label: {
                    HStack(spacing: SH.Space.s) {
                        Image(systemName: "exclamationmark.circle").font(.shSans(SHPiSignInMetrics.smallPrintSize))
                            .foregroundStyle(Color.sh.lanternText).accessibilityHidden(true)
                        Text(PiImportSheetState.problemsTitle(problems: state.report.problems.count, skipped: state.report.skipped.count))
                            .font(.shSans(SHPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.sh.textSecondary)
                        Image(systemName: showsProblems ? "chevron.down" : "chevron.right")
                            .font(.shSans(SHPiSignInMetrics.smallPrintSize, .semibold)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsProblems ? "Hide what was passed over" : "Show what was passed over")
                if showsProblems {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SH.Space.xs) {
                            ForEach(Array(problems.enumerated()), id: \.offset) { _, sentence in
                                Text(sentence).font(.shSans(SHPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.sh.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.importProblemsMaxHeight)
                    .shTransition(.disclosure)
                }
            }
            .padding(.horizontal, SH.Space.xxs)
            .shAnimation(.disclosure, value: showsProblems)
        }
    }

    @ViewBuilder private var missing: some View {
        SHSheetHeader(state.missingTitle, subtitle: state.missingSubtitle, leading: .glyph("key", .attention))
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHSheetCard {
                if let model = state.unresolvedDefault {
                    // The default model nothing can start, and the models that can take its place.
                    HStack(spacing: SHPiSignInMetrics.rowGap) {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text("Default model · \(NativeModelChoices.shortName(model))")
                                .font(.shSans(SHPiSignInMetrics.nameSize, .medium)).foregroundStyle(Color.sh.textPrimary)
                            Text(PiImportSheetState.unresolvedDetail(model))
                                .font(.shSans(SHPiSignInMetrics.stepDetailSize)).foregroundStyle(Color.sh.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SHPopupMenu("Choose model", minWidth: AppLayout.importModelMenuWidth) {
                            ForEach(state.catalog, id: \.self) { id in
                                Button(id) { chooseDefault(id) }
                            }
                        }
                        .accessibilityLabel("Choose another default model")
                    }
                    .padding(.vertical, SHPiSignInMetrics.rowVertical)
                    .padding(.horizontal, SHPiSignInMetrics.rowSides)
                }
                ForEach(state.missing) { item in
                    SHImportSignInRow(PiSignInCatalog.name(item.id), badge: PiSignInCatalog.badge(item.id), detail: item.detail,
                                      signedIn: state.signedIn(item.id)) { signIn(item.id, false) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Image(systemName: "info.circle").font(.shSans(SHPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                SHImportSummary(state.summary, size: SHPiSignInMetrics.smallPrintSize, quiet: true)
            }
            .padding(.horizontal, SH.Space.xxs)
            problems
        }
        .padding(.top, SH.Space.xl)
        .padding(.horizontal, SHPiSignInMetrics.sheetInset)
        .padding(.bottom, SHPiSignInMetrics.bodyBottom)
        SHSheetFooter {
            Button("Skip for now", action: close).buttonStyle(.sh(.secondary)).keyboardShortcut(.cancelAction)
            Button("Done", action: close).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                .disabled(!state.allSignedIn)
        }
    }

    @ViewBuilder private var newUser: some View {
        SHSheetHeader("Sign in to a model provider",
                      subtitle: "There’s no pi on this Mac, so there’s nothing to bring over. Use a subscription you already pay for, or an API key.",
                      leading: .glyph("person.badge.key", .neutral))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: SH.Space.m), GridItem(.flexible())], spacing: SH.Space.m) {
            ForEach(PiSignInCatalog.subscriptions) { subscription in
                Button { signIn(subscription.id, false) } label: {
                    SHSignInChoiceTile(subscription.name, detail: subscription.plan, badge: PiSignInCatalog.badge(subscription.id))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign in to \(subscription.name)")
            }
            Menu {
                ForEach(PiSignInCatalog.keyProviders, id: \.self) { provider in
                    Button(PiSignInCatalog.name(provider)) { signIn(provider, true) }
                }
            } label: {
                SHSignInChoiceTile("Use an API key", detail: PiSignInPage.addableSummary(PiSignInCatalog.keyProviders))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Use an API key")
        }
        .padding(.top, SHPiSignInMetrics.bodyTop)
        .padding(.horizontal, SHPiSignInMetrics.sheetInset)
        .padding(.bottom, SHPiSignInMetrics.sheetInset)
        SHSheetFooter {
            Text("Change these any time in Settings ▸ Pi ▸ Sign-in.").font(.shSans(SHPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.sh.textTertiary)
        } actions: {
            Button("Skip", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var failed: some View {
        let unreadable = state.report.signInsUnreadable
        SHSheetHeader("Couldn’t read your pi’s sign-ins", subtitle: "Everything else came over. Your file wasn’t changed.",
                      leading: .glyph("exclamationmark.triangle", .failed))
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHFailureBox(((unreadable?.path ?? "auth.json") as NSString).abbreviatingWithTildeInPath, detail: unreadable?.reason,
                         monoTitle: true, monoDetail: true)
            Text("Fix the file and try again, or skip and sign in here instead. Agents that need a sign-in wait either way.")
                .shText(size: SHPiSignInMetrics.proseSize, lineHeight: SHPiSignInMetrics.leadLeading)
                .foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            stepsCard
        }
        .padding(.top, SH.Space.xl)
        .padding(.horizontal, SHPiSignInMetrics.sheetInset)
        .padding(.bottom, SHPiSignInMetrics.bodyBottom)
        SHSheetFooter {
            Button {
                if let path = unreadable?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.sh(.ghost))
        } actions: {
            Button("Skip", action: close).buttonStyle(.sh(.secondary)).keyboardShortcut(.cancelAction)
            Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                .disabled(state.retrying)
        }
    }
}
