import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// The trigger engine against a stand-in GitHub and a stand-in app: what fires, what waits, what
/// never fires, and every bound reached (runs at once, runs a day, pending expiry, backoff, pause).
@Suite("Automation trigger engine")
struct AutomationTriggersTests {
    /// Everything the engine touches, recorded.
    final class World: @unchecked Sendable {
        let lock = NSLock()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var automations: [Automation] = []
        var items: [GitHubItem] = []
        var readError: AutomationTriggers.SourceError?
        var reads = 0
        var started: [[AutomationEvent]] = []
        var live: [AutomationID: [String?]] = [:]
        var thread: AutomationTriggers.ThreadState = .idle
        var failStarts = 0
        var failures: [String] = []
        var notes: [String] = []
        var origin: String? = "acme/app"

        func with<T>(_ body: (World) throws -> T) rethrows -> T { try lock.withLock { try body(self) } }
        func advance(_ seconds: TimeInterval) { with { $0.now = $0.now.addingTimeInterval(seconds) } }
    }

    static func engine(_ world: World, url: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("triggers-\(UUID().uuidString).json")) async -> AutomationTriggers {
        let source = AutomationTriggers.Source(
            activity: { _ in
                try world.with { w in
                    w.reads += 1
                    if let error = w.readError { throw error }
                    return w.items
                }
            },
            originRepo: { _ in world.with { $0.origin } })
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let engine = AutomationTriggers(url: url, source: source, clock: { world.with { $0.now } }, calendar: utc)
        await engine.install(AutomationTriggers.Host(
            automations: { world.with { $0.automations } },
            liveRuns: { id in world.with { $0.live[id] ?? [] } },
            threadState: { _ in world.with { $0.thread } },
            start: { _, events in
                try world.with { w in
                    if w.failStarts > 0 {
                        w.failStarts -= 1
                        throw AutomationTriggers.SourceError("worktree failed", permanent: false)
                    }
                    w.started.append(events)
                    w.live[w.automations[0].id, default: []].append(events.first?.id)
                }
            },
            recordFailure: { _, event, message in world.with { $0.failures.append("\(event?.id ?? "-"): \(message)") } },
            notify: { title, _ in world.with { $0.notes.append(title) } }))
        return engine
    }

    static func loop(_ limits: AutomationLimits = .default, gate: AutomationAuthorGate = .collaborators,
                     events: [GitHubEventKind] = [.issueLabeled], labels: [String] = ["shepherd"]) -> Automation {
        Automation(id: AutomationID(rawValue: "loop"), name: "issue loop", prompt: "speckit it", cwd: "/tmp",
                   trigger: .github([GitHubTrigger(events: events, labels: labels)]), authorGate: gate, limits: limits)
    }

    /// An issue labeled `label` by `actor` at `at`.
    static func labeled(_ number: Int, at: Date, label: String = "shepherd", author: String = "stranger",
                        association: String = "NONE", actor: String = "maintainer") -> GitHubItem {
        GitHubItem(repo: "acme/app", number: number, isPullRequest: false, title: "Issue \(number)", body: "please fix",
                   url: "https://github.com/acme/app/issues/\(number)", createdAt: at.addingTimeInterval(-3600),
                   author: author, association: association, labels: [label], headOID: nil,
                   events: [.init(id: "L\(number)-\(Int(at.timeIntervalSince1970))", at: at, activity: .labeled(label: label, actor: actor))])
    }

    // MARK: GitHub matching

    @Test func parsesTheGraphQLAnswer() throws {
        let json = """
        {"data":{"repository":{
          "issues":{"nodes":[{"number":12,"title":"Fix login","body":"b","url":"u","createdAt":"2026-10-30T10:00:00Z",
            "authorAssociation":"NONE","author":{"login":"stranger"},"labels":{"nodes":[{"name":"shepherd"}]},
            "timelineItems":{"nodes":[
              {"__typename":"LabeledEvent","id":"LE1","createdAt":"2026-10-30T11:00:00Z","actor":{"login":"owner"},"label":{"name":"shepherd"}},
              {"__typename":"IssueComment","id":"IC1","createdAt":"2026-10-30T12:00:00Z","url":"cu","body":"hi","authorAssociation":"OWNER","author":{"login":"owner"}}]}}]},
          "pullRequests":{"nodes":[{"number":40,"title":"PR","body":"","url":"pu","createdAt":"2026-10-30T09:00:00Z",
            "authorAssociation":"MEMBER","author":{"login":"m"},"headRefOid":"abc","labels":{"nodes":[]},
            "timelineItems":{"nodes":[
              {"__typename":"PullRequestReview","id":"R1","submittedAt":"2026-10-30T13:00:00Z","url":"ru","body":"lgtm","state":"APPROVED","authorAssociation":"MEMBER","author":{"login":"m2"}},
              {"__typename":"PullRequestReview","id":"R2","submittedAt":null,"state":"PENDING"},
              {"__typename":"MergedEvent","id":"M1","createdAt":"2026-10-30T14:00:00Z"}]}}]}}}}
        """
        let items = try GitHubActivity.parse(Data(json.utf8), repo: "acme/app")
        #expect(items.count == 2)
        #expect(items[0].key == "acme/app#12" && items[0].events.count == 2 && items[0].labels == ["shepherd"])
        #expect(items[1].isPullRequest && items[1].headOID == "abc" && items[1].events.count == 2)

        let missing = #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"x"}]}"#
        #expect(throws: GitHubActivity.ResponseError(description: "Repository acme/app wasn't found, or gh can't see it.", permanent: true)) {
            try GitHubActivity.parse(Data(missing.utf8), repo: "acme/app")
        }
    }

    /// The author gate runs before anything reaches a model.
    @Test func authorGate() {
        let t = Date(timeIntervalSince1970: 1_000)
        func fire(_ item: GitHubItem, _ kinds: [GitHubEventKind], labels: [String] = []) -> [AutomationEvent] {
            GitHubActivity.events(in: [item], triggers: [GitHubTrigger(events: kinds, labels: labels)], repoOf: { _ in "acme/app" },
                                  gate: .collaborators, since: .distantPast, now: t, heads: [:])
        }
        // A maintainer labeling a stranger's issue fires: only triagers can label.
        #expect(fire(Self.labeled(1, at: t), [.issueLabeled], labels: ["shepherd"]).count == 1)
        // A stranger whose issue template applied the label doesn't.
        #expect(fire(Self.labeled(2, at: t, actor: "stranger"), [.issueLabeled]).isEmpty)
        // A stranger opening an issue doesn't; a member does.
        #expect(fire(Self.labeled(3, at: t), [.issueOpened]).isEmpty)
        #expect(fire(Self.labeled(4, at: t, association: "MEMBER"), [.issueOpened]).count == 1)
        // Comments are gated on the commenter.
        var commented = Self.labeled(5, at: t, association: "OWNER")
        commented.events = [.init(id: "C", at: t, activity: .comment(author: "x", association: "NONE", body: "do it", url: nil))]
        #expect(fire(commented, [.issueComment]).isEmpty)
        // A label other than the one asked for never fires.
        #expect(fire(Self.labeled(6, at: t, label: "bug"), [.issueLabeled], labels: ["shepherd"]).isEmpty)
    }

    @Test func newCommitsOnAPullRequest() {
        let t = Date(timeIntervalSince1970: 1_000)
        let pr = GitHubItem(repo: "acme/app", number: 9, isPullRequest: true, title: "PR", body: "", url: nil, createdAt: t,
                            author: "m", association: "MEMBER", labels: [], headOID: "new", events: [])
        let trigger = [GitHubTrigger(events: [.pullRequestCommits])]
        let first = GitHubActivity.events(in: [pr], triggers: trigger, repoOf: { _ in "acme/app" }, gate: .collaborators,
                                          since: .distantPast, now: t, heads: [:])
        #expect(first.isEmpty) // first sight is the baseline
        let pushed = GitHubActivity.events(in: [pr], triggers: trigger, repoOf: { _ in "acme/app" }, gate: .collaborators,
                                           since: .distantPast, now: t, heads: ["acme/app#9": "old"])
        #expect(pushed.map(\.id) == ["acme/app#9:commits:new"])
    }

    @Test func remoteURLs() {
        #expect(GitHubActivity.repo(fromRemote: "git@github.com:acme/app.git\n") == "acme/app")
        #expect(GitHubActivity.repo(fromRemote: "https://github.com/acme/app") == "acme/app")
        #expect(GitHubActivity.repo(fromRemote: "https://gitlab.com/acme/app.git") == nil)
    }

    // MARK: Engine

    /// What existed before the automation was enabled never fires; what happens after fires once.
    @Test func baselineAndDedupe() async {
        let world = World()
        world.automations = [Self.loop()]
        world.items = [Self.labeled(1, at: world.now.addingTimeInterval(-60))]
        let engine = await Self.engine(world)
        await engine.tick()
        #expect(world.started.isEmpty)
        world.advance(61)
        world.items.append(Self.labeled(2, at: world.now.addingTimeInterval(-5)))
        await engine.tick()
        #expect(world.started.map { $0.map(\.id) } == [["acme/app#2:labeled:L2-\(Int(world.now.addingTimeInterval(-5).timeIntervalSince1970))"]])
        world.advance(61)
        world.live = [:]
        await engine.tick()
        #expect(world.started.count == 1)
        // GitHub is read at most once a minute.
        let reads = world.reads
        world.advance(10)
        await engine.tick()
        #expect(world.reads == reads)
    }

    /// Runs at once and runs a day are both hard limits; past them events wait, and one note says so.
    @Test func limits() async {
        let world = World()
        world.automations = [Self.loop(AutomationLimits(maxConcurrent: 2, maxPerDay: 3))]
        let engine = await Self.engine(world)
        await engine.tick()
        world.advance(61)
        world.items = (1...5).map { Self.labeled($0, at: world.now.addingTimeInterval(-Double(10 - $0))) }
        await engine.tick()
        #expect(world.started.count == 2)
        var status = await engine.status(of: world.automations[0])
        #expect(status.pending.count == 3 && status.runsToday == 2)
        // Runs finish: one more fits under the daily limit of 3, then the rest wait.
        world.live = [:]
        world.advance(61)
        await engine.tick()
        #expect(world.started.count == 3)
        world.live = [:]
        world.advance(61)
        await engine.tick()
        #expect(world.started.count == 3)
        status = await engine.status(of: world.automations[0])
        #expect(status.pending.count == 2)
        #expect(world.notes.filter { $0.contains("daily limit") }.count == 1)
        // The user can run one now past the limit.
        await #expect(throws: Never.self) { try await engine.runPending(world.automations[0], eventID: status.pending[0].id) }
        #expect(world.started.count == 4)
        // Pending events expire after a week.
        world.advance(AutomationTriggers.pendingLifetime + 1)
        world.readError = AutomationTriggers.SourceError("offline", permanent: false)
        await engine.tick()
        #expect(await engine.status(of: world.automations[0]).pending.isEmpty)
    }

    /// A lasting error pauses with its reason and one note; a passing one backs off and retries.
    @Test func failures() async {
        let world = World()
        world.automations = [Self.loop()]
        let engine = await Self.engine(world)
        world.readError = AutomationTriggers.SourceError("offline", permanent: false)
        await engine.tick()
        var status = await engine.status(of: world.automations[0])
        #expect(status.state == .retrying && status.retryAt == world.now.timeIntervalSince1970 + 60)
        world.advance(61)
        await engine.tick()
        status = await engine.status(of: world.automations[0])
        #expect(status.retryAt == world.now.timeIntervalSince1970 + 120)
        // Backoff tops out at 30 minutes.
        for _ in 0..<10 { world.advance(AutomationTriggers.maxBackoff); await engine.tick() }
        status = await engine.status(of: world.automations[0])
        #expect(status.retryAt.map { $0 - world.now.timeIntervalSince1970 } == AutomationTriggers.maxBackoff)
        world.readError = AutomationTriggers.SourceError("gh isn't signed in.", permanent: true)
        world.advance(AutomationTriggers.maxBackoff)
        await engine.tick()
        status = await engine.status(of: world.automations[0])
        #expect(status.state == .paused && status.reason == "gh isn't signed in.")
        let reads = world.reads
        world.advance(3600)
        await engine.tick()
        #expect(world.reads == reads) // paused means no checks
        #expect(world.notes == ["issue loop paused"])
        // Resume checks again and fires nothing from while it was paused.
        world.readError = nil
        world.items = [Self.labeled(7, at: world.now.addingTimeInterval(-30))]
        await engine.resume(world.automations[0].id)
        await engine.tick()
        #expect(world.reads == reads + 1 && world.started.isEmpty)
    }

    /// No GitHub origin and no repository named: pause, saying how to fix it.
    @Test func missingOrigin() async {
        let world = World()
        world.origin = nil
        world.automations = [Self.loop()]
        let engine = await Self.engine(world)
        await engine.tick()
        let status = await engine.status(of: world.automations[0])
        #expect(status.state == .paused && status.reason?.contains("no GitHub origin") == true)
    }

    /// Activity on an item while this automation's own run for it works (its comments, pushes)
    /// never fires another run for it.
    @Test func ownRunDoesNotRetrigger() async {
        let world = World()
        world.automations = [Self.loop(events: [.issueLabeled, .issueComment], labels: [])]
        let engine = await Self.engine(world)
        await engine.tick()
        world.advance(61)
        var item = Self.labeled(1, at: world.now.addingTimeInterval(-5), association: "OWNER")
        world.items = [item]
        await engine.tick()
        #expect(world.started.count == 1)
        world.advance(61)
        item.events.append(.init(id: "C1", at: world.now.addingTimeInterval(-5),
                                 activity: .comment(author: "owner", association: "OWNER", body: "PR opened", url: nil)))
        world.items = [item]
        await engine.tick()
        #expect(world.started.count == 1)
        // After the run ends, a new comment fires again.
        world.live = [:]
        world.advance(61)
        await engine.tick()
        world.advance(61)
        item.events.append(.init(id: "C2", at: world.now.addingTimeInterval(-5),
                                 activity: .comment(author: "owner", association: "OWNER", body: "one more thing", url: nil)))
        world.items = [item]
        await engine.tick()
        #expect(world.started.count == 2)
    }

    /// A run that can't start is retried once, then recorded as a failed run.
    @Test func startFailures() async {
        let world = World()
        world.automations = [Self.loop()]
        let engine = await Self.engine(world)
        await engine.tick()
        world.advance(61)
        world.items = [Self.labeled(1, at: world.now.addingTimeInterval(-5))]
        world.failStarts = 2
        await engine.tick()
        #expect(world.started.isEmpty && world.failures.isEmpty)
        world.advance(61)
        await engine.tick()
        #expect(world.started.isEmpty && world.failures.count == 1)
        #expect(await engine.status(of: world.automations[0]).pending.isEmpty)
    }

    /// A missed schedule (the Mac slept for hours) runs once, then keeps its rhythm.
    @Test func scheduleCatchesUpOnce() async {
        let world = World()
        world.now = ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z")!
        world.automations = [Automation(id: AutomationID(rawValue: "s"), name: "brief", prompt: "brief me", cwd: "/tmp",
                                        trigger: .schedule(AutomationSchedule(rrule: "FREQ=HOURLY;BYMINUTE=0")))]
        let engine = await Self.engine(world)
        await engine.tick()
        #expect(await engine.status(of: world.automations[0]).nextRunAt == world.now.timeIntervalSince1970 + 3600)
        world.advance(5 * 3600 + 120)
        await engine.tick()
        #expect(world.started.count == 1 && world.started[0][0].kind == nil)
        let next = await engine.status(of: world.automations[0]).nextRunAt
        #expect(next == ISO8601DateFormatter().date(from: "2026-10-30T14:00:00Z")!.timeIntervalSince1970)
    }

    /// A thread destination gets every waiting firing in one message, waits while the thread
    /// works, and pauses when the thread is gone.
    @Test func threadDestination() async {
        let world = World()
        var automation = Self.loop()
        automation.destination = .thread(AgentID(rawValue: "t"))
        world.automations = [automation]
        let engine = await Self.engine(world)
        await engine.tick()
        world.advance(61)
        world.thread = .busy
        world.items = [Self.labeled(1, at: world.now.addingTimeInterval(-9)), Self.labeled(2, at: world.now.addingTimeInterval(-5))]
        await engine.tick()
        #expect(world.started.isEmpty)
        world.thread = .idle
        world.advance(61)
        await engine.tick()
        #expect(world.started.map(\.count) == [2])
        world.thread = .gone
        world.advance(61)
        world.items.append(Self.labeled(3, at: world.now.addingTimeInterval(-5)))
        await engine.tick()
        world.advance(61)
        await engine.tick()
        #expect(await engine.status(of: automation).state == .paused)
    }

    /// Editing the trigger takes a new baseline; Pause all stops every check.
    @Test func editsAndPauseAll() async {
        let world = World()
        world.automations = [Self.loop()]
        let engine = await Self.engine(world)
        await engine.tick()
        world.advance(61)
        world.items = [Self.labeled(1, at: world.now.addingTimeInterval(-5), label: "ready")]
        world.automations = [Self.loop(labels: ["ready"])]
        await engine.tick()
        #expect(world.started.isEmpty)
        await engine.setAllPaused(true)
        let reads = world.reads
        world.advance(3600)
        await engine.tick()
        let paused = await engine.status(of: world.automations[0])
        #expect(world.reads == reads && paused.state == .paused)
    }

    /// Cursors, pending events and limits outlive a restart; catch-up reaches back 24 hours.
    @Test func restartCatchesUpADay() async {
        let world = World()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("triggers-\(UUID().uuidString).json")
        world.automations = [Self.loop()]
        var engine = await Self.engine(world, url: url)
        await engine.tick()
        // The app is closed for two days; one issue was labeled each day.
        world.advance(2 * 24 * 3600)
        world.items = [Self.labeled(1, at: world.now.addingTimeInterval(-30 * 3600)),
                       Self.labeled(2, at: world.now.addingTimeInterval(-2 * 3600))]
        engine = await Self.engine(world, url: url)
        await engine.tick()
        #expect(world.started.flatMap { $0.map { $0.number } } == [2])
    }
}
