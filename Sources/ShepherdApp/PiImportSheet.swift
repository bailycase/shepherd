import SwiftUI
import ShepherdUI
import ShepherdSessions
import ShepherdRemote

/// The first launch's sheet as it stands (PiImport*; DESIGN.md › Dialogs and sheets › Bringing
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

    init(from: String?) {
        self.from = from
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.stage == b.stage && a.from == b.from && a.steps == b.steps && a.report == b.report && a.survey == b.survey
            && a.missing == b.missing && a.retrying == b.retrying
    }

    // MARK: How it ends

    /// The stage a finished first copy shows; nil for no sheet at all (a new user already
    /// signed in with nothing missing).
    static func stage(report: YourPiImportReport, survey: YourPiSurvey, missing: [Missing]) -> Stage? {
        if report.from == nil {
            return survey.canStartAgents && missing.isEmpty ? nil : .newUser
        }
        if report.signInsUnreadable != nil { return .failed }
        return missing.isEmpty ? .done : .missing
    }

    /// Providers the restored agents' and default `models` use that nothing in Shepherd's pi covers.
    static func missing(survey: YourPiSurvey, models: [String]) -> [Missing] {
        survey.missingSignIns(for: models).map { provider in
            let theirs = survey.logins.first { $0.provider == provider }?.yours
            return Missing(id: provider, detail: theirs == nil ? "Your pi isn’t signed in to it" : "Your pi’s sign-in couldn’t be copied")
        }
    }

    /// Whether `provider` is covered now (a sign-in landed, or a key in the environment).
    func signedIn(_ provider: String) -> Bool {
        !survey.missingSignIns(for: ["\(provider)/any"]).contains(provider)
    }

    var allSignedIn: Bool { missing.allSatisfy { signedIn($0.id) } }

    // MARK: Rows

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String?
        var count: String?
        var state: NWStepState
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

    static func mark(_ state: StepState) -> NWStepState {
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
    var summary: [NWImportSummary.Part] {
        let logins = report.logins.filter { if case .apiKey = $0.kind { false } else { true } }.count
        let keys = report.logins.count - logins
        var parts: [NWImportSummary.Part] = []
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
        .frame(width: state.stage == .newUser ? NWPiSignInMetrics.importWideWidth : NWPiSignInMetrics.importWidth)
        .background(Color.nw.bgWindow)
        .nwAnimation(.disclosure, value: state.stage)
        .interactiveDismissDisabled(state.stage == .progress)
    }

    private var from: String {
        ((state.from ?? "~/.pi/agent") as NSString).abbreviatingWithTildeInPath
    }

    private var stepsCard: some View {
        NWSheetCard {
            ForEach(state.rows) { row in
                NWImportStepRow(row.title, detail: row.detail, count: row.count, state: row.state)
            }
        }
    }

    // MARK: Stages

    @ViewBuilder private var progress: some View {
        NWSheetHeader("Bringing over your pi…", leading: .glyph("square.and.arrow.down", .neutral)) {
            (Text("Once, from ") + Text(from).font(.nwMono(NWPiSignInMetrics.subtitleMonoSize)).foregroundColor(Color.nw.textPrimary)
                + Text(". The pi in your terminal isn’t changed."))
                .nwText(size: NWPiSignInMetrics.sheetSubtitleSize, lineHeight: NWPiSignInMetrics.proseLeading)
                .foregroundStyle(Color.nw.textSecondary)
        }
        stepsCard
            .padding(.top, NWPiSignInMetrics.bodyTop)
            .padding(.horizontal, NWPiSignInMetrics.sheetInset)
            .padding(.bottom, NWPiSignInMetrics.sheetInset)
    }

    @ViewBuilder private var done: some View {
        NWSheetHeader("Your pi is in Shepherd", leading: .glyph("checkmark", .done)) {
            NWImportSummary(state.summary)
        }
        VStack(alignment: .leading, spacing: NWPiSignInMetrics.bodyGap) {
            Text("Shepherd now runs its own copy of pi. The pi in your terminal is untouched.")
                .nwText(size: NWPiSignInMetrics.leadSize, lineHeight: NWPiSignInMetrics.leadLeading)
                .foregroundStyle(Color.nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            let extensions = state.report.copied(.extensions).count
            if extensions > 0 {
                NWNoteCard(glyph: "puzzlepiece.extension", link: "Review extensions", action: reviewExtensions) {
                    (Text(YourPiText.count(extensions, "extension")).fontWeight(.semibold).foregroundColor(Color.nw.textPrimary)
                        + Text(" came over switched off. They’re code that runs with full access, so you turn each one on yourself."))
                        .nwText(size: NWPiSignInMetrics.noteProseSize, lineHeight: NWPiSignInMetrics.proseLeading)
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, NW.Space.xl)
        .padding(.leading, NWPiSignInMetrics.sheetInset + NWPiSignInMetrics.sheetTile + NWPiSignInMetrics.bodyGap)
        .padding(.trailing, NWPiSignInMetrics.sheetInset)
        .padding(.bottom, NWPiSignInMetrics.bodyBottom)
        NWSheetFooter {
            Button("Done", action: close).buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var missing: some View {
        NWSheetHeader(PiImportSheetState.missingTitle(state.missing.count),
                      subtitle: PiImportSheetState.missingSubtitle(state.missing.count), leading: .glyph("key", .attention))
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWSheetCard {
                ForEach(state.missing) { item in
                    NWImportSignInRow(PiSignInCatalog.name(item.id), badge: PiSignInCatalog.badge(item.id), detail: item.detail,
                                      signedIn: state.signedIn(item.id)) { signIn(item.id, false) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Image(systemName: "info.circle").font(.nwSans(NWPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
                NWImportSummary(state.summary, size: NWPiSignInMetrics.smallPrintSize, quiet: true)
            }
            .padding(.horizontal, NW.Space.xxs)
        }
        .padding(.top, NW.Space.xl)
        .padding(.horizontal, NWPiSignInMetrics.sheetInset)
        .padding(.bottom, NWPiSignInMetrics.bodyBottom)
        NWSheetFooter {
            Button("Skip for now", action: close).buttonStyle(.nw(.secondary)).keyboardShortcut(.cancelAction)
            Button("Done", action: close).buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
                .disabled(!state.allSignedIn)
        }
    }

    @ViewBuilder private var newUser: some View {
        NWSheetHeader("Sign in to a model provider",
                      subtitle: "There’s no pi on this Mac, so there’s nothing to bring over. Use a subscription you already pay for, or an API key.",
                      leading: .glyph("person.badge.key", .neutral))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: NW.Space.m), GridItem(.flexible())], spacing: NW.Space.m) {
            ForEach(PiSignInCatalog.subscriptions) { subscription in
                Button { signIn(subscription.id, false) } label: {
                    NWSignInChoiceTile(subscription.name, detail: subscription.plan, badge: PiSignInCatalog.badge(subscription.id))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign in to \(subscription.name)")
            }
            Menu {
                ForEach(PiSignInCatalog.keyProviders, id: \.self) { provider in
                    Button(PiSignInCatalog.name(provider)) { signIn(provider, true) }
                }
            } label: {
                NWSignInChoiceTile("Use an API key", detail: PiSignInPage.addableSummary(PiSignInCatalog.keyProviders))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Use an API key")
        }
        .padding(.top, NWPiSignInMetrics.bodyTop)
        .padding(.horizontal, NWPiSignInMetrics.sheetInset)
        .padding(.bottom, NWPiSignInMetrics.sheetInset)
        NWSheetFooter {
            Text("Change these any time in Settings ▸ Pi ▸ Sign-in.").font(.nwSans(NWPiSignInMetrics.smallPrintSize)).foregroundStyle(Color.nw.textTertiary)
        } actions: {
            Button("Skip", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var failed: some View {
        let unreadable = state.report.signInsUnreadable
        NWSheetHeader("Couldn’t read your pi’s sign-ins", subtitle: "Everything else came over. Your file wasn’t changed.",
                      leading: .glyph("exclamationmark.triangle", .failed))
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWFailureBox(((unreadable?.path ?? "auth.json") as NSString).abbreviatingWithTildeInPath, detail: unreadable?.reason,
                         monoTitle: true, monoDetail: true)
            Text("Fix the file and try again, or skip and sign in here instead. Agents that need a sign-in wait either way.")
                .nwText(size: NWPiSignInMetrics.proseSize, lineHeight: NWPiSignInMetrics.leadLeading)
                .foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            stepsCard
        }
        .padding(.top, NW.Space.xl)
        .padding(.horizontal, NWPiSignInMetrics.sheetInset)
        .padding(.bottom, NWPiSignInMetrics.bodyBottom)
        NWSheetFooter {
            Button {
                if let path = unreadable?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.nw(.ghost))
        } actions: {
            Button("Skip", action: close).buttonStyle(.nw(.secondary)).keyboardShortcut(.cancelAction)
            Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
                .disabled(state.retrying)
        }
    }
}
