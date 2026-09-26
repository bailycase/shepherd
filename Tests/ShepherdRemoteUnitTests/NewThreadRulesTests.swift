import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("New thread rules")
struct NewThreadRulesTests {
    static let studioID = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000001")!
    static let buildID = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000002")!
    static let laptopID = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000003")!
    static let shepherd = Space(id: SpaceID(rawValue: "s-shepherd"), name: "shepherd", path: "/Users/dev/code/shepherd")
    static let web = Space(id: SpaceID(rawValue: "s-web"), name: "dashboard-web", path: "/Users/dev/code/dashboard-web")
    static let orders = Space(id: SpaceID(rawValue: "s-orders"), name: "orders-svc", path: "/home/ci/orders-svc")
    static let hiddenSpace = Space(id: SpaceID(rawValue: "s-auto"), name: "Automations", path: "/Users/dev", hidden: true)
    static let all = Set(RemoteProtocol.capabilities)

    static func agent(_ id: String, _ status: AgentStatus, space: Space = shepherd) -> Agent {
        Agent(id: AgentID(rawValue: id), name: id, spaceID: space.id, tabID: TabID(rawValue: "t-" + id), status: status, nameIsFinal: true)
    }

    static var studio: NewThreadHostInput {
        NewThreadHostInput(id: studioID, name: "Studio", phase: .connected, capabilities: all,
                           state: ShepherdState(spaces: [shepherd, web, hiddenSpace],
                                                agents: [agent("a", .working), agent("b", .working), agent("c", .idle),
                                                         agent("run", .working, space: hiddenSpace)]))
    }

    static var build: NewThreadHostInput {
        NewThreadHostInput(id: buildID, name: "build-01", phase: .connected,
                           capabilities: [RemoteProtocol.nativeThreadCapability], state: ShepherdState(spaces: [orders], agents: [agent("d", .idle, space: orders)]))
    }

    static var laptop: NewThreadHostInput {
        NewThreadHostInput(id: laptopID, name: "MacBook Air", phase: .failed(RemoteHostFailure(kind: .unreachable, detail: "refused")), capabilities: [], state: ShepherdState(spaces: [web]))
    }

    static func readyDefaults(_ host: UUID = studioID) -> NewThreadDefaults {
        var defaults = NewThreadDefaults()
        let id = defaults.begin(hostID: host)
        defaults.apply(requestID: id, model: "anthropic/claude-opus", thinking: .medium)
        return defaults
    }

    static func resolvedBase(_ target: NewThreadBase.Target) -> NewThreadBase {
        var base = NewThreadBase()
        let id = base.begin(target)
        base.apply(requestID: id, options: RemoteCreationOptions(base: "origin/main", note: "fetched", fetchFirst: true, model: nil, thinking: .medium))
        return base
    }

    static func draft(prompt: String = "  Fix the tool rows  ", host: NewThreadHostInput? = studio, space: Space? = shepherd,
                      worktree: Bool = true, branch: String = "worktree/calm-otter-1234", attachments: Int = 0) -> NewThreadDraft {
        let target = host.flatMap { host in space.map { NewThreadBase.Target(host: host.id, space: $0.id, cwd: $0.path) } }
        return NewThreadDraft(prompt: prompt, host: host, space: space, defaults: readyDefaults(host?.id ?? studioID), worktree: worktree,
                              branch: branch, base: target.map(resolvedBase) ?? NewThreadBase(), attachments: attachments)
    }

    // MARK: Rows

    @Test func hostRowsSayWhatEachHostIsDoingAndOnlyConnectedOnesCanBeChosen() {
        let rows = NewThreadRows.hosts([Self.studio, Self.build, Self.laptop], selected: Self.studioID)
        #expect(rows.map(\.detail) == ["connected · 2 threads running", "connected · 1 thread", "unreachable"])
        #expect(rows.map(\.selectable) == [true, true, false])
        #expect(rows.map(\.offersRetry) == [false, false, true])
        #expect(rows.map(\.selected) == [true, false, false])
    }

    @Test func aHostOnAnOlderShepherdSaysWhatItCannotDo() {
        let rows = NewThreadRows.hosts([Self.studio, Self.build], selected: nil)
        #expect(rows[0].limitation == nil)
        #expect(rows[1].limitation == "Update Shepherd on build-01 for new worktrees and images.")
    }

    @Test func repoRowsListTheChosenHostsSpacesThenOtherConnectedHosts() {
        let rows = NewThreadRows.repos([Self.studio, Self.build, Self.laptop], host: Self.studioID, space: Self.web.id)
        #expect(rows.map(\.name) == ["shepherd", "dashboard-web", "orders-svc"])
        #expect(rows.map(\.detail) == ["~/code/shepherd", "~/code/dashboard-web", "on build-01"])
        #expect(rows.map(\.selected) == [false, true, false])
        #expect(rows[2].id == .init(host: Self.buildID, space: Self.orders.id))
    }

    @Test(arguments: [
        ("/Users/dev/code/shepherd", "~/code/shepherd"),
        ("/home/ci/orders-svc", "~/orders-svc"),
        ("/Users/dev", "~"),
        ("/opt/src/app", "/opt/src/app"),
        ("relative/path", "relative/path"),
    ])
    func pathsUnderAHomeReadFromTilde(path: String, shown: String) {
        #expect(NewThreadRules.abbreviatedPath(path) == shown)
    }

    // MARK: Defaults and base

    @Test func defaultsKeepAnEditMadeWhileTheSameHostLoadsAndDropItForANewHost() {
        var defaults = NewThreadDefaults()
        let first = defaults.begin(hostID: Self.studioID)
        defaults.edit(model: "openai/gpt-5")
        let second = defaults.begin(hostID: Self.studioID)
        defaults.apply(requestID: first, model: "stale", thinking: .low)
        #expect(defaults.loading)
        defaults.apply(requestID: second, model: "anthropic/claude-opus", thinking: .high)
        #expect(defaults.model == "openai/gpt-5")
        #expect(defaults.thinking == .high)
        #expect(defaults.ready)

        _ = defaults.begin(hostID: Self.buildID)
        #expect(defaults.model == "")
        #expect(!defaults.modelEdited)
        #expect(!defaults.ready)
    }

    @Test func aFailedDefaultsRequestLeavesThemNotReady() {
        var defaults = NewThreadDefaults()
        let id = defaults.begin(hostID: Self.studioID)
        defaults.fail(requestID: id)
        #expect(!defaults.loading)
        #expect(!defaults.ready)
    }

    @Test func aBaseIsReadyOnlyForTheTargetItWasResolvedFor() {
        let target = NewThreadBase.Target(host: Self.studioID, space: Self.shepherd.id, cwd: Self.shepherd.path)
        let other = NewThreadBase.Target(host: Self.studioID, space: Self.web.id, cwd: Self.web.path)
        var base = Self.resolvedBase(target)
        #expect(base.isReady(for: target))
        #expect(base.base == "origin/main")
        #expect(!base.isReady(for: other))
        let id = base.begin(other)
        #expect(base.base == "")
        #expect(!base.isReady(for: other))
        base.fail(requestID: id)
        #expect(!base.resolving)
        #expect(!base.isReady(for: other))
    }

    @Test func aStaleBaseAnswerNeverLands() {
        let target = NewThreadBase.Target(host: Self.studioID, space: Self.shepherd.id, cwd: Self.shepherd.path)
        var base = NewThreadBase()
        let old = base.begin(target)
        let new = base.begin(target)
        base.apply(requestID: old, options: RemoteCreationOptions(base: "stale", note: "", fetchFirst: false, model: nil, thinking: .off))
        #expect(base.resolving)
        base.apply(requestID: new, options: RemoteCreationOptions(base: "origin/main", note: "", fetchFirst: false, model: nil, thinking: .off))
        #expect(base.base == "origin/main")
    }

    // MARK: Start

    @Test func aReadyDraftBuildsTheRequestTheMacSends() throws {
        let creation = try #require(NewThreadRules.creation(Self.draft()))
        #expect(creation == NewThreadCreation(spaceID: Self.shepherd.id, cwd: "/Users/dev/code/shepherd", model: "anthropic/claude-opus",
                                              thinking: .medium, initialPrompt: "Fix the tool rows",
                                              worktreeBranch: "worktree/calm-otter-1234", worktreeBase: "origin/main",
                                              worktreeFetchFirst: true, firstSend: nil))
    }

    @Test func withoutAWorktreeOrAPromptTheRequestLeavesThemOut() throws {
        var draft = Self.draft(prompt: "   ", worktree: false)
        draft.defaults.edit(model: "  ")
        let creation = try #require(NewThreadRules.creation(draft))
        #expect(creation.initialPrompt == nil)
        #expect(creation.model == nil)
        #expect(creation.worktreeBranch == nil)
        #expect(creation.worktreeBase == nil)
        #expect(creation.worktreeFetchFirst == nil)
    }

    @Test func imagesMoveThePromptToTheFirstSend() throws {
        let creation = try #require(NewThreadRules.creation(Self.draft(attachments: 2)))
        #expect(creation.initialPrompt == nil)
        #expect(creation.firstSend == "Fix the tool rows")
    }

    @Test func aHostWithoutWorktreesCreatesInItsCheckout() throws {
        let draft = Self.draft(host: Self.build, space: Self.orders, worktree: true)
        #expect(!draft.usesWorktree)
        let creation = try #require(NewThreadRules.creation(draft))
        #expect(creation.worktreeBranch == nil)
    }

    @Test(arguments: [
        ("no host", NewThreadBlocker.noHost),
        ("offline", .hostOffline("MacBook Air")),
        ("no repo", .noRepo("Studio")),
        ("loading", .loadingDefaults("Studio")),
        ("failed", .defaultsFailed("Studio")),
        ("other host", .loadingDefaults("Studio")),
        ("no branch", .noBranch),
        ("resolving", .resolvingBase("Studio")),
        ("unresolved", .baseUnresolved),
        ("old host images", .imagesUnsupported("build-01")),
        ("images without prompt", .imagesNeedPrompt),
        ("starting", .starting),
    ])
    func eachMissingPieceBlocksStartWithItsReason(_ situation: String, _ expected: NewThreadBlocker) {
        var draft = Self.draft()
        switch situation {
        case "no host": draft.host = nil
        case "offline": draft = Self.draft(host: Self.laptop, space: Self.web)
        case "no repo": draft.space = nil
        case "loading": _ = draft.defaults.begin(hostID: Self.studioID)
        case "failed":
            let id = draft.defaults.begin(hostID: Self.studioID)
            draft.defaults.fail(requestID: id)
        case "other host": draft.defaults = Self.readyDefaults(Self.buildID)
        case "no branch": draft.branch = "  "
        case "resolving": _ = draft.base.begin(draft.baseTarget!)
        case "unresolved": draft.base = NewThreadBase()
        case "old host images": draft = Self.draft(host: Self.build, space: Self.orders, attachments: 1)
        case "images without prompt": draft = Self.draft(prompt: " ", attachments: 1)
        case "starting": draft.starting = true
        default: Issue.record("unknown situation \(situation)")
        }
        #expect(NewThreadRules.blocker(draft) == expected)
        #expect(NewThreadRules.creation(draft) == nil)
    }

    @Test func waitingOnTheHostIsPendingNotAProblem() {
        #expect(NewThreadBlocker.loadingDefaults("Studio").isPending)
        #expect(NewThreadBlocker.resolvingBase("Studio").isPending)
        #expect(!NewThreadBlocker.noBranch.isPending)
        #expect(!NewThreadBlocker.hostOffline("Studio").isPending)
    }

    // MARK: Words and search

    @Test(arguments: [
        ("anthropic/claude-opus", "claude-opus"),
        ("gpt-5", "gpt-5"),
        ("cpa/~anthropic/claude-haiku-latest", "claude-haiku-latest"),
        ("", "Default model"),
    ])
    func aModelChipDropsTheProvider(id: String, shown: String) {
        #expect(NewThreadRules.shortModel(id) == shown)
    }

    @Test func worktreeSummaryNamesTheRepo() {
        #expect(NewThreadRules.worktreeSummary(repo: "shepherd", worktree: true) == "New worktree on shepherd")
        #expect(NewThreadRules.worktreeSummary(repo: "shepherd", worktree: false) == "In shepherd's checkout")
        #expect(NewThreadRules.worktreeSummary(repo: nil, worktree: true) == "Choose a repo")
    }

    @Test(arguments: [
        ("origin/main", "Keeps main clean. Merge it from Review."),
        ("develop", "Keeps develop clean. Merge it from Review."),
        ("", "Keeps the checkout clean. Merge it from Review."),
    ])
    func theWorktreeCaptionNamesTheBaseBranch(base: String, caption: String) {
        #expect(NewThreadRules.worktreeCaption(base: base) == caption)
    }

    @Test func modelSearchRanksPrefixThenSubstringThenScattered() {
        let options = ["openai/gpt-5", "anthropic/claude-sonnet", "anthropic/claude-opus", "google/gemini-pro", "meta/opus-like"]
        #expect(NewThreadRules.rankModels("opus", in: options) == ["meta/opus-like", "anthropic/claude-opus", "anthropic/claude-sonnet"])
        #expect(NewThreadRules.rankModels("cls", in: options) == ["anthropic/claude-sonnet", "anthropic/claude-opus"])
        #expect(NewThreadRules.rankModels("", in: options, limit: 2) == ["openai/gpt-5", "anthropic/claude-sonnet"])
        #expect(NewThreadRules.rankModels("zzz", in: options).isEmpty)
    }

    @Test func aGeneratedBranchIsAReadableWorktreeName() {
        var generator = SeededGenerator(seed: 7)
        let branch = NewThreadRules.generatedBranch(using: &generator)
        #expect(branch.wholeMatch(of: /agent\/[a-z]+-[a-z]+-\d{4}/) != nil)
        var again = SeededGenerator(seed: 7)
        #expect(NewThreadRules.generatedBranch(using: &again) == branch)
    }

    @Test func foldersHideDotFoldersUnlessAskedAndFilterFuzzily() {
        let dirs = ["Shepherd", ".config", "shell-tools", "Documents", "src"]
        #expect(NewThreadFolders.visible(dirs, filter: "", showHidden: false) == ["Shepherd", "shell-tools", "Documents", "src"])
        #expect(NewThreadFolders.visible(dirs, filter: "", showHidden: true) == ["Shepherd", "shell-tools", "Documents", "src", ".config"])
        #expect(NewThreadFolders.visible(dirs, filter: "sh", showHidden: false) == ["shell-tools", "Shepherd"])
        #expect(NewThreadFolders.visible(dirs, filter: "sr", showHidden: false) == ["src", "Shepherd"])
        #expect(NewThreadFolders.visible(dirs, filter: ".c", showHidden: false) == [".config"])
        #expect(NewThreadFolders.child("app", of: "/Users/dev") == "/Users/dev/app")
        #expect(NewThreadFolders.child("app", of: "/") == "/app")
    }
}

/// A fixed sequence, so a generated branch is the same every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
