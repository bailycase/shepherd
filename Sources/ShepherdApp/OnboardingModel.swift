import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

/// First-run setup (the Onboarding boards): Welcome, Your pi, Sign in, A space, Your Macs, Ready. The steps use what the app
/// already does: the first launch's copy of the person's pi, the provider sign-ins, adding a space, pairing a Mac and starting a thread.
@MainActor @Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable {
        case welcome, pi, signIn, space, fleet, ready

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .pi: "Your pi"
            case .signIn: "Sign in"
            case .space: "A space"
            case .fleet: "Your Macs"
            case .ready: "Ready"
            }
        }
    }

    /// Shown over the window until the flow ends.
    private(set) var isActive = false
    private(set) var step = Step.welcome
    /// A pi of the person's came over on this launch: its step shows, else it is skipped.
    var hasPi = false
    /// The repos found in the first folder that has any.
    private(set) var candidates: [OnboardingScan.Candidate] = []
    private(set) var scanRoot: String?
    private(set) var scanned = false
    var selection: String?
    /// The space the person added here, for the last step.
    private(set) var addedSpace: SpaceID?
    private(set) var adding = false
    private(set) var problem: String?
    var prompt = ""
    @ObservationIgnored private let marker: URL?
    @ObservationIgnored private let home: URL

    /// `marker` is a file in the support folder: where onboarding ended is a fact about that folder, so a fresh one starts it again.
    init(marker: URL? = (try? ShepherdPaths.supportDirectory())?.appendingPathComponent("onboarding-finished"),
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.marker = marker
        self.home = home
    }

    var finishedBefore: Bool { marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// The steps this run shows, in order.
    var steps: [Step] { Step.allCases.filter { $0 != .pi || hasPi } }
    var position: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { position == 0 }

    func begin() {
        guard !isActive else { return }
        step = .welcome
        isActive = true
    }

    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
        problem = nil
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
        problem = nil
    }

    /// A dot: a step already passed.
    func go(to target: Step) {
        guard target < step, steps.contains(target) else { return }
        step = target
        problem = nil
    }

    func finish() {
        isActive = false
        if let marker { try? Data().write(to: marker) }
    }

    // MARK: A space

    func scan() async {
        let home = home
        let found = await Task.detached(priority: .userInitiated) { OnboardingScan.find(in: home) }.value
        use(root: found.root, candidates: found.candidates)
    }

    /// What a scan found: the list, with the first repo picked unless one already is.
    func use(root: String?, candidates found: [OnboardingScan.Candidate]) {
        scanRoot = root
        candidates = found
        if selection == nil || !candidates.contains(where: { $0.path == selection }) { selection = candidates.first?.path }
        scanned = true
    }

    /// A folder chosen by hand joins the list and is picked.
    func choose(folder path: String) {
        let url = URL(fileURLWithPath: path)
        let candidate = OnboardingScan.candidate(at: url, home: home)
        if !candidates.contains(where: { $0.path == candidate.path }) { candidates.append(candidate) }
        selection = candidate.path
    }

    func setAdding(_ value: Bool, problem: String? = nil) {
        adding = value
        self.problem = problem
    }

    func added(_ id: SpaceID?) {
        addedSpace = id
    }
}

/// Where the repos are: the first of the usual folders with a git repository in it.
enum OnboardingScan {
    struct Candidate: Identifiable, Equatable {
        var path: String
        var name: String
        /// "~/Developer/payments-api".
        var display: String
        var branch: String
        var id: String { path }
    }

    static let roots = ["Developer", "code", "src", "Projects", "dev", "Documents/GitHub", "GitHub", "repos", "work"]

    static func find(in home: URL) -> (root: String?, candidates: [Candidate]) {
        let manager = FileManager.default
        for root in roots {
            let folder = home.appendingPathComponent(root, isDirectory: true)
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            let repos = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .filter { !$0.hasPrefix(".") }
                .map { folder.appendingPathComponent($0, isDirectory: true) }
                .filter { manager.fileExists(atPath: $0.appendingPathComponent(".git").path) }
                .prefix(8).map { candidate(at: $0, home: home) }
            if !repos.isEmpty { return ("~/" + root, Array(repos)) }
        }
        return (nil, [])
    }

    static func candidate(at url: URL, home: URL) -> Candidate {
        var display = url.path
        if display.hasPrefix(home.path) { display = "~" + display.dropFirst(home.path.count) }
        return Candidate(path: url.path, name: url.lastPathComponent, display: display, branch: branch(of: url))
    }

    /// The checked-out branch, read from `.git/HEAD` ("ref: refs/heads/main"); a detached head shows its short hash.
    static func branch(of repo: URL) -> String {
        guard let head = try? String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        let prefix = "ref: refs/heads/"
        return head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : String(head.prefix(7))
    }
}
