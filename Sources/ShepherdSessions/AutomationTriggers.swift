import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Fires triggered automations: it ticks a schedule clock and polls GitHub through the user's
/// `gh`, keeps each automation's pending events, dedupe keys and cursors in
/// `automation-triggers.json`, and starts runs through the host (the app) under each
/// automation's limits. No model is involved until a run starts.
///
/// Bounds (docs/data-flow.md "Automation triggers"): runs at once and per day per automation,
/// a 5-minute minimum schedule gap, 60 s between GitHub checks of a repository, pending events
/// expire after 7 days, dedupe keys after 30, and catch-up after downtime reaches back 24 hours.
/// A lasting error pauses the automation instead of retrying; passing errors back off to 30 min.
public actor AutomationTriggers {
    public static let pollInterval: TimeInterval = 60
    public static let tickInterval: TimeInterval = 15
    public static let catchUpWindow: TimeInterval = 24 * 3600
    public static let pendingLifetime: TimeInterval = 7 * 24 * 3600
    public static let seenLifetime: TimeInterval = 30 * 24 * 3600
    public static let maxBackoff: TimeInterval = 30 * 60
    /// Pending events kept per automation; the oldest go first past it.
    public static let pendingLimit = 100
    /// Times one event's run may fail to start before it is dropped with a failed run.
    public static let startAttempts = 2

    /// What the engine needs from the app. Every closure may be called from any task.
    public struct Host: Sendable {
        /// Every automation, as currently saved.
        public var automations: @Sendable () async -> [Automation]
        /// The event ids (nil for an event-less run) of the automation's runs still going.
        public var liveRuns: @Sendable (AutomationID) async -> [String?]
        /// A `.thread` destination's state.
        public var threadState: @Sendable (AgentID) async -> ThreadState
        /// Start one run. New-thread destinations get one event (or none: Run now); a thread
        /// destination gets every event delivered at once.
        public var start: @Sendable (Automation, [AutomationEvent]) async throws -> Void
        /// Record a run that never started.
        public var recordFailure: @Sendable (AutomationID, AutomationEvent?, String) async -> Void
        public var notify: @Sendable (_ title: String, _ body: String) async -> Void
        /// Status changed (the app redraws; remote clients read it on request).
        public var changed: @Sendable () -> Void
        /// Why runs must wait (a Project paused), nil when they may start. Events keep queueing.
        public var holdReason: @Sendable (Automation) async -> String?

        public init(automations: @escaping @Sendable () async -> [Automation],
                    liveRuns: @escaping @Sendable (AutomationID) async -> [String?],
                    threadState: @escaping @Sendable (AgentID) async -> ThreadState,
                    start: @escaping @Sendable (Automation, [AutomationEvent]) async throws -> Void,
                    recordFailure: @escaping @Sendable (AutomationID, AutomationEvent?, String) async -> Void,
                    notify: @escaping @Sendable (String, String) async -> Void,
                    changed: @escaping @Sendable () -> Void = {},
                    holdReason: @escaping @Sendable (Automation) async -> String? = { _ in nil }) {
            self.holdReason = holdReason
            self.automations = automations
            self.liveRuns = liveRuns
            self.threadState = threadState
            self.start = start
            self.recordFailure = recordFailure
            self.notify = notify
            self.changed = changed
        }
    }

    public enum ThreadState: Sendable { case idle, busy, gone }

    /// Reads GitHub. The default runs `gh`; tests pass a stand-in.
    public struct Source: Sendable {
        public var activity: @Sendable (_ repo: String) async throws -> [GitHubItem]
        /// "owner/name" of a directory's `origin`, nil when it has none on GitHub.
        public var originRepo: @Sendable (_ directory: String) async -> String?

        public init(activity: @escaping @Sendable (String) async throws -> [GitHubItem],
                    originRepo: @escaping @Sendable (String) async -> String?) {
            self.activity = activity
            self.originRepo = originRepo
        }
    }

    /// A GitHub read that failed. `permanent` pauses the automation; anything else backs off.
    public struct SourceError: Error, CustomStringConvertible, Equatable {
        public var description: String
        public var permanent: Bool
        public var retryAfter: TimeInterval?
        public init(_ description: String, permanent: Bool, retryAfter: TimeInterval? = nil) {
            self.description = description
            self.permanent = permanent
            self.retryAfter = retryAfter
        }
    }

    struct Pending: Codable, Hashable {
        var event: AutomationEvent
        var attempts = 0
        var queuedAt: Double
    }

    struct Window: Codable, Hashable {
        var start: Double
        var end: Double?
    }

    struct Record: Codable {
        /// The trigger configuration the cursors below belong to; a change rebaselines.
        var fingerprint = ""
        /// Nothing that happened at or before this ever fires (enable, edit, first sight).
        var baselineAt: Double = 0
        var lastCheckedAt: Double?
        var seen: [String: Double] = [:]
        var pending: [Pending] = []
        var nextRunAt: Double?
        /// Paused by the user ("") or by a lasting error (its reason).
        var pausedReason: String?
        var failures = 0
        var retryAt: Double?
        var retryReason: String?
        var starts: [Double] = []
        var capNotifiedDay: String?
        /// Last head commit per pull request ("owner/name#12").
        var heads: [String: String] = [:]
        /// This automation's own runs per item: activity inside one never fires another run.
        var windows: [String: Window] = [:]
        /// Why runs are waiting (`Host.holdReason`), as of the last tick.
        var heldReason: String?
    }

    struct File: Codable {
        var version = 1
        var allPaused = false
        var records: [String: Record] = [:]
    }

    private let url: URL
    private let source: Source
    private let clock: @Sendable () -> Date
    private var calendar: Calendar
    private var host: Host?
    private var file = File()
    /// Notes to post once the tick's state is saved.
    private var outbox: [(String, String)] = []
    private var loop: Task<Void, Never>?
    private var origins: [String: String?] = [:]
    /// Each repository's last read this tick round, shared by automations watching it.
    private var reads: [String: (at: Date, result: Result<[GitHubItem], SourceError>)] = [:]

    public init(url: URL, source: Source = .gh(), clock: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.url = url
        self.source = source
        self.clock = clock
        self.calendar = calendar
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            self.file = file
        }
    }

    public func install(_ host: Host) {
        self.host = host
    }

    /// Starts ticking (the app, once its workspace is adopted). Tests call `tick()` instead.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Status and controls

    public func status(of automation: Automation) -> AutomationTriggerStatus {
        let record = file.records[automation.id.rawValue] ?? Record()
        let now = clock()
        var status = AutomationTriggerStatus(
            state: .active, pending: record.pending.map(\.event), nextRunAt: record.nextRunAt,
            lastCheckedAt: record.lastCheckedAt, runsToday: runsToday(record, now: now), allPaused: file.allPaused)
        if !automation.enabled {
            status.state = .off
        } else if file.allPaused {
            status.state = .paused
            status.reason = "All triggers are paused."
        } else if let reason = record.pausedReason {
            status.state = .paused
            status.reason = reason.isEmpty ? nil : reason
        } else if automation.projectID != nil, automation.isTriggered, !projectExecution {
            status.state = .paused
            status.reason = "Project triggers start runs through the Project's execution."
        } else if let held = record.heldReason {
            status.state = .paused
            status.reason = held
        } else if let retryAt = record.retryAt, retryAt > now.timeIntervalSince1970 {
            status.state = .retrying
            status.reason = record.retryReason
            status.retryAt = retryAt
        }
        return status
    }

    /// Whether Project-owned automations fire: set once the Project execution adapter is
    /// installed. Until then their triggers are stored but paused.
    private var projectExecution = false

    public func enableProjectExecution(_ enabled: Bool) {
        projectExecution = enabled
    }

    public var allPaused: Bool { file.allPaused }

    public func setAllPaused(_ paused: Bool) {
        guard file.allPaused != paused else { return }
        file.allPaused = paused
        save()
        host?.changed()
    }

    public func pause(_ id: AutomationID) {
        update(id) { $0.pausedReason = "" }
    }

    /// Resume after a pause or a lasting error: checks again on the next tick, and nothing that
    /// happened while paused fires (a new baseline).
    public func resume(_ id: AutomationID) {
        let now = clock().timeIntervalSince1970
        reads = [:]
        update(id) {
            $0.pausedReason = nil
            $0.failures = 0
            $0.retryAt = nil
            $0.retryReason = nil
            $0.lastCheckedAt = nil
            $0.baselineAt = now
        }
    }

    public func dismiss(_ id: AutomationID, eventID: String) {
        update(id) { $0.pending.removeAll { $0.event.id == eventID } }
    }

    /// Start one pending event's run now, past the daily and concurrent caps (the user asked).
    public func runPending(_ automation: Automation, eventID: String) async throws {
        guard let host, var record = file.records[automation.id.rawValue],
              let index = record.pending.firstIndex(where: { $0.event.id == eventID }) else {
            throw SourceError("That event is no longer pending.", permanent: true)
        }
        let pending = record.pending.remove(at: index)
        let now = clock().timeIntervalSince1970
        record.starts.append(now)
        if let key = pending.event.itemKey { record.windows[key] = Window(start: now) }
        file.records[automation.id.rawValue] = record
        save()
        host.changed()
        do {
            try await host.start(automation, [pending.event])
        } catch {
            await host.recordFailure(automation.id, pending.event, "\(error)")
            throw error
        }
    }

    /// The automation was removed: forget its cursors and queue.
    public func forget(_ id: AutomationID) {
        guard file.records.removeValue(forKey: id.rawValue) != nil else { return }
        save()
        host?.changed()
    }

    private func update(_ id: AutomationID, _ change: (inout Record) -> Void) {
        var record = file.records[id.rawValue] ?? Record()
        change(&record)
        file.records[id.rawValue] = record
        save()
        host?.changed()
    }

    // MARK: Ticking

    /// One pass over every triggered automation: rebaseline changed ones, fire due schedules,
    /// check GitHub where due, and start what the limits allow. A tick asked for while one runs
    /// waits for it, then runs.
    public func tick() async {
        let previous = currentTick
        let next = Task { [weak self] in
            await previous?.value
            await self?.runTick()
        }
        currentTick = next
        await next.value
    }

    private var currentTick: Task<Void, Never>?

    private func runTick() async {
        guard let host else { return }
        let before = file
        let automations = await host.automations()
        let now = clock()
        reads = reads.filter { now.timeIntervalSince($0.value.at) < Self.pollInterval }
        let kept = Set(automations.map(\.id.rawValue))
        file.records = file.records.filter { kept.contains($0.key) }
        for automation in automations where automation.isTriggered {
            if automation.projectID != nil && !projectExecution { continue }
            await advance(automation, now: now, host: host)
        }
        if !sameFile(before, file) {
            save()
            host.changed()
        }
        let notes = outbox
        outbox = []
        for note in notes { await host.notify(note.0, note.1) }
    }

    private func sameFile(_ a: File, _ b: File) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    private func advance(_ automation: Automation, now: Date, host: Host) async {
        let id = automation.id.rawValue
        let time = now.timeIntervalSince1970
        var record = file.records[id] ?? Record()
        let fingerprint = Self.fingerprint(automation)
        if record.fingerprint != fingerprint {
            // New, edited or switched back on: only what happens from now on fires.
            record.fingerprint = fingerprint
            record.baselineAt = time
            record.lastCheckedAt = nil
            record.heads = [:]
            record.nextRunAt = nil
            record.failures = 0
            record.retryAt = nil
            record.retryReason = nil
            if automation.enabled, record.pausedReason?.isEmpty == false { record.pausedReason = nil }
        }
        record.seen = record.seen.filter { time - $0.value < Self.seenLifetime }
        record.pending.removeAll { time - $0.queuedAt > Self.pendingLifetime }
        record.starts.removeAll { time - $0 > 2 * 24 * 3600 }
        record.windows = record.windows.filter { $0.value.end.map { time - $0 < Self.seenLifetime } ?? true }
        file.records[id] = record
        guard automation.enabled, !file.allPaused, record.pausedReason == nil else { return }

        switch automation.trigger {
        case .manual:
            return
        case .schedule(let schedule):
            if let next = record.nextRunAt {
                if time >= next {
                    // Missed runs (the Mac slept, the app was closed) collapse into this one.
                    let title = "Scheduled run"
                    record.pending.append(Pending(event: AutomationEvent(id: "schedule:\(Int(next))", title: title, occurredAt: next), queuedAt: time))
                    record.nextRunAt = schedule.next(after: now, calendar: calendar)?.timeIntervalSince1970
                }
            } else {
                record.nextRunAt = schedule.next(after: now, calendar: calendar)?.timeIntervalSince1970
            }
            record.lastCheckedAt = time
        case .github(let triggers):
            if let retryAt = record.retryAt, retryAt > time { break }
            if let last = record.lastCheckedAt, time - last < Self.pollInterval { break }
            file.records[id] = record
            let fetched = await fetch(automation, triggers: triggers, now: now)
            // Pause, Resume or Dismiss may have landed while GitHub answered: build on them.
            record = file.records[id] ?? record
            guard record.pausedReason == nil, !file.allPaused else { return }
            apply(fetched, automation: automation, triggers: triggers, to: &record, now: now)
        }
        file.records[id] = record
        guard file.records[id]?.pausedReason == nil else { return }
        await dispatch(automation, host: host, now: now)
    }

    enum Fetched {
        case items([GitHubItem], origin: String?)
        case lasting(String)
        case passing(SourceError)
    }

    /// Reads every repository the triggers watch (each at most once a minute across automations).
    private func fetch(_ automation: Automation, triggers: [GitHubTrigger], now: Date) async -> Fetched {
        var origin: String?
        if triggers.contains(where: { $0.repo == nil }) {
            let cwd = (automation.cwd as NSString).expandingTildeInPath
            if let cached = origins[cwd] { origin = cached } else {
                origin = await source.originRepo(cwd)
                origins[cwd] = origin
            }
            guard origin != nil else {
                origins[cwd] = nil
                return .lasting("\(automation.cwd) has no GitHub origin remote. Name the repository on the trigger.")
            }
        }
        var repos: [String] = []
        for trigger in triggers {
            if let repo = (trigger.repo ?? origin)?.lowercased(), !repos.contains(repo) { repos.append(repo) }
        }
        var items: [GitHubItem] = []
        for repo in repos {
            let result: Result<[GitHubItem], SourceError>
            if let cached = reads[repo] { result = cached.result } else {
                do { result = .success(try await source.activity(repo)) } catch let error as SourceError {
                    result = .failure(error)
                } catch {
                    result = .failure(SourceError("\(error)", permanent: false))
                }
                reads[repo] = (now, result)
            }
            switch result {
            case .success(let read): items += read
            case .failure(let error): return error.permanent ? .lasting(error.description) : .passing(error)
            }
        }
        return .items(items, origin: origin)
    }

    private func apply(_ fetched: Fetched, automation: Automation, triggers: [GitHubTrigger], to record: inout Record, now: Date) {
        let time = now.timeIntervalSince1970
        let items: [GitHubItem], origin: String?
        switch fetched {
        case .lasting(let reason):
            return pauseForError(&record, reason, automation: automation)
        case .passing(let error):
            record.failures += 1
            let backoff = min(Self.maxBackoff, Self.pollInterval * pow(2, Double(record.failures - 1)))
            record.retryAt = time + max(backoff, error.retryAfter ?? 0)
            record.retryReason = error.description
            return
        case .items(let read, let repo):
            items = read
            origin = repo
        }
        let since = max(record.baselineAt, time - Self.catchUpWindow)
        let found = GitHubActivity.events(in: items, triggers: triggers, repoOf: { $0.repo ?? origin }, gate: automation.authorGate,
                                          since: Date(timeIntervalSince1970: since), now: now, heads: record.heads)
        for item in items where item.isPullRequest { if let head = item.headOID { record.heads[item.key] = head } }
        if record.heads.count > 400 { record.heads = Dictionary(uniqueKeysWithValues: record.heads.sorted { $0.key < $1.key }.suffix(400).map { ($0.key, $0.value) }) }
        for event in found where record.seen[event.id] == nil {
            record.seen[event.id] = time
            if let key = event.itemKey, let window = record.windows[key],
               event.occurredAt >= window.start, event.occurredAt <= (window.end ?? .infinity) { continue }
            record.pending.append(Pending(event: event, queuedAt: time))
        }
        if record.pending.count > Self.pendingLimit { record.pending.removeFirst(record.pending.count - Self.pendingLimit) }
        record.failures = 0
        record.retryAt = nil
        record.retryReason = nil
        record.lastCheckedAt = time
    }

    private func pauseForError(_ record: inout Record, _ reason: String, automation: Automation) {
        record.pausedReason = reason
        outbox.append(("\(automation.name) paused", reason))
    }

    private func dispatch(_ automation: Automation, host: Host, now: Date) async {
        let id = automation.id.rawValue
        let time = now.timeIntervalSince1970
        let live = await host.liveRuns(automation.id)
        let held = await host.holdReason(automation)
        var threadState: ThreadState = .idle
        if case .thread(let agentID) = automation.destination { threadState = await host.threadState(agentID) }
        guard var record = file.records[id], record.pausedReason == nil else { return }
        record.heldReason = held
        guard held == nil else {
            file.records[id] = record
            return
        }
        let liveItems = Set(live.compactMap { $0.flatMap(AutomationEvent.itemKey(ofEventID:)) })
        for (key, window) in record.windows where window.end == nil && !liveItems.contains(key) {
            record.windows[key]?.end = time
        }
        // Activity on an item while this automation's run for it works never fires another.
        record.pending.removeAll { pending in
            guard let key = pending.event.itemKey, liveItems.contains(key), let window = record.windows[key] else { return false }
            return pending.event.occurredAt >= window.start
        }
        file.records[id] = record
        guard !record.pending.isEmpty else { return }
        var batch: [[Pending]] = []
        switch automation.destination {
        case .newThread:
            var running = live.count
            var today = runsToday(record, now: now)
            var busy = liveItems
            var waiting: [Pending] = []
            for next in record.pending {
                // One run per item at a time: a second event for it waits for the first run.
                let key = next.event.itemKey
                if running < automation.limits.maxConcurrent, today < automation.limits.maxPerDay,
                   key.map({ !busy.contains($0) }) ?? true {
                    batch.append([next])
                    running += 1
                    today += 1
                    if let key { busy.insert(key) }
                } else {
                    waiting.append(next)
                }
            }
            record.pending = waiting
        case .thread:
            switch threadState {
            case .gone:
                pauseForError(&record, "Its thread was deleted. Choose a new destination, then resume.", automation: automation)
                file.records[id] = record
                return
            case .busy:
                break
            case .idle:
                let room = automation.limits.maxPerDay - runsToday(record, now: now)
                if room > 0 {
                    // Firings that piled up go as one message.
                    batch.append(Array(record.pending.prefix(min(room, 20))))
                    record.pending.removeFirst(batch[0].count)
                }
            }
        }
        if !record.pending.isEmpty, runsToday(record, now: now) + batch.count >= automation.limits.maxPerDay {
            let day = Self.dayKey(now, calendar: calendar)
            if record.capNotifiedDay != day {
                record.capNotifiedDay = day
                let count = record.pending.count
                outbox.append(("\(automation.name) hit its daily limit", "\(count) event\(count == 1 ? "" : "s") waiting. They run tomorrow, or run one now from Automations."))
            }
        }
        for group in batch {
            record.starts.append(time)
            for pending in group { if let key = pending.event.itemKey { record.windows[key] = Window(start: time) } }
        }
        file.records[id] = record
        for group in batch {
            do {
                try await host.start(automation, group.map(\.event))
            } catch {
                let message = "\(error)"
                var current = file.records[id] ?? record
                for var pending in group {
                    pending.attempts += 1
                    if let key = pending.event.itemKey { current.windows[key] = nil }
                    if pending.attempts < Self.startAttempts {
                        current.pending.insert(pending, at: 0)
                    } else {
                        await host.recordFailure(automation.id, pending.event, message)
                    }
                }
                file.records[id] = current
            }
        }
    }

    private func runsToday(_ record: Record, now: Date) -> Int {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970
        return record.starts.filter { $0 >= start }.count
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// What a run's cursors depend on: trigger, gate, directory (its origin), and the switch.
    static func fingerprint(_ automation: Automation) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let trigger = (try? encoder.encode(automation.trigger)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [trigger, automation.authorGate.rawValue, automation.cwd, automation.enabled ? "on" : "off"].joined(separator: "|")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            ShepherdLog.warning("automation triggers not saved: \(error)")
        }
    }
}

extension AutomationEvent {
    /// "owner/name#12" for a GitHub event, nil for a schedule tick.
    public var itemKey: String? { Self.itemKey(ofEventID: id) }

    public static func itemKey(ofEventID id: String) -> String? {
        guard !id.hasPrefix("schedule:"), let colon = id.firstIndex(of: ":") else { return nil }
        let key = String(id[..<colon])
        return key.contains("#") ? key : nil
    }
}

extension AutomationTriggers.Source {
    /// The user's `gh` (resolved by their login shell, or `ghPath`) and `git`.
    public static func gh(ghPath: String? = nil) -> Self {
        Self(
            activity: { repo in
                let script = ghPath.map { "'\($0)' api graphql --input -" } ?? "gh api graphql --input -"
                var environment = ProcessInfo.processInfo.environment
                environment["GH_PROMPT_DISABLED"] = "1"
                environment["NO_COLOR"] = "1"
                let result: BoundedCommand.Result
                do {
                    result = try await Task.detached {
                        try BoundedCommand.run(["/bin/zsh", "-l", "-c", script], environment: environment,
                                               input: GitHubActivity.request(repo: repo), timeout: 60, outputLimit: 8 << 20)
                    }.value
                } catch {
                    throw AutomationTriggers.SourceError("gh didn't answer: \(error)", permanent: false)
                }
                let errors = String(decoding: result.errors, as: UTF8.self)
                if result.status == 127 || errors.contains("command not found") {
                    throw AutomationTriggers.SourceError("gh isn't installed. Install the GitHub CLI, run gh auth login, then resume.", permanent: true)
                }
                if errors.contains("gh auth login") || errors.contains("HTTP 401") {
                    throw AutomationTriggers.SourceError("gh isn't signed in. Run gh auth login, then resume.", permanent: true)
                }
                if result.status != 0, result.output.isEmpty {
                    let rateLimited = errors.localizedCaseInsensitiveContains("rate limit")
                    throw AutomationTriggers.SourceError(
                        rateLimited ? "GitHub rate limit reached." : "GitHub check failed: \(errors.prefix(200))",
                        permanent: false, retryAfter: rateLimited ? 15 * 60 : nil)
                }
                do {
                    return try GitHubActivity.parse(result.output, repo: repo)
                } catch let error as GitHubActivity.ResponseError {
                    throw AutomationTriggers.SourceError(error.description, permanent: error.permanent)
                }
            },
            originRepo: { directory in
                let result = try? await Task.detached {
                    try BoundedCommand.run(["/usr/bin/git", "-C", directory, "remote", "get-url", "origin"], timeout: 10)
                }.value
                guard let result, result.status == 0 else { return nil }
                return GitHubActivity.repo(fromRemote: String(decoding: result.output, as: UTF8.self))
            }
        )
    }
}
