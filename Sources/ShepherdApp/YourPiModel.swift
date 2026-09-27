import Foundation
import ShepherdSessions

/// Settings ▸ Pi's view of Shepherd's sign-ins and the user's own pi, and the first launch's copy
/// from it with the welcome step that follows (DESIGN.md › Settings ▸ Pi, Dialogs and sheets ›
/// Welcome). Every read and write runs off the main thread (`YourPiImport`: plain files, a login
/// shell the first time); what views draw is the latest `survey`, a plain value.
@MainActor @Observable
final class YourPiModel {
    /// The welcome step's content: what the first copy brought over, and both sides as they stand.
    struct Welcome: Identifiable, Equatable {
        let id = UUID()
        var report: YourPiImportReport
        var survey: YourPiSurvey
        /// Providers the default model names that nothing in Shepherd's pi can sign in to.
        var missing: [String] = []

        /// No provider can start an agent: restored agents wait for the step to close, so the
        /// user can sign in first.
        var holdsAgents: Bool { !survey.canStartAgents }
        /// The step asks to sign in: nothing can start an agent, or the default model's provider
        /// is missing.
        var asksToSignIn: Bool { !survey.canStartAgents || !missing.isEmpty }
    }

    /// Both sides as last read; nil until the first read.
    private(set) var survey: YourPiSurvey?
    /// A failed Re-import or switch, by row (`rowID`), shown inline.
    private(set) var problems: [String: String] = [:]
    /// Rows with a copy under way.
    private(set) var busy: Set<String> = []
    /// Shown while set (`AppDialogs`); closing it ends the first launch's hold.
    var welcome: Welcome?

    @ObservationIgnored let pi: PiSetup
    /// A fixed survey (previews) is never read again.
    @ObservationIgnored private let fixed: Bool
    /// The first launch's copy (`PiSetup.copyYourPiOnce`), and how long restored agents wait for it.
    @ObservationIgnored private let firstCopy: @Sendable (PiSetup) -> YourPiImportReport?
    @ObservationIgnored private let copyDeadline: Duration

    init(pi: PiSetup, survey: YourPiSurvey? = nil, copyDeadline: Duration = YourPiModel.copyDeadline,
         firstCopy: @escaping @Sendable (PiSetup) -> YourPiImportReport? = { $0.copyYourPiOnce() }) {
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
        case .customProviders: "customProviders"
        case .defaultModel: "defaultModel"
        case .trust: "trust"
        }
    }

    /// Copies `item` from the user's pi again, overwriting Shepherd's copy.
    func reimport(_ item: YourPiImport.Item) async {
        await run(Self.rowID(item)) { pi in _ = try pi.imports().reimport(item) }
        // A login or providers changed: the model catalog reads the home's files afresh.
        pi.catalog.invalidate()
    }

    func setInstructions(_ on: Bool) async {
        await run("instructions") { pi in try pi.imports().setInstructions(on) }
    }

    /// `key` is `skills` or `prompts`.
    func setResources(_ key: String, on: Bool) async {
        await run(key) { pi in try pi.imports().setResources(key, on: on) }
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

    /// The first launch of a build with Shepherd's own pi: copies the user's pi once (or finds it
    /// done), then shows the welcome step when this launch did the copy. True when restored
    /// agents should keep waiting, for the step to close: it shows and no provider can start an
    /// agent. False otherwise, and the caller releases them at once, while any step shows. The
    /// copy is plain file work that finishes or fails fast; if it overruns the deadline, agents
    /// start anyway. `defaultModel` is Shepherd's own (Settings ▸ Agents); without one, pi's.
    func runFirstLaunch(defaultModel: String? = nil) async -> Bool {
        let pi = pi
        let firstCopy = firstCopy
        let result = await Self.first(within: copyDeadline) { () -> (YourPiImportReport, YourPiSurvey)? in
            guard let report = firstCopy(pi) else { return nil }
            return (report, pi.imports().survey(environmentKeys: pi.yourPi.environmentKeys()))
        }
        guard let (report, survey) = result ?? nil else { return false }
        if survey != self.survey { self.survey = survey }
        guard report.first else { return false }
        let models = [defaultModel ?? survey.shepherdDefaultModel].compactMap { $0 }
        let step = Welcome(report: report, survey: survey, missing: survey.missingSignIns(for: models))
        // A user with no pi sees only sign-in: already signed in, with no key found and no
        // problem to report, there is no step at all.
        if report.from == nil, !step.asksToSignIn, report.problems.isEmpty, PiWelcomeSheet.sections(step) == .init() { return false }
        welcome = step
        return step.holdsAgents
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
