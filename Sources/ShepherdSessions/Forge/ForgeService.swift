import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One gh or git command: `arguments[0]` is "gh" or "git", the rest its argument vector. Never a
/// shell line; untrusted text (a body) only ever travels as `input`.
public struct ForgeCommand: Hashable, Sendable {
    public var arguments: [String]
    public var input: Data?

    public init(_ arguments: [String], input: Data? = nil) {
        self.arguments = arguments
        self.input = input
    }
}

/// What a command printed and how it exited. Status 127: the tool isn't there; -2: it timed out.
public struct ForgeOutput: Sendable {
    public var output: Data
    public var errors: String
    public var status: Int32

    public init(output: Data = Data(), errors: String = "", status: Int32 = 0) {
        self.output = output
        self.errors = errors
        self.status = status
    }

    public static func json(_ text: String) -> ForgeOutput { ForgeOutput(output: Data(text.utf8)) }
}

/// What the host knows of its own threads and automations, snapshotted on the server queue so the
/// service never touches server state.
public struct ForgeContext: Sendable {
    public struct Agent: Sendable {
        public var id: AgentID
        public var title: String
        public var running: Bool
        public var branch: String?
        public var worktreePath: String?
        /// Its checkout.
        public var directory: String
        public var automationName: String?
        /// "owner/name#12" of the event that started its automation run.
        public var automationItem: String?

        public init(id: AgentID, title: String, running: Bool, branch: String?, worktreePath: String?, directory: String,
                    automationName: String? = nil, automationItem: String? = nil) {
            self.id = id
            self.title = title
            self.running = running
            self.branch = branch
            self.worktreePath = worktreePath
            self.directory = directory
            self.automationName = automationName
            self.automationItem = automationItem
        }

        var link: ForgeThreadLink {
            ForgeThreadLink(agentID: id, title: title, running: running, branch: branch, worktreePath: worktreePath,
                            automationName: automationName)
        }
    }

    /// A GitHub trigger's labels: issues carrying one show under From automations.
    public struct Watch: Sendable {
        public var automationName: String
        /// The automation's folder, whose `origin` is the repository when `repo` is nil.
        public var directory: String
        public var repo: String?
        public var labels: [String]

        public init(automationName: String, directory: String, repo: String?, labels: [String]) {
            self.automationName = automationName
            self.directory = directory
            self.repo = repo
            self.labels = labels
        }
    }

    public var agents: [Agent]
    /// Spaces' and agents' folders: the repository picker's candidates.
    public var directories: [String]
    public var watches: [Watch]

    public init(agents: [Agent] = [], directories: [String] = [], watches: [Watch] = []) {
        self.agents = agents
        self.directories = directories
        self.watches = watches
    }
}

/// GitHub issues and pull requests through the user's gh (docs/rules.md, Only these paths mutate
/// repositories). Every request runs on demand, never on a timer; reads are reused for
/// `ttl`; a change forgets them. Nothing throws: failures come back as `ForgeError`.
public final class ForgeService: @unchecked Sendable {
    public typealias Runner = @Sendable (ForgeCommand) async -> ForgeOutput

    /// How long a read is reused.
    public static let ttl: TimeInterval = 60
    /// The longest any one command may take.
    public static let timeout: TimeInterval = 15

    private let runner: Runner
    private let pinsURL: URL
    private let now: @Sendable () -> Date
    private let cache = ChangesLocked<[ForgeCommand: (at: Date, output: ForgeOutput)]>([:])
    private let pinsLock = NSLock()
    private let lastNeedsYou = ChangesLocked(0)

    public init(pinsURL: URL, runner: @escaping Runner = ForgeService.gh, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.pinsURL = pinsURL
        self.now = now
    }

    // MARK: Running commands

    /// The user's gh (found by `ChangesService.ghPath`) and /usr/bin/git, bounded, never prompting,
    /// run from "/" so no checkout of the user's is touched (a merge's `--delete-branch` then
    /// deletes only the remote branch).
    public static let gh: Runner = { command in
        guard let tool = command.arguments.first else { return ForgeOutput(status: 127) }
        let executable: String? = switch tool {
        case "gh": ChangesService.ghPath()
        case "git": "/usr/bin/git"
        default: nil
        }
        guard let executable else { return ForgeOutput(errors: "\(tool): command not found", status: 127) }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let argv = [executable] + command.arguments.dropFirst()
        let input = command.input
        return await Task.detached {
            do {
                let result = try BoundedCommand.run(argv, directory: URL(fileURLWithPath: "/", isDirectory: true), environment: environment,
                                                    input: input, timeout: ForgeService.timeout, outputLimit: 32 << 20)
                return ForgeOutput(output: result.output, errors: String(decoding: result.errors.prefix(8192), as: UTF8.self),
                                   status: result.status)
            } catch BoundedCommand.Failure.timedOut {
                return ForgeOutput(errors: "timed out", status: -2)
            } catch {
                return ForgeOutput(errors: String(describing: error), status: -1)
            }
        }.value
    }

    /// A read, reused for `ttl`.
    private func read(_ arguments: [String]) async -> Result<Data, ForgeError> {
        let command = ForgeCommand(arguments)
        let at = now()
        if let hit = cache.withValue({ $0[command] }), at.timeIntervalSince(hit.at) < Self.ttl { return Self.checked(hit.output) }
        let output = await runner(command)
        let result = Self.checked(output)
        if case .success = result { cache.withValue { $0[command] = (at, output) } }
        return result
    }

    /// A change: never reused, and it forgets every read.
    private func change(_ arguments: [String], input: Data? = nil) async -> Result<RemoteForgeResult, ForgeError> {
        await changed(arguments, input: input).map { _ in .ok }
    }

    /// A change's output (`gh issue create` prints the new issue's link).
    private func changed(_ arguments: [String], input: Data? = nil) async -> Result<Data, ForgeError> {
        let output = await runner(ForgeCommand(arguments, input: input))
        cache.withValue { $0.removeAll() }
        return Self.checked(output)
    }

    /// gh's exit as data or a `ForgeError` in words.
    static func checked(_ output: ForgeOutput) -> Result<Data, ForgeError> {
        if output.status == 0 { return .success(output.output) }
        let errors = output.errors
        let lower = errors.lowercased()
        if output.status == 127 || lower.contains("command not found") { return .failure(.ghMissing) }
        if output.status == -2 { return .failure(ForgeError(.timedOut, "GitHub didn't answer within \(Int(timeout)) seconds.")) }
        if lower.contains("gh auth login") || lower.contains("http 401") || lower.contains("not logged in") {
            return .failure(.signedOut)
        }
        if lower.contains("rate limit") { return .failure(ForgeError(.rateLimited, "GitHub's rate limit was reached. Try again in a few minutes.")) }
        if lower.contains("could not resolve to") || lower.contains("http 404") || lower.contains("not found") {
            return .failure(ForgeError(.notFound, "GitHub has no such repository, pull request or issue, or you can't see it."))
        }
        let line = errors.split(separator: "\n").first.map { String($0.prefix(200)) } ?? ""
        return .failure(ForgeError(.failed, line.isEmpty ? "gh failed (exit \(output.status))." : "gh: \(line)"))
    }

    // MARK: Answering

    /// Answers one request. Never throws; gh's failures come back in words.
    public func answer(_ request: RemoteForgeRequest, context: ForgeContext) async -> Result<RemoteForgeResult, ForgeError> {
        if let problem = Self.invalid(request) { return .failure(ForgeError(.invalid, problem)) }
        switch request {
        case .repos:
            return .success(.repos(await repos(context.directories)))
        case .list(let kind, let repo, let sections):
            return await list(kind: kind, repo: repo, sections: sections ?? ForgeSectionID.defaults(for: kind), context: context).map { .list($0) }
        case .search(let kind, let repo, let query):
            return await search(kind: kind, repo: repo, query: query, context: context).map { .list($0) }
        case .pullRequest(let ref):
            return await pullRequest(ref, context: context).map { .pullRequest($0) }
        case .pullRequestFiles(let ref):
            return await read(["gh", "pr", "diff", String(ref.number), "--repo=\(ref.repo)", "--color=never"])
                .map { .files(ForgeParse.files($0, ref: ref)) }
        case .issue(let ref):
            return await issue(ref, context: context).map { .issue($0) }
        case .checkLog(let repo, let jobID):
            return await read(["gh", "run", "view", "--repo=\(repo)", "--job=\(jobID)", "--log-failed"]).map { .checkLog(ForgeParse.logTail($0)) }
        case .comment(let ref, let body):
            return await change(["gh", ref.kind == .pullRequest ? "pr" : "issue", "comment", String(ref.number), "--repo=\(ref.repo)",
                                 "--body-file", "-"], input: Data(body.utf8))
        case .review(let ref, let verdict, let body):
            let flag = switch verdict { case .approve: "--approve"; case .requestChanges: "--request-changes"; case .comment: "--comment" }
            var arguments = ["gh", "pr", "review", String(ref.number), "--repo=\(ref.repo)", flag]
            if !body.isEmpty { arguments += ["--body-file", "-"] }
            return await change(arguments, input: body.isEmpty ? nil : Data(body.utf8))
        case .merge(let ref, let method, let whenReady, let deleteBranch):
            var arguments = ["gh", "pr", "merge", String(ref.number), "--repo=\(ref.repo)", "--\(method.rawValue)"]
            if whenReady { arguments.append("--auto") }
            if deleteBranch { arguments.append("--delete-branch") }
            return await change(arguments)
        case .deleteBranch(let ref):
            return await deleteBranch(ref)
        case .setDraft(let ref, let draft):
            return await change(["gh", "pr", "ready", String(ref.number), "--repo=\(ref.repo)"] + (draft ? ["--undo"] : []))
        case .setOpen(let ref, let open):
            return await change(["gh", ref.kind == .pullRequest ? "pr" : "issue", open ? "reopen" : "close", String(ref.number),
                                 "--repo=\(ref.repo)"])
        case .editTitle(let ref, let title):
            return await change(["gh", ref.kind == .pullRequest ? "pr" : "issue", "edit", String(ref.number), "--repo=\(ref.repo)",
                                 "--title=\(title.trimmingCharacters(in: .whitespacesAndNewlines))"])
        case .rerunFailed(let repo, let runID):
            return await change(["gh", "run", "rerun", String(runID), "--repo=\(repo)", "--failed"])
        case .browse(let kind, let repo, let filter, let after):
            async let viewerLogin = viewer()
            async let linked = links(context)
            let (viewer, links) = await (viewerLogin, linked)
            return await searched(kind, filter.query(kind: kind, repo: repo), viewer: viewer, links: links, after: after).map {
                .list(ForgeList(kind: kind, repo: repo, viewer: viewer,
                                sections: [ForgeSection(id: .results, pullRequests: $0.pullRequests, issues: $0.issues)], next: $0.next))
            }
        case .people(let repo):
            async let labels = read(["gh", "label", "list", "--repo=\(repo)", "--limit=200", "--json", "name,color"])
            async let assignable = read(["gh", "api", "repos/\(repo)/assignees?per_page=100"])
            let (labelData, peopleData) = await (labels, assignable)
            if case .failure(let error) = labelData, case .failure = peopleData { return .failure(error) }
            return .success(.people(ForgeParse.people(labels: try? labelData.get(), assignable: try? peopleData.get())))
        case .createIssue(let repo, let title, let body):
            return await changed(["gh", "issue", "create", "--repo=\(repo)", "--title=\(title.trimmingCharacters(in: .whitespacesAndNewlines))",
                                  "--body-file", "-"], input: Data(body.utf8)).flatMap { data in
                let link = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                guard let ref = ForgeItemRef(link: link.trimmingCharacters(in: .whitespaces)) else { return .success(.ok) }
                return .success(.created(ref))
            }
        case .edit(let ref, let field, let add, let remove):
            let flag = switch field { case .labels: "label"; case .assignees: "assignee"; case .reviewers: "reviewer" }
            var arguments = ["gh", ref.kind == .pullRequest ? "pr" : "issue", "edit", String(ref.number), "--repo=\(ref.repo)"]
            if !add.isEmpty { arguments.append("--add-\(flag)=\(add.joined(separator: ","))") }
            if !remove.isEmpty { arguments.append("--remove-\(flag)=\(remove.joined(separator: ","))") }
            return await change(arguments)
        case .postReview(let ref, let verdict, let body, let comments):
            let event = switch verdict { case .approve: "APPROVE"; case .requestChanges: "REQUEST_CHANGES"; case .comment: "COMMENT" }
            struct Line: Encodable { let path: String; let line: Int; let side: String; let body: String }
            struct Review: Encodable { let event: String; let body: String; let comments: [Line] }
            let review = Review(event: event, body: body, comments: comments.map {
                Line(path: $0.path, line: $0.line, side: $0.right ? "RIGHT" : "LEFT", body: $0.body)
            })
            guard let input = try? JSONEncoder().encode(review) else { return .failure(Self.unreadable) }
            return await change(["gh", "api", "--method=POST", "repos/\(ref.repo)/pulls/\(ref.number)/reviews", "--input", "-"], input: input)
        case .sidebar:
            return .success(.sidebar(await sidebar(context: context)))
        case .setPinned(let ref, let title, let pinned):
            return .success(.sidebar(ForgeSidebar(pins: setPinned(ref, title: title, pinned: pinned).map { ForgePinnedItem(pin: $0) },
                                                  needsYou: lastNeedsYou.withValue { $0 })))
        }
    }

    /// What the host refuses before running anything: a repository or number gh could misread,
    /// an empty or oversized body or title, an action the item's kind doesn't take.
    static func invalid(_ request: RemoteForgeRequest) -> String? {
        func bad(_ ref: ForgeItemRef) -> Bool { !ForgeItemRef.isValidRepo(ref.repo) || ref.number <= 0 }
        let badRepo = "That isn't a GitHub repository (owner/name)."
        switch request {
        case .repos, .sidebar: return nil
        case .browse(let kind, let repo, let filter, let after):
            if repo != ForgeList.allRepos, !ForgeItemRef.isValidRepo(repo) { return badRepo }
            if filter.text.count > 256 || (after?.count ?? 0) > 256 { return "Search for something shorter than 256 characters." }
            let names = [filter.author, filter.assignee, filter.label].compactMap { $0 }
            if names.contains(where: { $0.isEmpty || $0.count > 100 || $0.contains("\n") }) { return "That isn't a login or label." }
            return kind == .issue && filter.state == .merged ? "Issues aren't merged." : nil
        case .people(let repo): return ForgeItemRef.isValidRepo(repo) ? nil : badRepo
        case .createIssue(let repo, let title, let body):
            if !ForgeItemRef.isValidRepo(repo) { return badRepo }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count > 256 || trimmed.contains("\n") { return "Give the issue a title of one line." }
            return badBody(body, required: false)
        case .edit(let ref, let field, let add, let remove):
            if bad(ref) { return badRepo }
            if field == .reviewers, ref.kind != .pullRequest { return "Only pull requests have reviewers." }
            let all = add + remove
            if all.isEmpty || all.count > 50 { return "Pick something to change." }
            // A comma or a leading dash would split or read as a flag.
            return all.contains { $0.isEmpty || $0.count > 100 || $0.contains(",") || $0.hasPrefix("-") || $0.contains("\n") }
                ? "That isn't a login or label." : nil
        case .postReview(let ref, let verdict, let body, let comments):
            if bad(ref) || ref.kind != .pullRequest { return badRepo }
            if comments.isEmpty, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, verdict != .approve { return "Write a comment first." }
            if comments.count > 100 { return "Post at most 100 comments at once." }
            if comments.contains(where: { $0.line <= 0 || $0.path.isEmpty || $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "Every comment needs a line and some words."
            }
            return badBody(body, required: false) ?? comments.lazy.compactMap { badBody($0.body, required: true) }.first
        case .list(_, let repo, _): return repo == ForgeList.allRepos || ForgeItemRef.isValidRepo(repo) ? nil : badRepo
        case .search(_, let repo, let query):
            if repo != ForgeList.allRepos, !ForgeItemRef.isValidRepo(repo) { return badRepo }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 256 ? "Search for something shorter than 256 characters." : nil
        case .checkLog(let repo, let id), .rerunFailed(let repo, let id):
            return ForgeItemRef.isValidRepo(repo) && id > 0 ? nil : badRepo
        case .pullRequest(let ref), .pullRequestFiles(let ref), .merge(let ref, _, _, _), .setDraft(let ref, _), .deleteBranch(let ref):
            if bad(ref) { return badRepo }
            return ref.kind == .pullRequest ? nil : "That's an issue, not a pull request."
        case .issue(let ref):
            if bad(ref) { return badRepo }
            return ref.kind == .issue ? nil : "That's a pull request, not an issue."
        case .setOpen(let ref, _), .setPinned(let ref, _, _):
            return bad(ref) ? badRepo : nil
        case .comment(let ref, let body):
            if bad(ref) { return badRepo }
            return Self.badBody(body, required: true)
        case .review(let ref, let verdict, let body):
            if bad(ref) { return badRepo }
            if ref.kind != .pullRequest { return "Only a pull request takes a review." }
            return Self.badBody(body, required: verdict != .approve)
        case .editTitle(let ref, let title):
            if bad(ref) { return badRepo }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 256 || trimmed.contains(where: \.isNewline) ? "A title is one line of at most 256 characters." : nil
        }
    }

    private static func badBody(_ body: String, required: Bool) -> String? {
        if required, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write something first." }
        return body.count > ForgeLimits.bodyCharacters ? "That's longer than GitHub takes (\(ForgeLimits.bodyCharacters) characters)." : nil
    }

    /// Deletes a merged pull request's head branch on GitHub: the branch as GitHub names it, never
    /// one the client sent, and never a fork's.
    private func deleteBranch(_ ref: ForgeItemRef) async -> Result<RemoteForgeResult, ForgeError> {
        struct Head: Decodable { var state: String; var headRefName: String; var isCrossRepository: Bool? }
        let view = await runner(ForgeCommand(["gh", "pr", "view", String(ref.number), "--repo=\(ref.repo)", "--json",
                                              "state,headRefName,isCrossRepository"]))
        let head: Head
        switch Self.checked(view) {
        case .failure(let error): return .failure(error)
        case .success(let data):
            guard let read = try? ForgeParse.decode(Head.self, data) else { return .failure(Self.unreadable) }
            head = read
        }
        guard head.state.uppercased() == "MERGED" else { return .failure(ForgeError(.invalid, "Only a merged pull request's branch is deleted here.")) }
        guard head.isCrossRepository != true else { return .failure(ForgeError(.invalid, "The branch is in someone else's fork.")) }
        guard !head.headRefName.isEmpty, let path = head.headRefName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return .failure(Self.unreadable)
        }
        return await change(["gh", "api", "--method=DELETE", "repos/\(ref.repo)/git/refs/heads/\(path)"])
    }

    // MARK: Repositories and links

    /// A folder's checkout root and GitHub repository, or nil.
    func repo(ofDirectory directory: String) async -> ForgeRepo? {
        guard case .success(let top) = await read(["git", "-C", directory, "rev-parse", "--show-toplevel"]) else { return nil }
        let root = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, case .success(let remote) = await read(["git", "-C", root, "remote", "get-url", "origin"]),
              let name = GitHubActivity.repo(fromRemote: String(decoding: remote, as: UTF8.self)), ForgeItemRef.isValidRepo(name) else { return nil }
        return ForgeRepo(nameWithOwner: name, path: root)
    }

    /// Each distinct GitHub repository among `directories`, in their order.
    func repos(_ directories: [String]) async -> [ForgeRepo] {
        // ponytail: the first 50 folders; a host with more threads than that rarely has more repositories.
        let unique = Array(NSOrderedSet(array: directories).array.compactMap { $0 as? String }.prefix(50))
        let found = await withTaskGroup(of: (Int, ForgeRepo?).self) { group in
            for (index, directory) in unique.enumerated() { group.addTask { (index, await self.repo(ofDirectory: directory)) } }
            var found: [(Int, ForgeRepo?)] = []
            for await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.nameWithOwner.lowercased()).inserted }
    }

    /// Which threads are tied to which items: a pull request's head branch, an issue's thread
    /// (`ForgeLinks.issueBranch`) or automation run.
    struct Links {
        /// "owner/name" lowercased → branch → thread.
        var branches: [String: [String: ForgeThreadLink]] = [:]
        /// "owner/name#12" lowercased → thread.
        var issues: [String: ForgeThreadLink] = [:]
        /// "owner/name#12" lowercased → automation name.
        var automationItems: [String: String] = [:]

        func pullRequest(repo: String, head: String) -> ForgeThreadLink? { branches[repo.lowercased()]?[head] }
    }

    func links(_ context: ForgeContext) async -> Links {
        var links = Links()
        for agent in context.agents {
            if let item = agent.automationItem?.lowercased() {
                links.issues[item] = links.issues[item] ?? agent.link
                if let name = agent.automationName { links.automationItems[item] = name }
            }
        }
        let resolved = await withTaskGroup(of: (Int, ForgeRepo?).self) { group in
            for (index, agent) in context.agents.enumerated() where agent.branch != nil {
                group.addTask { (index, await self.repo(ofDirectory: agent.directory)) }
            }
            var resolved: [Int: ForgeRepo] = [:]
            for await (index, repo) in group { resolved[index] = repo }
            return resolved
        }
        for (index, agent) in context.agents.enumerated() {
            guard let branch = agent.branch, let repo = resolved[index]?.nameWithOwner.lowercased() else { continue }
            // A running thread wins a branch two threads share.
            if links.branches[repo]?[branch]?.running != true { links.branches[repo, default: [:]][branch] = agent.link }
            if let number = ForgeLinks.issueNumber(ofBranch: branch) {
                let key = "\(repo)#\(number)"
                if links.issues[key]?.running != true { links.issues[key] = agent.link }
            }
        }
        return links
    }

    /// The signed-in gh user's login, when gh says.
    func viewer() async -> String? {
        guard case .success(let data) = await read(["gh", "api", "user", "--jq", ".login"]) else { return nil }
        let login = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    // MARK: Lists

    private func pullList(_ repo: String, _ filters: [String], limit: Int = 30) -> [String] {
        ["gh", "pr", "list", "--repo=\(repo)"] + filters + ["--limit=\(limit)", "--json", ForgeParse.pullFields]
    }

    private func issueList(_ repo: String, _ filters: [String], limit: Int = 30) -> [String] {
        ["gh", "issue", "list", "--repo=\(repo)"] + filters + ["--limit=\(limit)", "--json", ForgeParse.issueFields]
    }

    private func pulls(_ arguments: [String], repo: String, links: Links) async -> Result<[PullRequestSummary], ForgeError> {
        await read(arguments).flatMap { data in
            Result { try ForgeParse.pullRequests(data, repo: repo) }.mapError { _ in Self.unreadable }
        }.map { $0.map { var pull = $0; pull.thread = links.pullRequest(repo: repo, head: pull.headRef); return pull } }
    }

    private func issues(_ arguments: [String], repo: String, viewer: String?, links: Links) async -> Result<[IssueSummary], ForgeError> {
        await read(arguments).flatMap { data in
            Result { try ForgeParse.issues(data, repo: repo, viewer: viewer) }.mapError { _ in Self.unreadable }
        }.map { $0.map { var issue = $0; Self.link(&issue, links); return issue } }
    }

    private static func link(_ issue: inout IssueSummary, _ links: Links) {
        let key = issue.ref.key.lowercased()
        issue.thread = links.issues[key]
        issue.automationName = links.automationItems[key] ?? issue.thread?.automationName
    }

    static let unreadable = ForgeError(.failed, "gh answered with something Shepherd couldn't read. Update gh and try again.")

    func list(kind: ForgeKind, repo: String, sections wanted: [ForgeSectionID], context: ForgeContext) async -> Result<ForgeList, ForgeError> {
        let order = ForgeSectionID.all(for: kind).filter { wanted.contains($0) }
        async let viewerLogin = viewer()
        async let linked = links(context)
        let (viewer, links) = await (viewerLogin, linked)
        let everywhere = repo == ForgeList.allRepos
        let watched = !everywhere && kind == .issue && order.contains(.fromAutomations) ? await watchedLabels(repo: repo, context: context) : [:]
        let results = await withTaskGroup(of: (ForgeSectionID, Result<ForgeSection, ForgeError>).self) { group in
            for id in order {
                group.addTask {
                    guard everywhere else { return (id, await self.section(id, kind: kind, repo: repo, viewer: viewer, links: links, watched: watched)) }
                    return (id, await self.sectionEverywhere(id, kind: kind, viewer: viewer, links: links, context: context))
                }
            }
            var results: [ForgeSectionID: Result<ForgeSection, ForgeError>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
        var sections: [ForgeSection] = []
        var seen = Set<String>()
        for id in order {
            switch results[id] {
            case .failure(let error)?: return .failure(error)
            case .success(var section)?:
                section.pullRequests.removeAll { !seen.insert($0.id).inserted }
                section.issues.removeAll { !seen.insert($0.id).inserted }
                sections.append(section)
            case nil: break
            }
        }
        return .success(ForgeList(kind: kind, repo: repo, viewer: viewer, sections: sections))
    }

    private func section(_ id: ForgeSectionID, kind: ForgeKind, repo: String, viewer: String?, links: Links,
                         watched: [String: String]) async -> Result<ForgeSection, ForgeError> {
        if kind == .pullRequest {
            let rows: Result<[PullRequestSummary], ForgeError>
            switch id {
            case .authored: rows = await pulls(pullList(repo, ["--author=@me", "--state=open"]), repo: repo, links: links)
            case .reviewRequested:
                rows = await pulls(pullList(repo, ["--state=open", "--search=user-review-requested:@me"]), repo: repo, links: links)
            case .teamReview:
                // Asked of a team you're on, not of you: every request minus the direct ones.
                async let direct = pulls(pullList(repo, ["--state=open", "--search=user-review-requested:@me"]), repo: repo, links: links)
                async let all = pulls(pullList(repo, ["--state=open", "--search=review-requested:@me"]), repo: repo, links: links)
                let mine = Set(((try? await direct.get()) ?? []).map(\.id))
                rows = await all.map { $0.filter { !mine.contains($0.id) } }
            case .openedByAgents:
                rows = await pulls(pullList(repo, ["--state=open"], limit: 100), repo: repo, links: links).map { $0.filter { $0.thread != nil } }
            case .closed:
                rows = await pulls(pullList(repo, ["--state=closed", "--search=involves:@me sort:updated-desc"]), repo: repo, links: links)
            default: rows = .success([])
            }
            return rows.map { ForgeSection(id: id, pullRequests: $0) }
        }
        let rows: Result<[IssueSummary], ForgeError>
        switch id {
        case .assigned: rows = await issues(issueList(repo, ["--assignee=@me", "--state=open"]), repo: repo, viewer: viewer, links: links)
        case .mentioned: rows = await issues(issueList(repo, ["--mention=@me", "--state=open"]), repo: repo, viewer: viewer, links: links)
        case .fromAutomations:
            rows = await issues(issueList(repo, ["--state=open"], limit: 100), repo: repo, viewer: viewer, links: links).map { all in
                all.compactMap { issue in
                    var issue = issue
                    if issue.automationName == nil { issue.automationName = issue.labels.lazy.compactMap { watched[$0.name.lowercased()] }.first }
                    return issue.automationName == nil ? nil : issue
                }
            }
        case .closed:
            rows = await issues(issueList(repo, ["--state=closed", "--search=involves:@me sort:updated-desc"]), repo: repo, viewer: viewer, links: links)
        default: rows = .success([])
        }
        return rows.map { ForgeSection(id: id, issues: $0) }
    }

    /// A section across every repository: GitHub's search for what involves the viewer; agents'
    /// and automations' sections, which only this host knows, from each of its repositories.
    private func sectionEverywhere(_ id: ForgeSectionID, kind: ForgeKind, viewer: String?, links: Links,
                                   context: ForgeContext) async -> Result<ForgeSection, ForgeError> {
        let mine = "archived:false sort:updated-desc"
        let query: String
        switch (kind, id) {
        case (.pullRequest, .authored): query = "is:pr is:open author:@me \(mine)"
        case (.pullRequest, .reviewRequested): query = "is:pr is:open user-review-requested:@me \(mine)"
        case (.pullRequest, .teamReview):
            async let direct = searched(kind, "is:pr is:open user-review-requested:@me \(mine)", viewer: viewer, links: links)
            async let all = searched(kind, "is:pr is:open review-requested:@me \(mine)", viewer: viewer, links: links)
            let directIDs = Set(((try? await direct.get())?.pullRequests ?? []).map(\.id))
            return await all.map { ForgeSection(id: id, pullRequests: $0.pullRequests.filter { !directIDs.contains($0.id) }) }
        case (.issue, .assigned): query = "is:issue is:open assignee:@me \(mine)"
        case (.issue, .mentioned): query = "is:issue is:open mentions:@me \(mine)"
        case (_, .closed): query = "\(kind == .pullRequest ? "is:pr" : "is:issue") is:closed involves:@me sort:updated-desc"
        case (_, .openedByAgents), (_, .fromAutomations):
            // ponytail: one list per repository this host knows (at most 50, cached reads); a host with more needs a search.
            var section = ForgeSection(id: id)
            for repo in await repos(context.directories) {
                let watched = id == .fromAutomations ? await watchedLabels(repo: repo.nameWithOwner, context: context) : [:]
                if id == .fromAutomations, watched.isEmpty, !links.automationItems.keys.contains(where: { $0.hasPrefix(repo.nameWithOwner.lowercased() + "#") }) {
                    continue
                }
                if id == .openedByAgents, links.branches[repo.nameWithOwner.lowercased()] == nil { continue }
                guard case .success(let found) = await self.section(id, kind: kind, repo: repo.nameWithOwner, viewer: viewer, links: links,
                                                                    watched: watched) else { continue }
                section.pullRequests += found.pullRequests
                section.issues += found.issues
            }
            section.pullRequests.sort { $0.updatedAt > $1.updatedAt }
            section.issues.sort { $0.updatedAt > $1.updatedAt }
            return .success(section)
        default: return .success(ForgeSection(id: id))
        }
        return await searched(kind, query, viewer: viewer, links: links).map { ForgeSection(id: id, pullRequests: $0.pullRequests, issues: $0.issues) }
    }

    /// One GitHub search (`gh api graphql`), its rows tied to this host's threads.
    private func searched(_ kind: ForgeKind, _ query: String, viewer: String?, links: Links, after: String? = nil, limit: Int = 30) async
        -> Result<(pullRequests: [PullRequestSummary], issues: [IssueSummary], next: String?), ForgeError> {
        let graphQL = "query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: \(limit), after: $after) "
            + "{ pageInfo { hasNextPage endCursor } nodes { \(ForgeParse.searchNode) } } }"
        var arguments = ["gh", "api", "graphql", "-f", "query=\(graphQL)"]
        if let after { arguments += ["-f", "after=\(after)"] }
        return await read(arguments + ["-f", "q=\(query)"]).flatMap { data in
            Result {
                let next = try ForgeParse.searchNext(data)
                return kind == .pullRequest
                    ? (try ForgeParse.searchedPullRequests(data).map { pull in
                        var pull = pull
                        pull.thread = links.pullRequest(repo: pull.ref.repo, head: pull.headRef)
                        return pull
                    }, [], next)
                    : ([], try ForgeParse.searchedIssues(data, viewer: viewer).map { issue in
                        var issue = issue
                        Self.link(&issue, links)
                        return issue
                    }, next)
            }.mapError { _ in Self.unreadable }
        }
    }

    /// Label (lowercased) → the automation whose GitHub trigger on `repo` waits for it.
    func watchedLabels(repo: String, context: ForgeContext) async -> [String: String] {
        var labels: [String: String] = [:]
        for watch in context.watches where !watch.labels.isEmpty {
            let watchedRepo: String? = if let repo = watch.repo { repo } else { await self.repo(ofDirectory: watch.directory)?.nameWithOwner }
            guard watchedRepo?.lowercased() == repo.lowercased() else { continue }
            for label in watch.labels where labels[label.lowercased()] == nil { labels[label.lowercased()] = watch.automationName }
        }
        return labels
    }

    func search(kind: ForgeKind, repo: String, query: String, context: ForgeContext) async -> Result<ForgeList, ForgeError> {
        let filters = ["--state=all", "--search=\(query.trimmingCharacters(in: .whitespacesAndNewlines))"]
        async let viewerLogin = viewer()
        async let linked = links(context)
        let (viewer, links) = await (viewerLogin, linked)
        if repo == ForgeList.allRepos {
            let query = "\(kind == .pullRequest ? "is:pr" : "is:issue") involves:@me \(query.trimmingCharacters(in: .whitespacesAndNewlines))"
            return await searched(kind, query, viewer: viewer, links: links).map {
                ForgeList(kind: kind, repo: repo, viewer: viewer, sections: [ForgeSection(id: .results, pullRequests: $0.pullRequests, issues: $0.issues)])
            }
        }
        let section: Result<ForgeSection, ForgeError> = kind == .pullRequest
            ? await pulls(pullList(repo, filters), repo: repo, links: links).map { ForgeSection(id: .results, pullRequests: $0) }
            : await issues(issueList(repo, filters), repo: repo, viewer: viewer, links: links).map { ForgeSection(id: .results, issues: $0) }
        return section.map { ForgeList(kind: kind, repo: repo, viewer: viewer, sections: [$0]) }
    }

    // MARK: Details

    func pullRequest(_ ref: ForgeItemRef, context: ForgeContext) async -> Result<PullRequestDetail, ForgeError> {
        let number = String(ref.number)
        async let view = read(["gh", "pr", "view", number, "--repo=\(ref.repo)", "--json", ForgeParse.pullDetailFields])
        async let timeline = read(["gh", "api", "repos/\(ref.repo)/issues/\(number)/timeline?per_page=100"])
        async let comments = read(["gh", "api", "repos/\(ref.repo)/pulls/\(number)/comments?per_page=100"])
        async let settings = read(["gh", "repo", "view", ref.repo, "--json", ForgeParse.repoFields])
        async let viewerLogin = viewer()
        async let linked = links(context)
        let viewData: Data
        switch await view {
        case .success(let data): viewData = data
        case .failure(let error): return .failure(error)
        }
        let (timelineData, commentsData, settingsData, viewer, links) = await (timeline, comments, settings, viewerLogin, linked)
        guard var detail = try? ForgeParse.pullRequestDetail(view: viewData, timeline: try? timelineData.get(), lineComments: try? commentsData.get(),
                                                             repoSettings: try? settingsData.get(), repo: ref.repo, viewer: viewer)
        else { return .failure(Self.unreadable) }
        detail.summary.thread = links.pullRequest(repo: ref.repo, head: detail.summary.headRef)
        return .success(detail)
    }

    func issue(_ ref: ForgeItemRef, context: ForgeContext) async -> Result<IssueDetail, ForgeError> {
        let number = String(ref.number)
        async let view = read(["gh", "issue", "view", number, "--repo=\(ref.repo)", "--json", ForgeParse.issueDetailFields])
        async let timeline = read(["gh", "api", "repos/\(ref.repo)/issues/\(number)/timeline?per_page=100"])
        async let viewerLogin = viewer()
        async let linked = links(context)
        let viewData: Data
        switch await view {
        case .success(let data): viewData = data
        case .failure(let error): return .failure(error)
        }
        let (timelineData, viewer, links) = await (timeline, viewerLogin, linked)
        guard var detail = try? ForgeParse.issueDetail(view: viewData, timeline: try? timelineData.get(), repo: ref.repo, viewer: viewer)
        else { return .failure(Self.unreadable) }
        Self.link(&detail.summary, links)
        return .success(detail)
    }

    // MARK: Sidebar

    func sidebar(context: ForgeContext) async -> ForgeSidebar {
        let pins = loadPins()
        async let needs = needsYou(context: context)
        async let viewerLogin = viewer()
        async let linked = links(context)
        let (viewer, links) = await (viewerLogin, linked)
        let items = await withTaskGroup(of: (Int, ForgePinnedItem).self) { group in
            for (index, pin) in pins.enumerated() {
                group.addTask {
                    let ref = pin.ref
                    var item = ForgePinnedItem(pin: pin)
                    if ref.kind == .pullRequest {
                        let read = await self.read(["gh", "pr", "view", String(ref.number), "--repo=\(ref.repo)", "--json", ForgeParse.pullFields])
                        item.pullRequest = (try? read.get()).flatMap { try? ForgeParse.decode(ForgeParse.Pull.self, $0) }.map {
                            var pull = ForgeParse.summary($0, repo: ref.repo)
                            pull.thread = links.pullRequest(repo: ref.repo, head: pull.headRef)
                            return pull
                        }
                    } else {
                        let read = await self.read(["gh", "issue", "view", String(ref.number), "--repo=\(ref.repo)", "--json", ForgeParse.issueFields])
                        item.issue = (try? read.get()).flatMap { try? ForgeParse.decode(ForgeParse.Issue.self, $0) }.map {
                            var issue = ForgeParse.summary($0, repo: ref.repo, viewer: viewer)
                            Self.link(&issue, links)
                            return issue
                        }
                    }
                    return (index, item)
                }
            }
            var items: [(Int, ForgePinnedItem)] = []
            for await item in group { items.append(item) }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return ForgeSidebar(pins: items, needsYou: await needs)
    }

    /// Pull requests waiting on your review, yours with changes requested or failing checks, and
    /// new issues assigned to you (no linked pull request, no thread here), across the
    /// repositories this host knows. 0 when gh can't say.
    func needsYou(context: ForgeContext) async -> Int {
        // ponytail: the first 20 repositories, as --repo flags on one search each; a host with more needs per-repo pages.
        let repos = await repos(context.directories).prefix(20).map { "--repo=\($0.nameWithOwner)" }
        guard !repos.isEmpty else { return 0 }
        let fields = ["--json", "number,repository", "--limit=100"]
        let searches: [[String]] = [
            ["gh", "search", "prs", "--state=open"] + repos + fields + ["--", "user-review-requested:@me"],
            ["gh", "search", "prs", "--state=open", "--author=@me", "--review=changes_requested"] + repos + fields,
            ["gh", "search", "prs", "--state=open", "--author=@me", "--checks=failure"] + repos + fields,
        ]
        async let linked = links(context)
        async let newIssues = read(["gh", "search", "issues", "--state=open", "--assignee=@me"] + repos + fields + ["--", "-linked:pr"])
        var keys = Set<String>()
        for search in searches {
            if case .success(let data) = await read(search), let found = try? ForgeParse.searchKeys(data) { keys.formUnion(found.map { $0.lowercased() }) }
        }
        let links = await linked
        if case .success(let data) = await newIssues, let found = try? ForgeParse.searchKeys(data) {
            keys.formUnion(found.map { $0.lowercased() }.filter { links.issues[$0] == nil })
        }
        lastNeedsYou.withValue { $0 = keys.count }
        return keys.count
    }

    // MARK: Pins

    private struct PinsFile: Codable {
        var pins: [ForgePin]
        init(pins: [ForgePin]) { self.pins = pins }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pins = try c.decodeIfPresent([ForgePin].self, forKey: .pins) ?? []
        }
    }

    /// The pins as stored, newest first.
    public func loadPins() -> [ForgePin] {
        pinsLock.lock()
        defer { pinsLock.unlock() }
        return Self.readPins(pinsURL)
    }

    private static func readPins(_ url: URL) -> [ForgePin] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(PinsFile.self, from: data))?.pins ?? []
    }

    /// Pins (newest first, at most `ForgeLimits.pins`) or unpins `ref`, and saves.
    @discardableResult
    public func setPinned(_ ref: ForgeItemRef, title: String, pinned: Bool) -> [ForgePin] {
        pinsLock.lock()
        defer { pinsLock.unlock() }
        var pins = Self.readPins(pinsURL).filter { $0.ref != ref }
        if pinned { pins.insert(ForgePin(ref: ref, title: String(title.prefix(256)), pinnedAt: now()), at: 0) }
        pins = Array(pins.prefix(ForgeLimits.pins))
        do {
            try FileManager.default.createDirectory(at: pinsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(PinsFile(pins: pins)).write(to: pinsURL, options: .atomic)
        } catch {
            ShepherdLog.warning("forge pins not saved: \(error)")
        }
        return pins
    }
}
