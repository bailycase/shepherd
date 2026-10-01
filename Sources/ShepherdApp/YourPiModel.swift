import Foundation
import ShepherdSessions

/// Settings ▸ Pi's view of Shepherd's sign-ins and the user's own pi, and the first launch's copy
/// from it with its sheet (docs/design/settings-pi.md › Pi ▸ Sign-in, Pi ▸ From your pi, Dialogs and sheets ›
/// Bringing over your pi). Every read and write runs off the main thread (`YourPiImport`: plain
/// files, a login shell the first time); what views draw is the latest `survey`, a plain value.
@MainActor @Observable
final class YourPiModel {
    /// Both sides as last read; nil until the first read.
    private(set) var survey: YourPiSurvey?
    /// A failed Re-import or switch, by row (`rowID`), shown inline.
    private(set) var problems: [String: String] = [:]
    /// Rows with a copy under way.
    private(set) var busy: Set<String> = []
    /// Rows re-imported while Settings shows them ("Re-imported just now").
    private(set) var reimported: Set<String> = []
    /// The first launch's sheet while it shows (`AppDialogs`); closing it ends the first launch's
    /// hold.
    var importSheet: PiImportSheetState?

    @ObservationIgnored let pi: PiSetup
    /// A fixed survey (previews) is never read again.
    @ObservationIgnored private let fixed: Bool
    /// The first launch's copy (`PiSetup.copyYourPiOnce`), and how long restored agents wait for it.
    typealias FirstCopy = @Sendable (PiSetup, @escaping @Sendable (YourPiImportProgress) -> Void) -> YourPiImportReport?
    @ObservationIgnored private let firstCopy: FirstCopy
    @ObservationIgnored private let copyDeadline: Duration
    /// How long the sheet shows its last step before it turns to what came over.
    @ObservationIgnored var doneBeat: Duration = AppLayout.importDoneBeat
    /// The models restored agents and the default use, whose providers the sheet asks for.
    @ObservationIgnored private var neededModels: [String] = []

    init(pi: PiSetup, survey: YourPiSurvey? = nil, copyDeadline: Duration = YourPiModel.copyDeadline,
         firstCopy: @escaping FirstCopy = { pi, progress in pi.copyYourPiOnce(progress: progress) }) {
        self.pi = pi
        self.survey = survey
        fixed = survey != nil
        self.copyDeadline = copyDeadline
        self.firstCopy = firstCopy
    }

    /// Re-reads both sides.
    func refresh() async {
        guard !fixed else { return }
        let pi = pi
        let next = await Task.detached(priority: .userInitiated) { pi.imports().survey(environmentKeys: pi.yourPi.environmentKeys()) }.value
        if next != survey { survey = next }
    }

    /// The row a Re-import or switch belongs to.
    static func rowID(_ item: YourPiImport.Item) -> String {
        switch item {
        case .login(let provider): "login:\(provider)"
        case .logins: "logins"
        case .customProviders: "customProviders"
        case .defaultModel: "defaultModel"
        case .trust: "trust"
        case .files(let kind): "files:\(kind.rawValue)"
        }
    }

    /// Copies `item` from the user's pi again, overwriting Shepherd's copy.
    func reimport(_ item: YourPiImport.Item) async {
        let row = Self.rowID(item)
        await run(row) { pi in _ = try pi.imports().reimport(item) }
        if problems[row] == nil { reimported.insert(row) }
        // A login or providers changed: the model catalog reads the home's files afresh.
        pi.catalog.invalidate()
        if case .login = item { onSignInsChanged?() } else if item == .logins { onSignInsChanged?() }
    }

    /// Re-import all: every item, in the order the first copy took them.
    func reimportAll() async {
        let survey = survey ?? YourPiSurvey()
        var items: [YourPiImport.Item] = [.logins]
        if !survey.customProviders.isEmpty { items.append(.customProviders) }
        if survey.defaultModel != nil { items.append(.defaultModel) }
        if survey.trustedFolders > 0 { items.append(.trust) }
        items += YourPiResourceKind.allCases.map { .files($0) }
        for item in items { await reimport(item) }
    }

    /// Logins changed by a Re-import: agents waiting on a sign-in may start.
    @ObservationIgnored var onSignInsChanged: (() -> Void)?

    /// The row of one of the user's extensions, by its copy's destination.
    static func extensionRowID(_ destination: String) -> String { "extension:\(destination)" }

    /// Switches one of the user's extensions on or off (on also tries a failed one again): new
    /// agents load it, running ones on `/reload`.
    func setExtension(_ destination: String, on: Bool) async {
        await run(Self.extensionRowID(destination)) { pi in try pi.importedState().setExtension(destination, on: on) }
    }

    private func run(_ row: String, _ body: @escaping @Sendable (PiSetup) throws -> Void) async {
        guard !fixed, !busy.contains(row) else { return }
        busy.insert(row)
        let pi = pi
        let failure: String? = await Task.detached(priority: .userInitiated) {
            if let problem = pi.prepare() { return problem.message }
            do { try body(pi) } catch { return String(describing: error) }
            return nil
        }.value
        busy.remove(row)
        if problems[row] != failure { problems[row] = failure }
        await refresh()
    }

    // MARK: The first launch

    /// How long the first copy may take before restored agents stop waiting for it.
    nonisolated static let copyDeadline: Duration = .seconds(30)

    /// Which restored agents keep waiting once the first copy is over.
    enum Hold: Equatable {
        /// None: they start at once, while Done shows.
        case none
        /// Every one, until the sheet closes: it asks for a sign-in (New user, Failed), or no
        /// provider can start an agent.
        case all
        /// Those whose model uses one of these providers, until the sheet closes (Something
        /// missing); the rest start at once.
        case agents(using: Set<String>)
    }

    /// The first launch of a build with Shepherd's own pi: copies the user's pi once (or finds it
    /// done), showing the sheet while it runs when there is a pi of theirs to copy, then what came
    /// over, and says which restored agents keep waiting for the sheet to close. The copy is
    /// plain file work that finishes or fails fast; past the deadline agents start anyway.
    /// `models` are the restored agents' and the default model (Settings ▸ Agents' own; pi's is
    /// added here).
    func runFirstLaunch(models: [String] = []) async -> Hold {
        await runFirstLaunch(models: { models })
    }

    /// `models` is read once the copy is over, when the restored workspace is in.
    func runFirstLaunch(models: @MainActor () -> [String]) async -> Hold {
        let pi = pi
        let firstCopy = firstCopy
        let progress: @Sendable (YourPiImportProgress) -> Void = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        let result = await Self.first(within: copyDeadline) { () -> (YourPiImportReport, YourPiSurvey)? in
            guard let report = firstCopy(pi, progress) else { return nil }
            return (report, pi.imports().survey(environmentKeys: pi.yourPi.environmentKeys()))
        }
        guard let (report, survey) = result ?? nil else {
            importSheet = nil
            return .none
        }
        if survey != self.survey { self.survey = survey }
        guard report.first else {
            importSheet = nil
            return .none
        }
        // The progress events hop to the main actor too: the last of them lands before this.
        await Task.yield()
        var sheet = importSheet ?? PiImportSheetState(from: report.from)
        sheet.report = report
        sheet.survey = survey
        neededModels = models()
        let needed = neededModels + [survey.shepherdDefaultModel].compactMap { $0 }
        sheet.missing = PiImportSheetState.missing(survey: survey, models: needed)
        let stage = PiImportSheetState.stage(report: report, survey: survey, missing: sheet.missing)
        guard let stage else {
            importSheet = nil
            return .none
        }
        if importSheet != nil, sheet.stage == .progress {
            // Let the last step land where it can be seen before the sheet turns.
            for step in YourPiImportStep.allCases where sheet.steps[step] == .running { sheet.steps[step] = .done }
            importSheet = sheet
            try? await Task.sleep(for: doneBeat)
        }
        sheet.stage = stage
        importSheet = sheet
        return Self.hold(stage: stage, survey: survey, missing: sheet.missing)
    }

    /// Who waits once the sheet shows `stage`.
    static func hold(stage: PiImportSheetState.Stage, survey: YourPiSurvey, missing: [PiImportSheetState.Missing]) -> Hold {
        if !survey.canStartAgents || stage == .newUser || stage == .failed { return .all }
        if stage == .missing { return .agents(using: Set(missing.map(\.id))) }
        return .none
    }

    /// One step of the first copy, as it goes: the sheet shows once it's known there's a pi to copy.
    func apply(_ event: YourPiImportProgress) {
        switch event {
        case .started(let from):
            if importSheet == nil { importSheet = PiImportSheetState(from: from) }
        case .running(let step):
            importSheet?.steps[step] = .running
        case .finished(let step, let report):
            importSheet?.report = report
            let failed = step == .logins && report.signInsUnreadable != nil
            importSheet?.steps[step] = failed ? .failed : .done
        }
    }

    /// Retry, from a sheet that couldn't read your pi's sign-ins: copies them again, then says
    /// what's still missing, and who still waits.
    func retrySignIns() async -> Hold {
        guard var sheet = importSheet else { return .none }
        sheet.retrying = true
        importSheet = sheet
        let pi = pi
        let outcome: (Result<YourPiImportReport, YourPiFileError>, YourPiSurvey) = await Task.detached(priority: .userInitiated) {
            let result: Result<YourPiImportReport, YourPiFileError>
            do { result = .success(try pi.imports().reimport(.logins)) } catch {
                result = .failure(error as? YourPiFileError ?? YourPiFileError(String(describing: error)))
            }
            return (result, pi.imports().survey(environmentKeys: pi.yourPi.environmentKeys()))
        }.value
        survey = outcome.1
        sheet.retrying = false
        sheet.survey = outcome.1
        pi.catalog.invalidate()
        switch outcome.0 {
        case .success(let copied):
            sheet.report.logins = copied.logins
            sheet.report.signInsUnreadable = nil
            sheet.steps[.logins] = .done
            sheet.steps[.apiKeys] = .done
            sheet.missing = PiImportSheetState.missing(survey: outcome.1, models: neededModels + [outcome.1.shepherdDefaultModel].compactMap { $0 })
            sheet.stage = PiImportSheetState.stage(report: sheet.report, survey: outcome.1, missing: sheet.missing) ?? .done
            onSignInsChanged?()
        case .failure(let error):
            // Still unreadable: the reason as it is now.
            if let path = sheet.report.signInsUnreadable?.path { sheet.report.signInsUnreadable = (path, error.detail ?? error.description) }
        }
        importSheet = sheet
        return Self.hold(stage: sheet.stage, survey: sheet.survey, missing: sheet.missing)
    }

    /// A sign-in landed while the sheet asks for some: its row turns signed in.
    func signInLanded() async {
        await refresh()
        guard var sheet = importSheet, let survey else { return }
        sheet.survey = survey
        importSheet = sheet
    }

    /// `work`'s answer, or nil when `deadline` passes first (the work carries on detached).
    nonisolated static func first<T: Sendable>(within deadline: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task.detached(priority: .userInitiated) {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(for: deadline)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }
}
