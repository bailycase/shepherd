import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

enum RemoteSamples {
    static let op = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let agent = AgentID(rawValue: "agent")
    static let session = SessionID(rawValue: "session")
    static let space = SpaceID(rawValue: "space")
    static let pane = PaneID(rawValue: "pane")
    static let tab = TabID(rawValue: "tab")
    static let split = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(cwd: "/a")), second: .leaf(LeafPane(cwd: "/b")))
    static let finalize = RemoteFinalizeOptions(
        base: "main", title: "fix", body: "details", autoCommit: false, deleteLocalBranch: true,
        autoMergePR: true, mergeMethod: "squash"
    )

    static let commitFile = RemoteCommitFile(path: "App/iOS/FleetView.swift", status: "M", added: 9, removed: 7, fingerprint: "f1")
    static let renamedFile = RemoteCommitFile(path: "new name.swift", oldPath: "old.swift", status: "R", added: 0, removed: 0, fingerprint: "f2")
    static let commitInfo = RemoteCommitInfo(
        repository: "/host/repo", branch: "feat/x", head: "abc123", upstream: "origin/feat/x", pushRemote: "origin",
        defaultBranch: "main", files: [commitFile, renamedFile], title: "Update 2 files", body: "- a\n- b",
        draftsMessage: true, agentWorking: true, blocked: nil)
    static let detachedInfo = RemoteCommitInfo(
        repository: "/host/repo", branch: nil, head: "", upstream: nil, pushRemote: nil, defaultBranch: nil, files: [],
        title: "", body: "", draftsMessage: false, agentWorking: false, blocked: "HEAD is detached.")

    static let state: ShepherdState = {
        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        // The live fields ride the wire (state.json drops `waitingOn` and `waitingReason`; a remote
        // client needs them).
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .blocked,
                          lastActiveAt: 1_790_000_000_000, waitingOn: "Which base?", waitingReason: "base?")
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }()

    static let agentQueries: [RemoteAgentQuery] = [
        .deleteKeepingWorktree,
        .worktreeInfo,
        .worktreeSetup(action: .check),
        .worktreeSetup(action: .applyIdentity(name: "O'Neil", email: "test@example.invalid")),
        .worktreeSetup(action: .installCommandLineTools),
        .worktreeSetup(action: .enableDeleteBranchOnMerge),
        .worktreeSetup(action: .enableAutoMerge),
        .worktreeSetup(action: .loginShell),
        .worktreeCommitCount(base: "release"),
        .worktreeDescription(base: "release", title: "fix"),
        .deleteWorktree(operationID: op, confirmedWarning: "dirty", fingerprint: "hash"),
        .deleteWorktree(operationID: op, confirmedWarning: nil),
        .finalizeWorktree(operationID: op, options: finalize),
        .worktreeStatus(operationID: op),
        .review(pullRequest: true),
        .reviewPane(paneID: pane, pullRequest: false),
        .reviewPane(paneID: pane),
        .finishReview(paneID: pane, text: "feedback"),
        .finishReview(paneID: pane, text: nil),
        .children,
        .inspectorPane(tabID: tab, action: .split(paneID: pane, axis: .horizontal)),
        .inspectorPane(tabID: tab, action: .close(paneID: pane)),
        .inspectorPane(tabID: tab, action: .resize(split: split, ratio: 0.6)),
        .search(query: "prompt"),
        .terminals,
        .commitInfo,
        .commitMessage(paths: ["old.swift", "new name.swift"]),
        .commit(operationID: op, options: RemoteCommitOptions(head: "abc123", files: [commitFile, renamedFile], title: "Fix \"it\"",
                                                              body: "why", push: .pullRequest, newBranch: "shepherd/fix-it",
                                                              confirmedWhileWorking: true)),
        .commit(operationID: op, options: RemoteCommitOptions(head: "", files: [commitFile], title: "t", body: "", push: .none)),
        .commit(operationID: op, options: RemoteCommitOptions(head: "abc", files: [commitFile], title: "t", body: "", push: .upstream)),
        .changesOverview,
        .changesList(scope: .lastTurn, options: ChangesOptions()),
        .changesList(scope: .turn(id: op), options: ChangesOptions(ignoreWhitespace: true)),
        .changesList(scope: .uncommitted, options: ChangesOptions(fullFiles: true)),
        .changesList(scope: .unstaged, options: ChangesOptions()),
        .changesList(scope: .staged, options: ChangesOptions()),
        .changesList(scope: .commits(first: "5d11a07", last: "a1c9f2e"), options: ChangesOptions()),
        .changesList(scope: .branch(base: "origin/release/2.4"), options: ChangesOptions()),
        .changesList(scope: .branch(base: nil), options: ChangesOptions()),
        .changesList(scope: .pullRequest, options: ChangesOptions()),
        .changesFile(revision: revision, path: "ledger/outbox.go", oldPath: nil, options: ChangesOptions(ignoreWhitespace: true, fullFiles: true)),
        .changesFile(revision: revision, path: "new name.go", oldPath: "old.go", options: ChangesOptions()),
        .changesBranches,
        .changesPatch(revision: revision, options: ChangesOptions()),
        .changesUndoTurn(turnID: op),
        .changesRedoTurn(turnID: op),
    ]

    static let revision = ChangesRevision(old: "3f2a91c0", new: "4b825dc6")
    static let changedFiles = [
        ChangesFile(path: "ledger/outbox.go", status: .modified, added: 21, removed: 8),
        ChangesFile(path: "ledger/refund.go", status: .added, added: 64, removed: 0),
        ChangesFile(path: "new name.go", oldPath: "old.go", status: .renamed, added: 0, removed: 0),
        ChangesFile(path: "logo.png", status: .deleted, added: 0, removed: 0, isBinary: true),
    ]
    static let turn = ChangesTurn(id: op, messageTimestamp: 1_758_000_000_000, prompt: "Wrap errors with context", startedAt: 1_758_000_000_100,
                                  endedAt: 1_758_000_240_000, state: .ready, files: changedFiles, fileCount: 7, added: 85, removed: 8,
                                  canUndo: true)
    static let overview = ChangesOverview(
        repository: "/host/payments", branch: "agent/refund-events", head: "a1c9f2e", defaultScope: .branch(base: nil), defaultBase: "origin/main",
        entries: [.init(scope: .lastTurn, files: 2, added: 12, removed: 3), .init(scope: .pullRequest, unavailable: "No pull request for this branch."),
                  .init(scope: .commits(first: "5d11a07", last: "a1c9f2e"), count: 4)],
        commits: [ChangesCommit(id: "a1c9f2e00", shortID: "a1c9f2e", subject: "Emit refund events from the outbox", date: 1_758_000_000)],
        commitsBase: "origin/main",
        pullRequest: ChangesPullRequest(number: 31, title: "Refund events", isDraft: true, state: "OPEN", base: "main", head: "agent/refund-events",
                                        url: "https://example.invalid/pull/31"),
        lastTurn: turn)

    static let agentResults: [RemoteAgentResult] = [
        .ok,
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: "3 uncommitted files", defaults: finalize,
                                         generateDescription: true, fingerprint: "abc")),
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: nil, defaults: finalize)),
        .worktreeSetup(RemoteWorktreeSetup(
            repoPath: "/host/repo",
            checks: ["git": .pass("installed"), "identity": .fail("missing"), "remote": .checking, "gh": .pending],
            repoSettings: ["allowAutoMerge": .disabled, "deleteBranchOnMerge": .unavailable("admin required"),
                           "a": .enabled, "b": .unknown, "c": .checking]
        )),
        .worktreeCommitCount(23),
        .worktreeCommitCount(nil),
        .worktreeDescription(body: "## Summary\nHost changes"),
        .worktreeOperation(RemoteWorktreeOperation(id: op, finished: true, error: "failed", progress: ["push failed"], prURL: nil)),
        .worktreeOperation(RemoteWorktreeOperation(id: op, prURL: "https://example.invalid/pr/1")),
        .review(files: Data("[]".utf8), reference: "origin/main"),
        .children([ChildRun(runID: "run", label: "child", state: "running")]),
        .inspector(tab),
        .inspectorFocus(pane),
        .search(snippet: "matched text"),
        .search(snippet: nil),
        .terminals([RemoteTerminalActivity(paneID: pane, sessionID: SessionID(), process: "make", command: "make dev", outputSequence: 42),
                    RemoteTerminalActivity(paneID: PaneID(), sessionID: SessionID(), process: nil, command: nil, outputSequence: 0),
                    RemoteTerminalActivity(paneID: PaneID(), sessionID: SessionID(), process: "zsh", command: nil, outputSequence: 9,
                                           newsSequence: 4)]),
        .terminals([]),
        .commitInfo(commitInfo),
        .commitInfo(detachedInfo),
        .commitMessage(title: "Show commands in tool rows", body: "Tool rows preview the command.", drafted: true),
        .commitMessage(title: "Update FleetView.swift", body: "", drafted: false),
        .changesOverview(overview),
        .changesOverview(ChangesOverview(repository: nil, reason: "notes is not a git repository.", defaultScope: .uncommitted)),
        .changesList(ChangesList(scope: .branch(base: nil), revision: revision,
                                 comparison: ChangesComparison(head: "agent/refund-events", base: "origin/main", baseName: "main", mergeBase: "3f2a91c"),
                                 files: changedFiles, skipped: ["dump.bin"])),
        .changesList(ChangesList(scope: .lastTurn, revision: revision,
                                 comparison: ChangesComparison(head: "End of turn", base: "Start of turn", turn: turn), files: [])),
        .changesFile(ChangesFileDiff(file: DiffFile.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n")[0], truncated: true)),
        .changesBranches(ChangesBranches(defaultBase: "origin/main", pullRequestBase: "origin/main", recents: ["feat/ledger-v2"],
                                         branches: [ChangesBranch(name: "origin/main", isRemote: true, committedAt: 1_758_000_000),
                                                    ChangesBranch(name: "agent/retry-plan", isRemote: false, worktree: "/w/retry", committedAt: 1),
                                                    ChangesBranch(name: "agent/refund-events", isRemote: false, isCurrent: true, committedAt: 2)])),
        .changesBranches(ChangesBranches(defaultBase: nil, branches: [])),
        .changesPatch(text: "diff --git a/a b/a\n", truncated: false),
        .changesTurn(turn),
        .changesTurn(ChangesTurn(id: op, startedAt: 1, state: .unavailable, reason: "Shepherd quit before this turn ended.")),
    ]

    static let automation = AutomationID(rawValue: "automation")
    static let draft = RemoteAutomationDraft(name: "Nightly \"dry\" run", prompt: "Run every migration\nReport", cwd: "/host/repo",
                                             enabled: false)
    static let automationRequests: [RemoteAutomationRequest] = [
        .setEnabled(enabled: true), .setEnabled(enabled: false), .run, .stop, .runs,
        .create(draft: draft), .update(draft: draft), .delete,
    ]
    static let runs: [AutomationRun] = [
        AutomationRun(id: op, startedAt: 1_700_000_000, settledAt: 1_700_000_043, endedAt: 1_700_000_100, result: .finished),
        AutomationRun(id: op, startedAt: 1_700_000_200, result: .needsYou, agentID: agent),
        AutomationRun(id: op, startedAt: 1_700_000_300, endedAt: 1_700_000_400, result: .interrupted),
    ]
    static let automationResults: [RemoteAutomationResult] = [.ok, .runs([]), .runs(runs)]

    static let instructionsRequests: [RemoteInstructionsRequest] = [
        .fetch,
        .save(file: .agents, content: "# How I work\n- Prefer \"small\" commits.\n", origin: "studio", sync: false),
        .save(file: .appendSystem, content: "", origin: "iPhone", sync: true),
        .restore(revisionID: op, origin: "This Mac"),
    ]
    static let instructions = InstructionsSnapshot(
        agents: "- Prefer small commits.\n", appendSystem: "Never force-push.\n",
        directory: "~/Library/Application Support/Shepherd/instructions",
        history: [
            InstructionHistoryEntry(id: op, file: .appendSystem, savedAt: 1_700_000_100, summary: "Synced from studio", origin: "studio"),
            InstructionHistoryEntry(id: op, file: .agents, savedAt: 1_700_000_000, summary: "Added “Prefer small commits.”"),
        ])

    static let suggestionSettings = SuggestedInstructionsSettings(enabled: true, since: 1_700_000_000, sources: [.automation],
                                                                  files: [.agents, .appendSystem])
    static let suggestionsRequests: [RemoteSuggestionsRequest] = [
        .fetch,
        .configure(suggestionSettings),
        .configure(SuggestedInstructionsSettings()),
        .add(id: op, line: nil, file: nil),
        .add(id: op, line: "- Ask for \"join keys\" first.", file: .appendSystem),
        .addAll,
        .dismiss(id: op),
        .undo(id: op),
    ]
    static let suggestions = SuggestionsSnapshot(
        settings: suggestionSettings,
        waiting: [
            InstructionSuggestion(id: op, line: "- Run `go mod tidy` with any dependency bump.", reason: "CI failed twice on a stale go.sum.",
                                  file: .agents, source: SuggestionSource(kind: .automation, name: "Nightly dependency bump"),
                                  suggestedAt: 1_700_000_200),
        ],
        added: [
            AddedSuggestion(id: op, line: "- Prefer table-driven tests in Go.", file: .agents, sourceName: "Ledger cleanup",
                            addedAt: 1_700_000_100),
        ])

    static let hostSettings = HostSettings(
        shepherdVersion: "0.4.2", piVersion: "0.87.1", defaultModel: "anthropic/claude-opus", defaultThinking: .high,
        queueDelivery: .oneAtATime, worktreeBase: .head, fetchBeforeCreating: false, mergePRAutomatically: true, mergeMethod: .rebase,
        bundledExtensions: [HostSettings.BundledExtension(id: "panes", name: "Panes and agent tools", on: true),
                            HostSettings.BundledExtension(id: "review", name: "Diff review tool", on: false)],
        installedExtensions: ["npm:@example/pi-tools@1.0.0"], updatePiDaily: true)
    static let hostSettingChanges: [HostSettingChange] = [
        .defaultModel("openai/gpt-5"), .defaultModel(nil), .defaultThinking(.low), .queueDelivery(.all),
        .worktreeBase(.fresh), .fetchBeforeCreating(true), .commitRemainingWork(false), .generatePRDescriptions(false),
        .deleteLocalBranch(false), .mergePRAutomatically(false), .mergeMethod(.squash),
        .bundledExtension(id: "review", on: true), .updatePiDaily(false), .updateExtensionsDaily(true),
    ]

    static let skillSource = SkillSource(repo: "anthropics/skills", path: "skills/pdf", commit: "3f2a91c0", committedAt: 1_700_000_000)
    static let skills = SkillsSnapshot(
        directory: "~/.agents/skills",
        skills: [
            InstalledSkill(name: "pdf", summary: "Read, fill, merge and split PDFs.", source: skillSource, updatedAt: 1_700_000_100,
                           files: [SkillFileEntry(name: "SKILL.md"), SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 8)],
                           update: SkillUpdate(commit: "8c04e1d0", committedAt: 1_700_000_900, filesChanged: 3)),
            InstalledSkill(name: "changelog", summary: "Drafts a \"CHANGELOG\" entry.", isOn: false, invocation: .slashOnly,
                           updatedAt: 1_690_000_000),
        ],
        checkedAt: 1_700_000_500, autoUpdate: true,
        pi: PiSkills(agentDirectory: "~/.pi/agent", skills: [
            PiSkill(name: "review", summary: "Reviews a diff.", path: "~/.pi/agent/skills/review/SKILL.md", origin: .agentDirectory),
            PiSkill(name: "lint", summary: "Runs the linters.", path: "~/code/skills/lint/SKILL.md", origin: .settingsPath,
                    invocation: .slashOnly),
            PiSkill(name: "review", summary: "Another review.", path: "~/.pi/agent/npm/node_modules/@acme/skills/review/SKILL.md",
                    origin: .package, package: "@acme/skills", shadowedBy: "~/.pi/agent/skills/review/SKILL.md"),
        ], shadowedInstalled: ["pdf": "~/.pi/agent/skills/pdf/SKILL.md"]))
    static let repoSkills = RepoSkills(
        repo: "anthropics/skills", branch: "main", commit: "8c04e1d0",
        skills: [
            RepoSkill(path: "skills/docx", name: "docx", summary: "Create and edit Word documents.",
                      instructions: "---\nname: docx\n---\n# Word documents\n", files: [SkillFileEntry(name: "SKILL.md")]),
            RepoSkill(path: "", name: "solo", summary: "The repository is the skill."),
        ])
    static let skillsRequests: [RemoteSkillsRequest] = [
        .fetch,
        .lookUp(repo: "https://github.com/anthropics/skills"),
        .install(repo: "anthropics/skills", paths: ["skills/docx", "skills/pptx"], commit: "8c04e1d0", invocation: .slashOnly),
        .install(repo: "acme/platform-skills", paths: [""], commit: nil, invocation: nil),
        .installFiles(name: "go-table-tests", files: [SkillFile(path: "SKILL.md", contents: Data("---\nname: go-table-tests\n---\n".utf8)),
                                                      SkillFile(path: "scripts/run.sh", contents: Data([0x23, 0x21]), executable: true)],
                      invocation: .automatic),
        .setOn(name: "pdf", on: false),
        .setInvocation(name: "pdf", invocation: .slashOnly),
        .remove(name: "pdf"),
        .restore(name: "pdf"),
        .checkUpdates,
        .configure(autoUpdate: true),
    ]
    static let skillsResults: [RemoteSkillsResult] = [
        .skills(skills), .skills(SkillsSnapshot(directory: "~/.agents/skills")),
        .skills(SkillsSnapshot(directory: "~/.agents/skills", pi: PiSkills(agentDirectory: "~/.pi/agent", problem: "pi_not_found"))),
        .repo(repoSkills),
    ]
}

@Suite("Remote requests")
struct RemoteRequestTests {
    typealias S = RemoteSamples

    /// Exhaustive on purpose: a new case fails to compile here until it is named, then
    /// `samplesCoverEveryCase` fails until it has a sample.
    static func caseName(_ request: RemoteRequest) -> String {
        switch request {
        case .nativeThread, .hello, .stateFetch, .attach, .detach, .input, .resize, .paste, .openPane,
             .closePane, .resizePaneSplit, .listDir, .listModels, .addSpace, .createAgent, .upload,
             .creationOptions, .agentQuery, .agentAction, .automation, .instructions, .suggestions, .hostSettings, .skills, .design:
            return Wire.caseName(request)
        }
    }
    static let caseCount = 25

    static let samples: [RemoteRequest] = [
        .nativeThread(id: 80, agentID: S.agent, request: .snapshot(expectedSessionID: "s", beforeEntryID: "m:3", afterRevision: 9)),
        .hello(id: 2, token: "", clientName: "Baily's MacBook \"Pro\"", protocolVersion: 99),
        .hello(id: 9, token: "t", clientName: "Mac", protocolVersion: 1, capabilities: RemoteProtocol.clientCapabilities),
        .stateFetch(id: 3),
        .attach(id: 4, sessionID: S.session, cols: 120, rows: 40, viewportGeneration: 2),
        .detach(sessionID: S.session),
        .input(sessionID: S.session, data: Data([0x1B, 0x5B, 0x41])),
        .resize(sessionID: S.session, cols: 80, rows: 24, viewportGeneration: 3),
        .paste(id: 12, sessionID: S.session, text: "multi\nline \"prompt\"", submit: false),
        .openPane(id: 14, agentID: S.agent, axis: .vertical, relativeTo: S.pane),
        .closePane(id: 15, agentID: S.agent, paneID: S.pane),
        .resizePaneSplit(id: 16, agentID: S.agent, split: S.split, ratio: 0.7),
        .listDir(id: 8, path: ""),
        .listModels(id: 10),
        .addSpace(id: 5, path: "/Users/demo/Developer/project"),
        .createAgent(id: 6, spaceID: S.space, cwd: "/tmp/checkout", model: "anthropic/claude-4", thinking: .high,
                     initialPrompt: "fix the \"thing\"\nplease", worktreeBranch: "worktree/a", worktreeBase: "origin/release",
                     worktreeFetchFirst: false,
                     initialImages: [NativeImage(mimeType: "image/png", data: Data([0x89, 0x50]), name: "shot.png")]),
        .upload(id: 50, action: .begin(sessionID: S.session, name: "image.png", size: 20)),
        .creationOptions(id: 54, spaceID: S.space, cwd: "/host/repo", fetchFirst: false),
        .agentQuery(id: 31, agentID: S.agent, query: .children),
        .agentAction(id: 20, agentID: S.agent, action: .rename(name: "new \"name\"")),
        .automation(id: 21, automationID: S.automation, request: .setEnabled(enabled: false)),
        .instructions(id: 23, request: .save(file: .appendSystem, content: "Never force-push.\n", origin: "studio", sync: true)),
        .suggestions(id: 25, request: .add(id: S.op, line: "- Ask for join keys first.", file: nil)),
        .hostSettings(id: 27, request: .change(.bundledExtension(id: "review", on: true))),
        .skills(id: 29, request: .install(repo: "anthropics/skills", paths: ["skills/pdf"], commit: nil, invocation: nil)),
        .design(id: 31, request: .boards(designID: RemoteDesignSamples.design, paths: nil, knownShas: [:])),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ request: RemoteRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ request: RemoteRequest) throws {
        #expect(try Wire.object(request)["type"] as? String == Self.caseName(request))
    }

    @Test(arguments: RemoteSamples.agentQueries)
    func everyAgentQueryRoundTrips(_ query: RemoteAgentQuery) throws {
        let request = RemoteRequest.agentQuery(id: 1, agentID: S.agent, query: query)
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test(arguments: [
        RemoteUploadAction.begin(sessionID: RemoteSamples.session, name: "a.png", size: 3),
        .chunk(uploadID: RemoteSamples.op, data: Data([0, 1, 2])),
        .finish(uploadID: RemoteSamples.op),
        .cancel(uploadID: RemoteSamples.op),
    ])
    func everyUploadActionRoundTrips(_ action: RemoteUploadAction) throws {
        #expect(try Wire.roundTrip(RemoteRequest.upload(id: 1, action: action)) == .upload(id: 1, action: action))
    }

    @Test(arguments: [RemoteAgentAction.rename(name: "x"), .deleteKeepingWorktree, .reorder(target: AgentID(rawValue: "b")),
                      .renameTerminal(paneID: PaneID(rawValue: "p"), title: "logs"), .renameTerminal(paneID: PaneID(rawValue: "p"), title: nil),
                      .killTerminalProcess(paneID: PaneID(rawValue: "p"))])
    func everyAgentActionRoundTrips(_ action: RemoteAgentAction) throws {
        #expect(try Wire.roundTrip(RemoteRequest.agentAction(id: 1, agentID: S.agent, action: action))
            == .agentAction(id: 1, agentID: S.agent, action: action))
    }

    /// Run in terminal is gone: an older client's `typeInTerminal` is no action this side knows.
    @Test func anOlderClientsRunInTerminalIsNoLongerAnAction() {
        let line = Data(#"{"type":"agentAction","id":4,"agentID":"a","action":{"typeInTerminal":{"paneID":"p","text":"ls"}}}"#.utf8)
        #expect(throws: DecodingError.self) { try NDJSON.decode(RemoteRequest.self, from: line) }
    }

    @Test(arguments: RemoteSamples.automationRequests)
    func everyAutomationRequestRoundTrips(_ request: RemoteAutomationRequest) throws {
        let message = RemoteRequest.automation(id: 1, automationID: S.automation, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: RemoteSamples.instructionsRequests)
    func everyInstructionsRequestRoundTrips(_ request: RemoteInstructionsRequest) throws {
        let message = RemoteRequest.instructions(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: RemoteSamples.suggestionsRequests)
    func everySuggestionsRequestRoundTrips(_ request: RemoteSuggestionsRequest) throws {
        let message = RemoteRequest.suggestions(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: RemoteSamples.hostSettingChanges)
    func everyHostSettingChangeRoundTrips(_ change: HostSettingChange) throws {
        let message = RemoteRequest.hostSettings(id: 1, request: .change(change))
        #expect(try Wire.roundTrip(message) == message)
        #expect(try Wire.roundTrip(RemoteRequest.hostSettings(id: 2, request: .fetch)) == .hostSettings(id: 2, request: .fetch))
    }

    @Test(arguments: RemoteSamples.skillsRequests)
    func everySkillsRequestRoundTrips(_ request: RemoteSkillsRequest) throws {
        let message = RemoteRequest.skills(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test func anAutomationRequestNamesItsAutomation() throws {
        let object = try Wire.object(RemoteRequest.automation(id: 1, automationID: S.automation, request: .run))
        #expect(object["automationID"] as? String == "automation")
        #expect(object["type"] as? String == "automation")
    }

    /// An older host decodes a createAgent with images as one without them, so a client asks
    /// for `createAgentImagesCapability` first; the images travel as base64 under their own key.
    @Test func aCreateAgentsImagesTravelUnderTheirOwnKey() throws {
        let image = NativeImage(mimeType: "image/jpeg", data: Data([1, 2, 3]))
        let request = RemoteRequest.createAgent(id: 7, spaceID: S.space, cwd: nil, model: nil, thinking: nil,
                                                initialPrompt: "look", initialImages: [image])
        let images = try #require(try Wire.object(request)["initialImages"] as? [[String: Any]])
        #expect(images.map { $0["mimeType"] as? String } == ["image/jpeg"])
        #expect(images.first?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func aMinimalCreateAgentOmitsEveryOptional() throws {
        let request = RemoteRequest.createAgent(id: 7, spaceID: S.space, cwd: nil, model: nil, thinking: nil, initialPrompt: nil)
        #expect(Set(try Wire.object(request).keys) == ["type", "id", "spaceID"])
        #expect(try Wire.roundTrip(request) == request)
    }

    /// Older clients predate viewport generations and the paste `submit` flag.
    @Test(arguments: [
        (#"{"type":"attach","id":1,"sessionID":"session","cols":80,"rows":24}"#,
         RemoteRequest.attach(id: 1, sessionID: RemoteSamples.session, cols: 80, rows: 24, viewportGeneration: 0)),
        (#"{"type":"resize","sessionID":"session","cols":90,"rows":30}"#,
         .resize(sessionID: RemoteSamples.session, cols: 90, rows: 30, viewportGeneration: 0)),
        (#"{"type":"paste","id":2,"sessionID":"session","text":"hi"}"#,
         .paste(id: 2, sessionID: RemoteSamples.session, text: "hi", submit: true)),
        // Older clients list no capabilities: the host reads them as not knowing its queue.
        (#"{"type":"hello","id":1,"token":"t","clientName":"old","protocolVersion":1}"#,
         .hello(id: 1, token: "t", clientName: "old", protocolVersion: 1, capabilities: nil)),
    ])
    func olderClientShapesDecodeWithDefaults(json: String, expected: RemoteRequest) throws {
        #expect(try Wire.decode(RemoteRequest.self, json) == expected)
    }

    @Test func unknownRequestKindsAreRejected() {
        #expect(throws: DecodingError.self) { try Wire.decode(RemoteRequest.self, #"{"type":"launchMissiles","id":1}"#) }
    }

    @Test func inputBytesTravelAsBase64() throws {
        let object = try Wire.object(RemoteRequest.input(sessionID: S.session, data: Data([0xFF, 0x00])))
        #expect(object["data"] as? String == "/wA=")
    }
}

@Suite("Remote replies")
struct RemoteReplyTests {
    typealias S = RemoteSamples

    static func caseName(_ reply: RemoteReply) -> String {
        switch reply {
        case .nativeThread, .uploadResult, .creationOptions, .helloOk, .agentResult, .ok, .paneOpened, .error,
             .state, .stateChanged, .attached, .output, .sessionExited, .dirListing, .models, .spaceAdded,
             .agentCreated, .automationResult, .instructions, .suggestions, .hostSettings, .skills, .design, .designChanged,
             .capabilitiesChanged:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 25

    static let samples: [RemoteReply] = [
        .nativeThread(id: 80, result: .accepted(operationID: S.op)),
        .uploadResult(id: 51, result: .complete(path: "/host/private/image.png")),
        .creationOptions(id: 52, options: RemoteCreationOptions(base: "origin/main", note: "cached", fetchFirst: false,
                                                                model: "host/model", thinking: .high)),
        .helloOk(id: 1, protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities),
        .agentResult(id: 60, result: .ok),
        .ok(id: 12),
        .paneOpened(id: 14, paneID: S.pane),
        .error(id: 2, code: "unauthorized", message: "bad token"),
        .state(id: 3, state: S.state),
        .stateChanged(state: ShepherdState()),
        .attached(id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 80, rows: 24, viewportGeneration: 2)),
        .output(sessionID: S.session, data: Data("screen bytes \u{1B}[31m".utf8)),
        .sessionExited(sessionID: S.session, code: 0),
        .dirListing(id: 8, path: "/Users/demo", parent: "/Users", dirs: ["Developer", "Documents"]),
        .models(id: 10, models: ["anthropic/claude-4", "openai/gpt-5"], defaultModel: "anthropic/claude-4",
                withoutThinking: ["openai/gpt-5"]),
        .models(id: 12, models: ["anthropic/claude-4", "openai/gpt-5"], defaultModel: nil, withoutThinking: [],
                thinkingLevels: ["anthropic/claude-4": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]]),
        .spaceAdded(id: 6, spaceID: S.space),
        .agentCreated(id: 7, agentID: S.agent),
        .automationResult(id: 22, result: .runs(S.runs)),
        .instructions(id: 24, snapshot: S.instructions),
        .suggestions(id: 26, snapshot: S.suggestions),
        .hostSettings(id: 28, settings: S.hostSettings),
        .skills(id: 30, result: .skills(S.skills)),
        .design(id: 32, result: .ok),
        .designChanged(designID: RemoteDesignSamples.design, revision: 8, commentsRevision: 2),
        .capabilitiesChanged(capabilities: [RemoteProtocol.designsCapability]),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ reply: RemoteReply) throws {
        #expect(try Wire.object(reply)["type"] as? String == Self.caseName(reply))
    }

    @Test(arguments: RemoteSamples.agentResults)
    func everyAgentResultRoundTrips(_ result: RemoteAgentResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.agentResult(id: 1, result: result)) == .agentResult(id: 1, result: result))
    }

    @Test(arguments: RemoteSamples.automationResults)
    func everyAutomationResultRoundTrips(_ result: RemoteAutomationResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.automationResult(id: 1, result: result)) == .automationResult(id: 1, result: result))
    }

    @Test(arguments: RemoteSamples.skillsResults)
    func everySkillsResultRoundTrips(_ result: RemoteSkillsResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.skills(id: 1, result: result)) == .skills(id: 1, result: result))
    }

    /// pi's skills from a newer host: a kind of origin this client doesn't know reads as pi's
    /// settings, and missing lists read as empty.
    @Test func piSkillsFromANewerHostDecodeWithDefaults() throws {
        let pi = try Wire.decode(PiSkills.self, #"{"skills":[{"name":"x","summary":"","path":"~/x/SKILL.md","origin":"extension","invocation":"automatic"}]}"#)
        #expect(pi.agentDirectory == "~/.pi/agent")
        #expect(pi.skills.map(\.origin) == [.settingsPath])
        #expect(pi.shadowedInstalled.isEmpty && pi.problem == nil)
        #expect(pi.skills[0].isUsed)
    }

    /// A host that predates Update automatically sends no `autoUpdate`: it reads as off.
    @Test func aSkillsSnapshotWithoutAutoUpdateReadsAsOff() throws {
        let snapshot = try Wire.decode(SkillsSnapshot.self, #"{"directory":"~/.agents/skills","skills":[]}"#)
        #expect(snapshot == SkillsSnapshot(directory: "~/.agents/skills"))
        #expect(snapshot.pi == nil)
        #expect(RemoteSamples.skills.skill("pdf")?.update?.filesChanged == 3)
        #expect(RemoteSamples.skills.skill("nothing") == nil)
    }

    @Test func aSnapshotNamesEachFilesPathAndLastSave() {
        let snapshot = RemoteSamples.instructions
        #expect(snapshot[.agents] == "- Prefer small commits.\n")
        #expect(snapshot[.appendSystem] == "Never force-push.\n")
        #expect(snapshot.path(of: .agents) == "~/Library/Application Support/Shepherd/instructions/AGENTS.md")
        #expect(snapshot.lastSaved(.appendSystem) == 1_700_000_100)
        #expect(InstructionsSnapshot(directory: "/i/").path(of: .appendSystem) == "/i/APPEND_SYSTEM.md")
        #expect(InstructionsSnapshot(directory: "/i").lastSaved(.agents) == nil)
    }

    /// A change applies to the one setting it names; a bundled extension the host doesn't have
    /// changes nothing.
    @Test func aHostSettingChangeAppliesToItsSettingAlone() {
        var settings = RemoteSamples.hostSettings
        settings.apply(.bundledExtension(id: "review", on: true))
        #expect(settings.bundledExtensions.map(\.on) == [true, true])
        settings.apply(.bundledExtension(id: "nothing", on: false))
        #expect(settings.bundledExtensions.map(\.on) == [true, true])
        settings.apply(.defaultModel(nil))
        #expect(settings.defaultModel == nil)
        settings.apply(.mergeMethod(.merge))
        #expect(settings.mergeMethod == .merge)
        var expected = RemoteSamples.hostSettings
        expected.bundledExtensions[1].on = true
        expected.defaultModel = nil
        expected.mergeMethod = .merge
        #expect(settings == expected)
    }

    /// An agent may suggest only while the experiment is on, only when its kind learns, and only
    /// for the files the user allows, in file order.
    @Test func suggestionSettingsSayWhichFilesAnAgentMaySuggestFor() {
        var settings = SuggestedInstructionsSettings()
        #expect(settings.files(for: .thread).isEmpty)
        settings.enabled = true
        #expect(settings.files(for: .thread) == [.agents])
        settings.files = [.appendSystem, .agents]
        #expect(settings.files(for: .automation) == [.agents, .appendSystem])
        settings.sources = [.thread]
        #expect(settings.files(for: .automation).isEmpty)
    }

    /// A run a newer host reports with a result this build does not know reads as stopped;
    /// optional times and the agent may be absent.
    @Test func aRunFromANewerHostDecodesLeniently() throws {
        let json = #"{"id":"00000000-0000-0000-0000-00000000000A","startedAt":5,"result":"skipped"}"#
        #expect(try Wire.decode(AutomationRun.self, json)
            == AutomationRun(id: S.op, startedAt: 5, result: .stopped))
    }

    @Test(arguments: AutomationRunResult.allCases)
    func everyRunResultRoundTrips(_ result: AutomationRunResult) throws {
        #expect(try Wire.roundTrip([result]) == [result])
    }

    @Test(arguments: [
        (AutomationRun(startedAt: 10, settledAt: 53, endedAt: 100, result: .finished), 43.0 as Double?),
        (AutomationRun(startedAt: 10, endedAt: 25, result: .stopped), 15),
        (AutomationRun(startedAt: 10, result: .running), nil),
    ])
    func aRunLastsUntilItsFirstFinishedTurnOrItsEnd(_ run: AutomationRun, _ duration: Double?) {
        #expect(run.duration == duration)
    }

    @Test(arguments: [RemoteUploadResult.ready(uploadID: RemoteSamples.op), .complete(path: "/p")])
    func everyUploadResultRoundTrips(_ result: RemoteUploadResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.uploadResult(id: 1, result: result)) == .uploadResult(id: 1, result: result))
    }

    @Test(arguments: [
        RemoteReply.sessionExited(sessionID: RemoteSamples.session, code: nil),
        .dirListing(id: 9, path: "/", parent: nil, dirs: []),
        .models(id: 11, models: [], defaultModel: nil),
    ])
    func absentOptionalsRoundTrip(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test func sessionExitCodeTravelsUnderExitCode() throws {
        #expect(try Wire.object(RemoteReply.sessionExited(sessionID: S.session, code: 3))["exitCode"] as? Int == 3)
    }

    @Test func aHelloOkWithoutCapabilitiesMeansNone() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"helloOk","id":1,"protocolVersion":1}"#)
            == .helloOk(id: 1, protocolVersion: 1, capabilities: []))
    }

    /// A host from before `withoutThinking` does not say which models take no thinking level.
    @Test func aModelListingFromAnOlderHostSaysNothingAboutThinking() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"models","id":4,"models":["a/b"],"defaultModel":"a/b"}"#)
            == .models(id: 4, models: ["a/b"], defaultModel: "a/b", withoutThinking: nil))
    }

    /// The thinking control goes only with a model that takes a level; a blank model is the
    /// default, and a model the listing says nothing about (or an older host's) keeps it.
    @Test(arguments: [
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), "qa/plain" as String?, false),
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), " qa/plain ", false),
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), "qa/deep", true),
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), nil, false),
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), "", false),
        (ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]), "typed/other", true),
        (ModelListing(models: ["qa/plain"], defaultModel: nil, withoutThinking: ["qa/plain"]), nil, true),
        (ModelListing(models: ["qa/plain"], defaultModel: "qa/plain", withoutThinking: nil), "qa/plain", true),
    ])
    func onlyAModelThatTakesAThinkingLevelOffersIt(_ listing: ModelListing, _ model: String?, _ expected: Bool) {
        #expect(listing.takesThinking(model) == expected)
    }

    /// Before a session starts, a reasoning model is offered the standard levels, or the ones
    /// the host's configuration names; a model without reasoning none.
    @Test(arguments: [
        ("qa/deep" as String?, ["off", "minimal", "low", "medium", "high"]),
        ("qa/max", ["off", "minimal", "low", "medium", "high", "xhigh", "max"]),
        ("qa/plain", []),
        (nil, []),
        ("typed/other", ["off", "minimal", "low", "medium", "high"]),
    ])
    func aModelIsOfferedTheLevelsItTakes(_ model: String?, _ expected: [String]) {
        let listing = ModelListing(models: ["qa/plain", "qa/deep", "qa/max"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"],
                                   thinkingLevels: ["qa/max": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]])
        #expect(listing.offeredThinkingLevels(model).map(\.rawValue) == expected)
    }

    /// A host that does not know a level a newer client sends creates the agent at its default.
    @Test func aCreateAgentWithAnUnknownLevelDecodesWithoutOne() throws {
        let request = try Wire.decode(RemoteRequest.self, #"{"type":"createAgent","id":7,"spaceID":"space","thinking":"ultra"}"#)
        #expect(request == .createAgent(id: 7, spaceID: S.space, cwd: nil, model: nil, thinking: nil, initialPrompt: nil))
    }

    /// Older hosts replied with a bare session id; the attachment's grid is then unknown (0).
    @Test func anAttachedReplyFromAnOlderHostDecodesWithAZeroGrid() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"attached","id":5,"sessionID":"session"}"#)
            == .attached(id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 0, rows: 0, viewportGeneration: 0)))
    }

    @Test func attachedStillCarriesTheBareSessionIDForOlderClients() throws {
        let object = try Wire.object(RemoteReply.attached(
            id: 5, attachment: RemoteAttachment(sessionID: S.session, cols: 1, rows: 2, viewportGeneration: 3)
        ))
        #expect(object["sessionID"] as? String == "session")
    }

    /// A host from before `newsSequence` counts every read of output, so its tabs' news is that.
    @Test func aTerminalFromAnOlderHostTakesItsOutputSequenceAsNews() throws {
        let row = try Wire.decode(RemoteTerminalActivity.self,
                                  #"{"paneID":"pane","sessionID":"session","process":"zsh","outputSequence":7}"#)
        #expect(row.newsSequence == nil && row.news == 7)
        let newer = RemoteTerminalActivity(paneID: S.pane, sessionID: S.session, process: "zsh", command: nil,
                                           outputSequence: 7, newsSequence: 2)
        #expect(newer.news == 2)
    }

    @Test func worktreeCheckStatePassesOnlyWhenPassed() {
        #expect(RemoteWorktreeCheckState.pass("ok").passed)
        for state in [RemoteWorktreeCheckState.fail("x"), .pending, .checking] { #expect(!state.passed) }
    }
}

@Suite("Remote protocol constants")
struct RemoteProtocolConstantTests {
    @Test func versionIsOne() {
        #expect(RemoteProtocol.version == 1)
    }

    @Test func hostAdvertisesEveryNamedCapabilityOnce() {
        let named = [
            RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeThreadV2Capability,
            RemoteProtocol.nativeThreadStartingCapability, RemoteProtocol.nativeQueueCapability,
            RemoteProtocol.pasteCapability, RemoteProtocol.paneControlCapability,
            RemoteProtocol.agentActionsCapability, RemoteProtocol.agentInspectionCapability,
            RemoteProtocol.worktreeActionsCapability, RemoteProtocol.worktreeSetupCapability,
            RemoteProtocol.uploadCapability, RemoteProtocol.creationOptionsCapability,
            RemoteProtocol.automationsCapability,
            RemoteProtocol.terminalActivityCapability,
            RemoteProtocol.reviewCommitCapability,
            RemoteProtocol.thinkingLevelsCapability,
            RemoteProtocol.changesCapability,
            RemoteProtocol.nativeContextCapability,
            RemoteProtocol.createAgentImagesCapability,
            RemoteProtocol.instructionsCapability, RemoteProtocol.suggestionsCapability,
            RemoteProtocol.hostSettingsCapability, RemoteProtocol.skillsCapability,
            RemoteProtocol.piSkillsCapability,
            RemoteProtocol.terminalControlCapability,
            RemoteProtocol.designContextCapability,
            // Offered only while the host's Design tool is on (SessionServer.setDesignsServed).
            RemoteProtocol.designsCapability,
        ]
        #expect(Set(RemoteProtocol.capabilities) == Set(named))
        #expect(RemoteProtocol.capabilities.count == named.count)
    }

    /// Capability strings are negotiated with older peers; they must never be renamed.
    @Test func capabilityStringsAreStable() {
        #expect(RemoteProtocol.nativeThreadCapability == "native.thread.v1")
        #expect(RemoteProtocol.nativeThreadV2Capability == "native.thread.v2")
        #expect(RemoteProtocol.changesCapability == "changes.v1")
        #expect(RemoteProtocol.nativeThreadStartingCapability == "native.thread.starting.v1")
        #expect(RemoteProtocol.nativeQueueCapability == "native.queue.v1")
        #expect(RemoteProtocol.pasteCapability == "session.paste.v1")
        #expect(RemoteProtocol.paneControlCapability == "pane.control.v1")
        #expect(RemoteProtocol.uploadCapability == "session.upload.v1")
        #expect(RemoteProtocol.terminalActivityCapability == "terminal.activity.v1")
        #expect(RemoteProtocol.reviewCommitCapability == "review.commit.v1")
        #expect(RemoteProtocol.automationsCapability == "automations.v1")
        #expect(RemoteProtocol.thinkingLevelsCapability == "thinking.levels.v1")
        #expect(RemoteProtocol.nativeContextCapability == "native.context.v1")
        #expect(RemoteProtocol.createAgentImagesCapability == "agent.create.images.v1")
        #expect(RemoteProtocol.instructionsCapability == "instructions.v1")
        #expect(RemoteProtocol.suggestionsCapability == "suggestions.v1")
        #expect(RemoteProtocol.hostSettingsCapability == "hostSettings.v1")
        #expect(RemoteProtocol.skillsCapability == "skills.v1")
        #expect(RemoteProtocol.piSkillsCapability == "skills.pi.v1")
        #expect(RemoteProtocol.designContextCapability == "design.context.v1")
        #expect(RemoteProtocol.designsCapability == "designs.v1")
    }

    /// Commit info from a host that sends only some fields still reads, with defaults.
    @Test func commitTypesDecodeWithDefaultsForMissingFields() throws {
        let info = try JSONDecoder().decode(RemoteCommitInfo.self, from: Data(#"{"files":[{"path":"a.swift"}]}"#.utf8))
        #expect(info.files == [RemoteCommitFile(path: "a.swift", status: "M", added: 0, removed: 0, fingerprint: "")])
        #expect(info.head.isEmpty && info.branch == nil && !info.draftsMessage && !info.agentWorking && info.blocked == nil)
        let options = try JSONDecoder().decode(RemoteCommitOptions.self, from: Data(#"{"head":"h","files":[],"title":"t"}"#.utf8))
        #expect(options.push == .none && options.body.isEmpty && options.newBranch == nil && !options.confirmedWhileWorking)
    }

    @Test(arguments: [
        (RemoteCommitFile(path: "a", status: "M", added: 0, removed: 0, fingerprint: ""), ["a"]),
        (RemoteCommitFile(path: "b", oldPath: "a", status: "R", added: 0, removed: 0, fingerprint: ""), ["a", "b"]),
        (RemoteCommitFile(path: "a", oldPath: "a", status: "M", added: 0, removed: 0, fingerprint: ""), ["a"]),
    ])
    func aCommitFileTakesARenamesOldPathToo(_ file: RemoteCommitFile, _ paths: [String]) {
        #expect(file.paths == paths)
    }

    @Test(arguments: [
        (RemoteCommitInfo(repository: "", branch: "main", head: "", upstream: nil, pushRemote: "origin", defaultBranch: "main", files: [],
                          title: "", body: "", draftsMessage: false, agentWorking: false, blocked: nil), true),
        (RemoteCommitInfo(repository: "", branch: "feat", head: "", upstream: nil, pushRemote: "origin", defaultBranch: "main", files: [],
                          title: "", body: "", draftsMessage: false, agentWorking: false, blocked: nil), false),
        (RemoteCommitInfo(repository: "", branch: nil, head: "", upstream: nil, pushRemote: nil, defaultBranch: nil, files: [],
                          title: "", body: "", draftsMessage: false, agentWorking: false, blocked: nil), false),
    ])
    func onTheDefaultBranchOnlyWhenTheBranchIsIt(_ info: RemoteCommitInfo, _ expected: Bool) {
        #expect(info.onDefaultBranch == expected)
    }

    @Test func aFullUploadChunkFitsInOneFrameAfterBase64() throws {
        let chunk = RemoteRequest.upload(id: Int.max, action: .chunk(
            uploadID: UUID(), data: Data(repeating: 0xAB, count: RemoteProtocol.uploadChunkBytes)
        ))
        #expect(try NDJSON.encode(chunk).count - 1 <= NDJSON.maxPayloadBytes)
        #expect(RemoteProtocol.uploadMaxBytes % RemoteProtocol.uploadChunkBytes == 0)
    }

    @Test func composedInputIsOneBracketedPasteWithAnOptionalReturn() {
        #expect(RemoteProtocol.composedInput(text: "one\ntwo", submit: true) == Data("\u{1B}[200~one\ntwo\u{1B}[201~\r".utf8))
        #expect(RemoteProtocol.composedInput(text: "draft", submit: false) == Data("\u{1B}[200~draft\u{1B}[201~".utf8))
        #expect(RemoteProtocol.composedInput(text: "", submit: false) == Data("\u{1B}[200~\u{1B}[201~".utf8))
    }
}
