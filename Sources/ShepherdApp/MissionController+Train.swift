import Foundation
import ShepherdCore
import ShepherdSessions

/// MXTrain: merges a published mission's pull requests one at a time through the owner's gh, in the order
/// and under the rules the owner started it with. Each step is a bounded command; the loop never survives a
/// restart (the server pauses a running train), and Pause or Stop ends it between commands.
extension MissionController {
    /// How often the train looks at CI, the merge window and a soak. Tests shorten it.
    static var trainPoll: Duration = .seconds(30)
    /// The longest the train waits for one pull request's CI before pausing.
    static var trainCIWait: Double = 2 * 60 * 60

    func startTrain(id: MissionID, revision: UInt64, order: [SpaceID], rules: MissionTrain.Rules) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, run.phase == .done, run.train == nil,
              let plan = mission.draft.plan, run.publicationApproval != nil else {
            throw MissionError("stale_mission", "Only a published mission starts a merge train, once.")
        }
        let published = Set(run.checkouts.filter { $0.prURL != nil }.map(\.spaceID))
        guard !published.isEmpty, Set(order) == published, order.count == published.count else {
            throw MissionError("mission_train_order", "The train takes every published pull request exactly once.")
        }
        guard MissionTrainOrder.allows(order, plan: plan) else {
            throw MissionError("mission_train_order", "That order merges a repository before one whose output it takes. Keep producers ahead of their consumers.")
        }
        try Self.check(rules, lanes: order, plan: plan)
        var train = MissionTrain(order: order, rules: rules, startedAt: Self.now)
        train.record(.init(at: Self.now, subject: "train", text: "started · \(order.count) PRs", by: "you"))
        run.train = train
        _ = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        driveTrain(id)
    }

    func pauseTrain(id: MissionID, revision: UInt64) async throws {
        guard try record(id).run?.train?.status == .running else { throw MissionError("stale_mission", "The train isn't running.") }
        trainJobs[id]?.cancel(); trainJobs[id] = nil
        try await updateTrain(id) { $0.pause("Paused. The train continues from this step when you resume it.") }
    }

    func resumeTrain(id: MissionID, revision: UInt64) async throws {
        let mission = try record(id)
        guard mission.revision == revision, mission.run?.train?.status == .paused, trainJobs[id] == nil else {
            throw MissionError("stale_mission", "The train changed. Look at it again before resuming.")
        }
        try await updateTrain(id) { $0.status = .running; $0.notice = nil }
        driveTrain(id)
    }

    func skipSoak(id: MissionID, revision: UInt64) async throws {
        guard let train = try record(id).run?.train, train.status == .running,
              let car = train.current, train.cars[car].steps.contains(where: { $0.kind == .soak && $0.status == .running }) else {
            throw MissionError("stale_mission", "No soak is running.")
        }
        try await updateTrain(id) { $0.skipSoak = true }
    }

    /// New rules (and, for cars that haven't started, a new order) while the train is paused.
    func changeTrain(id: MissionID, revision: UInt64, order: [SpaceID], rules: MissionTrain.Rules) async throws {
        let mission = try record(id)
        guard mission.revision == revision, let plan = mission.draft.plan, let train = mission.run?.train, train.status == .paused else {
            throw MissionError("stale_mission", "Pause the train before changing it.")
        }
        let started = train.cars.filter { $0.steps.contains { $0.status != .pending } }.map(\.spaceID)
        guard Set(order) == Set(train.cars.map(\.spaceID)), order.count == train.cars.count, Array(order.prefix(started.count)) == started,
              MissionTrainOrder.allows(order, plan: plan) else {
            throw MissionError("mission_train_order", "Only cars that haven't started can move, and producers stay ahead of their consumers.")
        }
        try Self.check(rules, lanes: order, plan: plan)
        try await updateTrain(id) { value in
            let cars = Dictionary(uniqueKeysWithValues: value.cars.map { ($0.spaceID, $0) })
            value.cars = order.map { lane in
                let car = cars[lane]!
                return started.contains(lane) ? car : MissionTrain.Car(spaceID: lane, steps: MissionTrain.steps(rules))
            }
            value.rules = rules
        }
    }

    private static func check(_ rules: MissionTrain.Rules, lanes: [SpaceID], plan: MissionPlan) throws {
        if rules.between == .stagingSoak, let missing = lanes.first(where: { rules.staging[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }) {
            let name = plan.lanes.first { $0.spaceID == missing }?.name ?? "a repository"
            throw MissionError("mission_train_staging", "Give \(name) a staging deploy command, or choose a soak without staging.")
        }
    }

    /// Reads the mission now and saves `change` to its train against that revision, again if another write landed first.
    @discardableResult
    func updateTrain(_ id: MissionID, _ change: (inout MissionTrain) -> Void) async throws -> MissionTrain {
        for _ in 0..<5 {
            let mission = try record(id)
            guard var run = mission.run, var train = run.train else { throw MissionError("mission_train", "This mission has no merge train.") }
            change(&train)
            run.train = train
            do { _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run); return train }
            catch let error as MissionError where error.code == "stale_mission" { continue }
        }
        throw MissionError("stale_mission", "The mission kept changing; the train step wasn't saved.")
    }

    func driveTrain(_ id: MissionID) {
        trainJobs[id]?.cancel()
        trainJobs[id] = Task {
            do { try await self.runTrain(id) }
            catch is CancellationError {}
            catch {
                let message = Self.safeText(String(describing: error))
                _ = try? await self.updateTrain(id) { train in if train.status == .running { train.pause(message) } }
            }
            self.trainJobs[id] = nil
        }
    }

    private func runTrain(_ id: MissionID) async throws {
        while true {
            try Task.checkCancellation()
            let mission = try record(id)
            guard let run = mission.run, let train = run.train, train.status == .running else { return }
            guard let car = train.current else {
                try await updateTrain(id) { $0.status = .done; $0.record(.init(at: Self.now, subject: "train", text: "all \($0.cars.count) merged", by: "train")) }
                return
            }
            let lane = train.cars[car].spaceID
            guard let checkout = run.checkouts.first(where: { $0.spaceID == lane }), let url = checkout.prURL,
                  let step = train.cars[car].steps.firstIndex(where: { ![.done, .fixed, .skipped].contains($0.status) }) else {
                throw MissionError("mission_train", "A train car lost its pull request. Nothing else was merged.")
            }
            let name = mission.lane(lane)?.name ?? checkout.repo
            let kind = train.cars[car].steps[step].kind
            if kind == .update, train.cars[car].steps[step].status == .pending, !train.rules.open(at: Date()) {
                if train.notice == nil { try await updateTrain(id) { $0.notice = "Waiting for the merge window (weekdays 9–4)." } }
                try await Task.sleep(for: Self.trainPoll)
                continue
            }
            try await updateTrain(id) { value in
                value.notice = nil
                value.cars[car].steps[step].status = .running
                value.cars[car].steps[step].at = Self.now
            }
            let outcome = try await runStep(kind, name: name, url: url, checkout: checkout, rules: train.rules, id: id, car: car, step: step)
            try await updateTrain(id) { value in
                value.cars[car].steps[step].status = outcome.status
                value.cars[car].steps[step].at = Self.now
                if let note = outcome.note { value.cars[car].steps[step].note = Self.safeText(note, bytes: 2_048) }
                for entry in outcome.log { value.record(entry) }
                if kind == .soak { value.skipSoak = nil }
                if outcome.status == .failed { value.pause(outcome.pause ?? "\(name): \(kind.rawValue) failed. Paused for you.") }
            }
            if outcome.status == .failed { return }
        }
    }

    private struct Outcome {
        var status: MissionTrain.StepStatus
        var note: String?
        var log: [MissionTrain.Entry] = []
        var pause: String?
    }

    private func runStep(_ kind: MissionTrain.StepKind, name: String, url: String, checkout: MissionCheckout, rules: MissionTrain.Rules,
                         id: MissionID, car: Int, step: Int) async throws -> Outcome {
        let pr = shellQuoted(url), cwd = checkout.path
        let number = MissionFormat.pullNumber(url) ?? name
        switch kind {
        case .update:
            if try await merged(url, cwd: cwd) { return Outcome(status: .skipped, note: "already merged") }
            let update = await Self.command("gh pr update-branch \(pr)", cwd: cwd)
            if update.status == 0 { return Outcome(status: .done, log: [.init(at: Self.now, subject: name, text: "updated from \(checkout.base)", by: "train")]) }
            let conflict = (update.stderr + update.stdout).localizedCaseInsensitiveContains("conflict")
            guard conflict else { return Outcome(status: .failed, note: update.stderr, pause: "\(name) couldn't update from \(checkout.base): \(Self.safeText(update.stderr, bytes: 400))") }
            var log = [MissionTrain.Entry(at: Self.now, subject: number, text: "conflict with \(checkout.base)", by: "train")]
            guard rules.lockfiles == .fix else {
                return Outcome(status: .failed, note: "conflict with \(checkout.base)", log: log, pause: "\(name) conflicts with \(checkout.base). Lockfile conflicts pause on your rules.")
            }
            switch await fixLockfiles(checkout) {
            case .fixed(let files):
                log.append(.init(at: Self.now, subject: "rebase-fix", text: "\(files.joined(separator: ", ")) regenerated", by: "auto · rule"))
                return Outcome(status: .fixed, note: "\(files.joined(separator: ", ")) regenerated", log: log)
            case .code(let files):
                return Outcome(status: .failed, note: "code conflict: \(files.joined(separator: ", "))", log: log,
                               pause: "\(name) has a code conflict with \(checkout.base) in \(files.joined(separator: ", ")). Code conflicts pause and ask.")
            case .failed(let reason):
                return Outcome(status: .failed, note: reason, log: log, pause: "\(name): the lockfile fix failed. \(reason)")
            }
        case .ci:
            let deadline = Self.now + Self.trainCIWait
            while true {
                let checks = await Self.command("gh pr checks \(pr) --json bucket --jq '[.[].bucket] | join(\",\")'", cwd: cwd)
                let buckets = checks.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
                if checks.stdout.isEmpty && (checks.stderr + checks.stdout).localizedCaseInsensitiveContains("no checks") {
                    return Outcome(status: .done, note: "no checks", log: [.init(at: Self.now, subject: name, text: "no CI checks", by: "train")])
                }
                if buckets.contains("fail") || buckets.contains("cancel") {
                    return Outcome(status: .failed, note: "CI failed", log: [.init(at: Self.now, subject: number, text: "CI red", by: "train")],
                                   pause: "\(name)'s CI failed on \(number). Fix it, then resume the train.")
                }
                if !buckets.isEmpty, buckets.allSatisfy({ $0 == "pass" || $0 == "skipping" }) {
                    return Outcome(status: .done, log: [.init(at: Self.now, subject: name, text: "CI green", by: "train")])
                }
                guard Self.now < deadline else { return Outcome(status: .failed, note: "CI still running", pause: "\(name)'s CI didn't finish in time. Resume to keep waiting.") }
                try await Task.sleep(for: Self.trainPoll)
            }
        case .merge:
            if try await merged(url, cwd: cwd) { return Outcome(status: .done, note: "merged") }
            let merge = await Self.command("gh pr merge \(pr) --merge", cwd: cwd)
            guard merge.status == 0 else { return Outcome(status: .failed, note: merge.stderr, pause: "GitHub refused to merge \(number): \(Self.safeText(merge.stderr, bytes: 400))") }
            return Outcome(status: .done, log: [.init(at: Self.now, subject: number, text: "merged", by: "train")])
        case .staging:
            let command = rules.staging[checkout.spaceID] ?? ""
            let deploy = await Self.command(command, cwd: cwd, timeout: 30 * 60)
            let tail = Self.tail(deploy.stdout + deploy.stderr)
            guard deploy.status == 0 else { return Outcome(status: .failed, note: tail, pause: "\(name)'s staging deploy exited \(deploy.status). Paused for you.") }
            return Outcome(status: .done, note: tail, log: [.init(at: Self.now, subject: name, text: "deployed to staging", by: "train")])
        case .soak:
            let end = Self.now + Double(rules.soakMinutes) * 60
            while Self.now < end, try record(id).run?.train?.skipSoak != true { try await Task.sleep(for: Self.trainPoll) }
            let skipped = try record(id).run?.train?.skipSoak == true
            var note: String?
            if let health = rules.health[checkout.spaceID], !health.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = await Self.command(health, cwd: cwd, timeout: 5 * 60)
                note = Self.tail(result.stdout + result.stderr)
                if result.status != 0 { return await redAfterMerge(name: name, number: number, pr: pr, cwd: cwd, rules: rules, note: note) }
            }
            // CI on the base branch after this merge: a failure is the "red CI after merge" rule's.
            let sha = await Self.command("gh pr view \(pr) --json mergeCommit --jq .mergeCommit.oid", cwd: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty {
                let runs = await Self.command("gh run list --commit \(shellQuoted(sha)) --json conclusion --jq '[.[].conclusion] | join(\",\")'", cwd: cwd)
                if runs.stdout.contains("failure") { return await redAfterMerge(name: name, number: number, pr: pr, cwd: cwd, rules: rules, note: note) }
            }
            return Outcome(status: skipped ? .skipped : .done, note: note,
                           log: [.init(at: Self.now, subject: name, text: skipped ? "soak skipped" : "healthy on \(rules.between == .stagingSoak ? "staging" : checkout.base)", by: skipped ? "you" : "soak")])
        }
    }

    private func redAfterMerge(name: String, number: String, pr: String, cwd: String, rules: MissionTrain.Rules, note: String?) async -> Outcome {
        var log = [MissionTrain.Entry(at: Self.now, subject: name, text: "red after merge", by: "soak")]
        if rules.redCI == .revertPause {
            let revert = await Self.command("gh pr revert \(pr)", cwd: cwd)
            log.append(.init(at: Self.now, subject: number, text: revert.status == 0 ? "revert PR opened" : "revert failed", by: "auto · rule"))
        }
        return Outcome(status: .failed, note: note, log: log,
                       pause: "\(name) went red after \(number) merged.\(rules.redCI == .revertPause ? " The train opened a revert pull request for you to merge." : "") Paused for you.")
    }

    private func merged(_ url: String, cwd: String) async throws -> Bool {
        let view = await Self.command("gh pr view \(shellQuoted(url)) --json state --jq .state", cwd: cwd)
        return view.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "MERGED"
    }

    private static func tail(_ text: String) -> String {
        safeText(text.split(separator: "\n").suffix(6).joined(separator: "\n"), bytes: 2_048)
    }

    enum LockfileFix: Equatable { case fixed([String]), code([String]), failed(String) }

    /// The lockfiles a conflict may regenerate, and how. Anything else is a code conflict.
    static let lockfiles: [String: String] = [
        "go.sum": "go mod tidy",
        "package-lock.json": "npm install --package-lock-only --ignore-scripts",
        "pnpm-lock.yaml": "pnpm install --lockfile-only --ignore-scripts",
        "yarn.lock": "yarn install --mode update-lockfile",
        "Cargo.lock": "cargo metadata --format-version 1 >/dev/null",
        "Package.resolved": "swift package resolve",
    ]

    /// Merges the base into the mission branch in its own worktree; when only lockfiles conflict, takes the base's
    /// and regenerates each, commits the merge and pushes it (a fast-forward of the PR branch, never forced).
    func fixLockfiles(_ checkout: MissionCheckout) async -> LockfileFix {
        let cwd = checkout.path, base = shellQuoted("origin/" + checkout.base)
        let fetch = await Self.command("git fetch origin \(shellQuoted(checkout.base)) \(shellQuoted(checkout.branch))", cwd: cwd)
        guard fetch.status == 0 else { return .failed(Self.safeText(fetch.stderr, bytes: 400)) }
        _ = await Self.command("git merge --ff-only \(shellQuoted("origin/" + checkout.branch))", cwd: cwd)
        let merge = await Self.command("git -c user.name=Shepherd -c user.email=shepherd@localhost merge --no-edit \(base)", cwd: cwd)
        if merge.status == 0 { return await push(checkout, files: []) }
        let conflicted = await Self.command("git diff --name-only --diff-filter=U", cwd: cwd).stdout.split(separator: "\n").map(String.init)
        let code = conflicted.filter { Self.lockfiles[($0 as NSString).lastPathComponent] == nil }
        guard !conflicted.isEmpty, code.isEmpty else {
            _ = await Self.command("git merge --abort", cwd: cwd)
            return .code(code.isEmpty ? ["unknown files"] : code)
        }
        for file in conflicted {
            let folder = ((cwd as NSString).appendingPathComponent(file) as NSString).deletingLastPathComponent
            let regenerate = Self.lockfiles[(file as NSString).lastPathComponent]!
            let take = await Self.command("git checkout --theirs -- \(shellQuoted(file))", cwd: cwd)
            let run = await Self.command(regenerate, cwd: folder, timeout: 10 * 60)
            guard take.status == 0, run.status == 0, await Self.command("git add -- \(shellQuoted(file))", cwd: cwd).status == 0 else {
                _ = await Self.command("git merge --abort", cwd: cwd)
                return .failed("\(regenerate) failed: \(Self.safeText(run.stderr, bytes: 400))")
            }
        }
        let commit = await Self.command("git -c user.name=Shepherd -c user.email=shepherd@localhost commit --no-edit", cwd: cwd)
        guard commit.status == 0 else { return .failed(Self.safeText(commit.stderr, bytes: 400)) }
        return await push(checkout, files: conflicted.map { ($0 as NSString).lastPathComponent })
    }

    private func push(_ checkout: MissionCheckout, files: [String]) async -> LockfileFix {
        let push = await Self.command("git push origin \(shellQuoted("HEAD:refs/heads/" + checkout.branch))", cwd: checkout.path)
        return push.status == 0 ? .fixed(files) : .failed(Self.safeText(push.stderr, bytes: 400))
    }
}
