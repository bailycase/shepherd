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

    static let fleetHost = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let fleetHash = String(repeating: "ab", count: 32)
    static let fleetIntroduction = FleetIntroduction(hostID: fleetHost, name: "MacBook Pro", myTokenHash: fleetHash, port: 7434)
    static let fleetMember = FleetMember(hostID: fleetHost, name: "Mac mini", host: "192.168.1.40", port: 7434)
    static let fleetDevice = FleetDeviceIntroduction(deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, name: "iPhone", kind: .iphone, tokenHash: fleetHash)
    static let fleetDeviceEntries = [
        FleetDeviceEntry(deviceID: fleetDevice.deviceID, name: "iPhone", kind: .iphone, tokenHash: fleetHash, pairedAt: 1_790_000_000_000),
        FleetDeviceEntry(deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!, name: "iPad", kind: .ipad, tokenHash: nil,
                         pairedAt: 1_790_000_000_500, revokedAt: 1_790_000_001_000),
    ]
    static let fleetDevicesSnapshot = FleetDevicesSnapshot(
        devices: [FleetDeviceStatus(deviceID: fleetDevice.deviceID, name: "iPhone", kind: .iphone, pairedAt: 1_790_000_000_000, connected: true, lastSeen: 1_790_000_002_000),
                  FleetDeviceStatus(deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!, name: "Mac mini", kind: .macApp, pairedAt: 1_790_000_000_100, connected: false)],
        code: FleetJoinStatus(expiresAt: 1_790_000_300_000, attemptsLeft: 5),
        sharedToken: FleetSharedTokenStatus(retired: false, waiting: [FleetLegacyClient(id: "Shepherd iOS@192.168.1.31", name: "Shepherd iOS", lastSeen: 1_790_000_002_000)], switched: 2))
    static let fleetSnapshot = FleetSnapshot(
        enabled: true, hostID: fleetHost, name: "MacBook Pro", build: "412", addresses: ["192.168.1.20"], port: 7434, advertising: true,
        peers: [FleetPeerStatus(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!, name: "Mac mini", host: "192.168.1.40", port: 7434,
                                pairedAt: 1_790_000_000_000, link: .connected),
                FleetPeerStatus(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!, name: "Mac Studio", pairedAt: 1_790_000_001_000,
                                link: .offline, lastSeen: 1_790_000_002_000)],
        join: FleetJoinStatus(expiresAt: 1_790_000_300_000, attemptsLeft: 4),
        sync: FleetSyncStatus(peers: [.init(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!, name: "Mac mini", state: .inSync),
                                      .init(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!, name: "Mac Studio", state: .offline)],
                              notice: "Replaced AGENTS.md with Mac mini's. The old copy is in its history."),
        macs: [FleetMacState(hostID: fleetHost, sample: fleetSample, sampleAge: 2.5, readiness: fleetReadiness),
               FleetMacState(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!)])
    static let fleetSample = FleetPressureSample(cpuUtilization: 0.72, cpuCount: 12, totalMemoryBytes: 38_654_705_664, availableMemoryBytes: 10_093_173_145,
                                                 thermal: .fair, onBattery: true, batteryPercent: 41, activeAgents: 3, reserved: 1)
    static let fleetIndexStatus = FleetIndexStatus(indexing: true, repos: [
        FleetIndexStatus.Repo(repo: "github.com/acme/web", name: "acme-web", files: 20_001, ready: true),
        FleetIndexStatus.Repo(repo: "space:2F1D", name: "orders-svc", files: 412, ready: false),
        FleetIndexStatus.Repo(repo: "space:90AB", name: "monorepo", files: 0, ready: false, tooLarge: true)])
    static let fleetManifestPrefixes = [FleetHashPrefix(hi: 0x0123_4567_89AB_CDEF, lo: 0xFEDC_BA98_7654_3210), FleetHashPrefix(hi: 1, lo: 2)]
    static let fleetManifestFull = FleetRepoManifestUpdate(repo: "github.com/acme/web", kind: .full, generation: 7, seq: 0,
                                                           added: FleetHashPrefix.pack(fleetManifestPrefixes), part: 0, parts: 2,
                                                           digest: FleetManifest(fleetManifestPrefixes).digest)
    static let fleetManifestDelta = FleetRepoManifestUpdate(repo: "space:2F1D", kind: .delta, generation: 7, seq: 3,
                                                            added: FleetHashPrefix.pack(fleetManifestPrefixes.prefix(1)),
                                                            removed: FleetHashPrefix.pack(fleetManifestPrefixes.suffix(1)), digest: .empty)
    static let fleetManifestHead = FleetRepoManifestUpdate(repo: "github.com/acme/web", kind: .head, generation: 7, seq: 3,
                                                           digest: FleetManifest(fleetManifestPrefixes).digest)
    static let fleetReadiness = FleetReadinessReport(model: "MacBook Pro", chip: "M4 Pro",
                                                     missing: [FleetMissingTool(kind: .binary, name: "muse"), FleetMissingTool(kind: .xcode)],
                                                     repos: ["acme-web", "payments-api"], repoKeys: ["github.com/acme/payments-api", "github.com/acme/web"], noXcode: true)
    static let dispatchID = UUID(uuidString: "5D4F1F6E-2B0C-4C86-9E43-7F5B7E0A9C11")!
    static let dispatchCreate = FleetDispatchCreate(
        dispatchID: dispatchID, task: "Fix the flaky payment test.", title: "Fix flaky payment test", repoKey: "github.com/acme/payments-api",
        commitSHA: String(repeating: "a", count: 40), subdir: "services/api", branch: "fleet/fix-flaky-payment-test", model: "acme/model-a", thinking: "high",
        from: FleetDispatchSender(hostID: fleetHost, hostName: "MacBook Pro", agentID: AgentID(rawValue: "a1"), agentTitle: "Ship checkout"))
    static let snapshotHash = FleetHash(of: Data("made-up contents".utf8))
    static let snapshotHeader = FleetSnapshotHeader(commit: String(repeating: "a", count: 40), rootHash: snapshotHash, digest: FleetHash(of: Data("digest".utf8)),
                                                    files: 3, directories: 1, deletions: 1, parts: 1, fileCount: 6_020, bytes: 2_800_000,
                                                    bundle: FleetBlobRef(hash: FleetHash(of: Data("bundle".utf8)), size: 4_096))
    /// The repository itself in a bundle, for a Mac that has no checkout and couldn't clone it from origin.
    static let repoBundleHeader = FleetSnapshotHeader(commit: String(repeating: "a", count: 40), rootHash: snapshotHash, digest: FleetHash(of: Data("digest".utf8)),
                                                      files: 0, directories: 0, deletions: 0, parts: 0, fileCount: 0, bytes: 9_000_000,
                                                      bundle: FleetBlobRef(hash: FleetHash(of: Data("repo".utf8)), size: 9_000_000), repoBundle: true)
    /// Only the repository (the dispatch carries no edits): no manifest, no digest.
    static let repoOnlyHeader = FleetSnapshotHeader(commit: String(repeating: "a", count: 40), rootHash: FleetHash(a: 0, b: 0, c: 0, d: 0), digest: FleetHash(a: 0, b: 0, c: 0, d: 0),
                                                    files: 0, directories: 0, deletions: 0, parts: 0, fileCount: 0, bytes: 9_000_000,
                                                    bundle: FleetBlobRef(hash: FleetHash(of: Data("repo".utf8)), size: 9_000_000), repoBundle: true, repoOnly: true)
    static let dispatchCreateCloning = FleetDispatchCreate(
        dispatchID: dispatchID, task: "Profile the orders import.", title: "Profile the orders import", repoKey: "github.com/acme/orders-svc",
        commitSHA: String(repeating: "a", count: 40), from: FleetDispatchSender(hostID: fleetHost, hostName: "MacBook Pro", agentTitle: "Speed up checkout CI"),
        snapshot: repoBundleHeader,
        repo: FleetRepoSource(origin: "https://github.com/acme/orders-svc.git", spaceID: SpaceID(rawValue: "S1"), name: "orders-svc", worktreeBase: "origin/main"))
    static let dispatchCreateWithSnapshot = FleetDispatchCreate(
        dispatchID: dispatchID, task: "Fix the flaky payment test.", title: "Fix flaky payment test", repoKey: "github.com/acme/payments-api",
        commitSHA: String(repeating: "a", count: 40), from: FleetDispatchSender(hostID: fleetHost, hostName: "MacBook Pro", agentTitle: "Ship checkout"),
        snapshot: snapshotHeader)
    static let snapshotPart = FleetSnapshotPart(
        index: 0, files: [FleetSnapshotFile(path: "src/app.ts", kind: .file, hash: snapshotHash, size: 42), FleetSnapshotFile(path: "node_modules/.bin/tool", kind: .symlink, hash: snapshotHash, size: 22)],
        directories: [FleetSnapshotDirectory(path: "node_modules", hash: snapshotHash, files: 6_000, bytes: 215_715_200)], deletions: ["old.txt"], wantsNeeds: true)
    static let blobChunk = FleetBlobChunk(hash: snapshotHash, size: 10, offset: 4, data: Data([1, 2, 3, 4, 5, 6]))
    static let dispatchRecord = FleetDispatchRecord(
        id: dispatchID, parentAgentID: AgentID(rawValue: "a1"), parentHostID: fleetHost, parentHostName: "MacBook Pro", parentTitle: "Ship checkout",
        targetHostID: UUID(uuidString: "0B8C1D52-3B5C-4F0A-8F56-1B7C6C9D5E22"), targetHostName: "Mac mini", state: .running, title: "Fix flaky payment test",
        task: "Fix the flaky payment test.", repoKey: "github.com/acme/payments-api", commitSHA: String(repeating: "a", count: 40),
        branch: "fleet/fix-flaky-payment-test", reasonCodes: [FleetPlacementReason(.mostRoom, ratio: 3.4)], remoteAgentID: AgentID(rawValue: "a9"),
        activity: "working", createdAt: 1_790_000_000_000, updatedAt: 1_790_000_001_000)
    /// A dispatch whose Mac is cloning the repository for it, and where the sender's space and origin were kept for that.
    static let dispatchRecordCloning = FleetDispatchRecord(
        id: dispatchID, parentAgentID: AgentID(rawValue: "a1"), parentHostID: fleetHost, parentHostName: "MacBook Pro", parentTitle: "Speed up checkout CI",
        targetHostID: UUID(uuidString: "0B8C1D52-3B5C-4F0A-8F56-1B7C6C9D5E22"), targetHostName: "Mac Studio", state: .preparing, title: "Profile the orders import",
        task: "Profile the orders import.", repoKey: "github.com/acme/orders-svc", commitSHA: String(repeating: "a", count: 40),
        reasonCodes: [FleetPlacementReason(.mostRoom, ratio: 3.4), FleetPlacementReason(.willClone)], activity: "cloning orders-svc: receiving objects",
        spaceID: SpaceID(rawValue: "S1"), origin: "https://github.com/acme/orders-svc.git",
        clone: FleetCloneProgress(name: "orders-svc", source: "github.com/acme/orders-svc", phase: "receiving objects", fraction: 0.37),
        createdAt: 1_790_000_000_000, updatedAt: 1_790_000_001_000)
    static let branchFacts = FleetBranchFacts(branch: "fleet/fix-flaky-payment-test", head: String(repeating: "b", count: 40), ahead: 2, pushed: true,
                                              filesChanged: 3, insertions: 10, deletions: 2)
    static let fleetOp = FleetOp(mac: fleetHost, seq: 3, hlc: FleetHLC(wallMs: 1_790_000_000_123, counter: 2), unit: "instruction:AGENTS.md",
                                 change: .blob(hash: String(repeating: "cd", count: 32), size: 424), seed: true, macName: "MacBook Pro")
    static let fleetSettingOp = FleetOp(mac: fleetHost, seq: 4, hlc: FleetHLC(wallMs: 1_790_000_000_200), unit: "setting:host.defaultModel",
                                        change: .value("\"acme/model\""))
    /// A sign-in, as the fleet carries it: inline, pi's own JSON for one provider (a made up token).
    static let fleetCredentialOp = FleetOp(mac: fleetHost, seq: 5, hlc: FleetHLC(wallMs: 1_790_000_000_300), unit: "credential:acme-ai",
                                           change: .value(#"{"access":"fake-access","expires":1790003600000,"refresh":"fake-refresh","type":"oauth"}"#))
    static let routeReport = FleetRouteReport(port: 7434, routes: [
        FleetReportedRoute(host: "10.77.20.10", kind: .lan), FleetReportedRoute(host: "mac-mini.local", kind: .hostname),
        FleetReportedRoute(host: "100.101.102.103", kind: .tailscale), FleetReportedRoute(host: "10.8.0.4", kind: .vpn),
    ])
    static let fleetVector = FleetVersionVector([fleetHost: 4, UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!: 9])

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
        let parent = Space(name: "parent", path: "/elsewhere")
        let space = Space(name: "demo", path: "/tmp/demo", parentID: parent.id, parentIsExplicit: true)
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        // The live fields ride the wire (state.json drops `waitingOn` and `waitingReason`; a remote
        // client needs them).
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .blocked,
                          lastActiveAt: 1_790_000_000_000, waitingOn: "Which base?", waitingReason: "base?")
        return ShepherdState(spaces: [space, parent], tabs: [tab], agents: [agent])
    }()

    static let agentQueries: [RemoteAgentQuery] = [
        .deleteKeepingWorktree,
        .worktreeInfo,
        .setWorktree(branch: "feat/card", base: nil),
        .setWorktree(branch: nil, base: "release"),
        .moveToCheckout(path: "/tmp/acme-web-feat", branch: "feat/card"),
        .deleteWorktree(operationID: op, confirmedWarning: "dirty", fingerprint: "hash"),
        .deleteWorktree(operationID: op, confirmedWarning: nil),
        .worktreeStatus(operationID: op),
        .review(pullRequest: true),
        .reviewPane(paneID: pane, pullRequest: false),
        .reviewPane(paneID: pane),
        .finishReview(paneID: pane, text: "feedback"),
        .finishReview(paneID: pane, text: nil),
        .children,
        .pullRequest,
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
        .changesOverview(),
        .changesOverview(cwd: "/tmp/acme-web"),
        .changesList(scope: .uncommitted, options: ChangesOptions(), cwd: "/tmp/acme-web"),
        .changesFile(revision: revision, path: "a.go", oldPath: nil, options: ChangesOptions(), cwd: "/tmp/acme-web"),
        .changesBranches(cwd: "/tmp/acme-web"),
        .changesPatch(revision: revision, options: ChangesOptions(), cwd: "/tmp/acme-web"),
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
        .changesRevertFile(revision: revision, path: "ledger/outbox.go", oldPath: nil),
        .changesRevertFile(revision: revision, path: "new name.go", oldPath: "old.go"),
        .changesWriteBegan(span: op, paths: ["/Users/me/acme-web/src/Checkout.tsx"]),
        .changesWriteBegan(span: op, paths: nil),
        .changesWriteEnded(span: op),
        .changesBranches(),
        .changesPatch(revision: revision, options: ChangesOptions()),
        .changesUndoTurn(turnID: op),
        .changesRedoTurn(turnID: op),
        .devServers,
        .files(path: "", showHidden: false),
        .files(path: "Sources/App Intents", showHidden: true),
        .fileRead(path: "Widgets/NeedsYouWidget.swift"),
        .fileWrite(path: "src/Checkout.tsx", text: "let pay = \"ok\"\n", expected: ""),
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
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: "3 uncommitted files", fingerprint: "abc")),
        .worktreeInfo(RemoteWorktreeInfo(path: "/r", branch: "worktree/x", warning: nil)),
        .worktreeOperation(RemoteWorktreeOperation(id: op, finished: true, error: "failed", progress: ["push failed"], prURL: nil)),
        .worktreeOperation(RemoteWorktreeOperation(id: op, prURL: "https://example.invalid/pr/1")),
        .review(files: Data("[]".utf8), reference: "origin/main"),
        .children([ChildRun(runID: "run", label: "child", state: "running")]),
        .inspector(tab),
        .inspectorFocus(pane),
        .search(snippet: "matched text"),
        .search(snippet: nil),
        .pullRequest(ThreadPullRequest(ref: ForgeItemRef(kind: .pullRequest, repo: "acme/web", number: 31), state: .merged,
                                       headRefName: "agent/refund-events", headRefOid: "3f2a91c")),
        .pullRequest(nil),
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
        .devServers([DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: "/host/repo", manifest: "package.json", port: 5173),
                     DevServer(script: "start", command: "npm start", packageName: nil, directory: "/host/repo/apps/api",
                               manifest: "apps/api/package.json", port: nil)]),
        .devServers([]),
        .files(ThreadFileListing(entries: [ThreadFileEntry(name: "Widgets", kind: .directory),
                                           ThreadFileEntry(name: "render \"v2\".py", kind: .file, size: 2_048, symlink: true),
                                           ThreadFileEntry(name: "locked", kind: .file, size: 0, error: "Permission denied")],
                                 truncated: true)),
        .files(ThreadFileListing(entries: [])),
        .fileData(Data("let x = 1\n".utf8)),
        .fileWrite(.saved),
        .fileWrite(.changed("let x = 2\n")),
        .fileWrite(.failed("No such file or folder")),
    ]

    static let automation = AutomationID(rawValue: "automation")
    static let draft = RemoteAutomationDraft(name: "Nightly \"dry\" run", prompt: "Run every migration\nReport", cwd: "/host/repo",
                                             enabled: false)
    static let automationRequests: [RemoteAutomationRequest] = [
        .setEnabled(enabled: true), .setEnabled(enabled: false), .run, .stop, .runs,
        .create(draft: draft), .update(draft: draft), .delete,
        .create(draft: RemoteAutomationDraft(name: "loop", prompt: "p", cwd: "/r", enabled: true, settings: AutomationSettings(
            trigger: .github([GitHubTrigger(repo: "acme/app", events: [.issueLabeled, .pullRequestMerged], labels: ["shepherd"])]),
            workspace: .worktree, limits: AutomationLimits(maxConcurrent: 2, maxPerDay: 20)))),
        .update(draft: RemoteAutomationDraft(name: "unlimited", prompt: "p", cwd: "/r", enabled: true,
            settings: AutomationSettings(limits: AutomationLimits(maxConcurrent: 0, maxPerDay: 20)))),
        .update(draft: RemoteAutomationDraft(name: "no daily limit", prompt: "p", cwd: "/r", enabled: true,
            settings: AutomationSettings(limits: AutomationLimits(maxConcurrent: 2, maxPerDay: 0)))),
        .status, .pause, .resume, .runEvent(eventID: "acme/app#1:opened"), .dismissEvent(eventID: "schedule:5"),
        .markRead(runID: op), .setAllPaused(paused: true),
        .setRunPullRequest(agentID: agent, url: "https://github.com/acme/app/pull/12"),
    ]
    static let runs: [AutomationRun] = [
        AutomationRun(id: op, startedAt: 1_700_000_000, settledAt: 1_700_000_043, endedAt: 1_700_000_100, result: .finished),
        AutomationRun(id: op, startedAt: 1_700_000_200, result: .needsYou, agentID: agent),
        AutomationRun(id: op, startedAt: 1_700_000_300, endedAt: 1_700_000_400, result: .interrupted),
    ]
    static let automationResults: [RemoteAutomationResult] = [
        .ok, .runs([]), .runs(runs),
        .runs([AutomationRun(id: op, startedAt: 1, endedAt: 1, result: .failed, trigger: "#1 T · issue opened", triggerURL: "u",
                             pullRequestURL: "p", unread: true, failure: "worktree failed")]),
        .status(AutomationTriggerStatus(state: .retrying, reason: "offline", pending: [
            AutomationEvent(id: "acme/app#1:opened", kind: .issueOpened, repo: "acme/app", number: 1, title: "T", occurredAt: 3)],
            nextRunAt: 9, lastCheckedAt: 8, retryAt: 10, runsToday: 2, allPaused: false)),
    ]

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
        defaultServiceTier: .fast, textGenerationModel: "anthropic/claude-haiku", visionModel: "google/gemini-flash", compactAtPercent: 80,
        queueDelivery: .oneAtATime, goalCrossProviderEvaluation: true, goalsEnabled: true, projectsEnabled: true, fleetEnabled: true,
        worktreeBase: .head, fetchBeforeCreating: false, mergePRAutomatically: true, mergeMethod: .rebase, closeOnMerge: true,
        backgroundService: true, designToolEnabled: true,
        subagentDefaults: HostSettings.SubagentDefaults(concurrency: 6, model: "openai/gpt-5-mini", thinking: .low, context: .fork),
        worktreeDeleteAction: .removeWorktree, skillsInSlashMenu: false, mcpProjectConfig: true,
        slashCommands: [NativeCommand(name: "review", description: "Review a diff", source: "extension")], hiddenSlashCommands: ["review"],
        bundledExtensions: [HostSettings.BundledExtension(id: "panes", name: "Panes and agent tools", on: true),
                            HostSettings.BundledExtension(id: "review", name: "Diff review tool", on: false)],
        installedExtensions: ["npm:@example/pi-tools@1.0.0"], updatePiDaily: true,
        fleetWeights: [FleetSendWeight.settingKey(hostID: fleetHost): .lessOften])
    static let mcpInventory = HostMCPInventory(
        servers: [HostMCPServer(name: "github", kind: .remote, endpoint: "https://api.githubcopilot.com/mcp/", status: .connected,
                                signIn: "Signed in", tools: 12),
                  HostMCPServer(name: "postgres", kind: .local, endpoint: "npx -y @modelcontextprotocol/server-postgres", status: .error,
                                note: "connection refused", signIn: "DATABASE_URI", tools: nil, enabled: true),
                  HostMCPServer(name: "old", kind: .remote, endpoint: "https://example.invalid/mcp", status: .off, enabled: false)],
        configPath: "~/Library/Application Support/Shepherd/pi/mcp.json", problem: nil, checkedAt: 1_700_000_000)
    static let inventoryRequests: [RemoteHostInventoryRequest] = [.mcp, .subagents, .subagent(file: "team/scout.md"), .providers]
    static let inventoryResults: [RemoteHostInventoryResult] = [
        .mcp(mcpInventory),
        .mcp(HostMCPInventory(servers: [], configPath: "~/mcp.json", problem: "mcp.json line 12 isn\u{2019}t valid JSON")),
        .subagents([HostSubagentProfile(file: "reviewer.md", name: "reviewer", description: "Reviews a diff.", tools: ["read"], context: "fork", isDefault: true),
                    HostSubagentProfile(file: "team/broken.md", name: "broken", error: "No front matter", disabled: true)]),
        .subagent(HostSubagentProfileText(file: "reviewer.md", text: "---\nname: reviewer\n---\nReview.\n", fingerprint: "ab12")),
        .providers([HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .expired, detail: "Claude Pro or Max", accounts: 2, activeAccount: "work"),
                    HostProviderStatus(id: "openai", name: "OpenAI", badge: "API key", auth: .apiKey, problem: "Couldn\u{2019}t sign out."),
                    HostProviderStatus(id: "local", name: "local", badge: "Custom", auth: .noKey, detail: "http://localhost:11434")]),
    ]
    static let hostSettingChanges: [HostSettingChange] = [
        .defaultModel("openai/gpt-5"), .defaultModel(nil), .defaultThinking(.low), .queueDelivery(.all),
        .defaultServiceTier(.fast), .textGenerationModel("openai/gpt-5-mini"), .textGenerationModel(nil), .namingModel("openai/gpt-5-mini"), .compactAtPercent(70), .compactAtPercent(nil),
        .goalCrossProviderEvaluation(true), .goalCrossProviderEvaluation(false), .goalsEnabled(true), .goalsEnabled(false), .projectsEnabled(true), .projectsEnabled(false), .fleetEnabled(true), .fleetEnabled(false),
        .fleetWeight(hostID: RemoteSamples.fleetHost, weight: .prefer), .fleetWeight(hostID: RemoteSamples.fleetHost, weight: .manualOnly),
        .fleetThreadsCanSend(true), .fleetThreadCap(5), .fleetAutoDispatch(true), .fleetAutoDispatch(false), .fleetBatteryCountsHalf(false),
        .worktreeBase(.fresh), .fetchBeforeCreating(true), .commitRemainingWork(false), .generatePRDescriptions(false),
        .deleteLocalBranch(false), .mergePRAutomatically(false), .mergeMethod(.squash),
        .bundledExtension(id: "review", on: true), .updatePiDaily(false), .updateExtensionsDaily(true),
        .designToolEnabled(true),
        .subagentDefaults(HostSettings.SubagentDefaults(concurrency: 2, model: nil, thinking: nil, context: .fresh)),
        .worktreeDeleteAction(.keepWorktree), .skillsInSlashMenu(false), .mcpProjectConfig(true), .slashCommand(name: "review", on: false),
        .closeOnMerge(true), .closeOnMerge(false),
    ]
    static let configRequests: [RemoteHostConfigRequest] = [
        .mcpEntry(name: "github"),
        .mcpSave(json: #"{"mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}"#, secrets: ["LINEAR_TOKEN": "lin_123"], replacing: nil),
        .mcpSave(json: #"{"mcpServers":{"pg":{"command":"uvx"}}}"#, secrets: [:], replacing: "postgres"),
        .mcpSetEnabled(name: "github", on: false), .mcpSetExposure(name: "github", exposure: .direct),
        .mcpSetTools(name: "github", tools: ["search"]), .mcpSetTools(name: "github", tools: nil),
        .mcpRemove(name: "old"), .mcpImport(json: "{}", replace: true), .mcpRefresh,
        .mcpSignIn(name: "linear"), .mcpSignOut(name: "linear"),
        .subagentSave(file: "team/scout.md", text: "---\nname: scout\n---\n", fingerprint: nil),
        .subagentSave(file: "reviewer.md", text: "---\nname: reviewer\n---\n", fingerprint: "ab12"),
        .subagentDelete(file: "team/scout.md", fingerprint: "cd34"), .subagentRestoreDefaults(expected: ["reviewer.md": "ab12"]),
        .providerKey(provider: "openai", key: "$OPENAI_API_KEY"), .providerSignOut(provider: "openai"), .providerSignIn(provider: "anthropic"),
        .providerAccount(provider: "anthropic", action: .use(id: "a1")), .providerAccount(provider: "anthropic", action: .remove(id: "a1")),
        .providerAccount(provider: "anthropic", action: .rename(id: "a1", name: "work")), .providerAccount(provider: "anthropic", action: .rotate(true)),
        .providerAccount(provider: "anthropic", action: .add), .providerAccount(provider: "deepseek", action: .addKey("$DEEPSEEK_API_KEY")),
        .signIn(id: op, action: .poll), .signIn(id: op, action: .complete("code#state")), .signIn(id: op, action: .cancel),
    ]
    static let configResults: [RemoteHostConfigResult] = [
        .mcp(mcpInventory), .mcpEntry(json: #"{"mcpServers":{"github":{"url":"https://x"}}}"#),
        .subagents([HostSubagentProfile(file: "reviewer.md", name: "reviewer", isDefault: true, fingerprint: "ab12")]),
        .subagent(HostSubagentProfileText(file: "reviewer.md", text: "Review.\n", fingerprint: "ab12")),
        .providers([HostProviderStatus(id: "openai", name: "OpenAI", badge: "API key", auth: .apiKey)]),
        .providers([HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .signedIn, accounts: 2, activeAccount: "work",
                                       accountList: [HostProviderAccount(id: "a1", name: "work", active: true),
                                                     HostProviderAccount(id: "a2", name: "home", active: false, limitedUntil: 1_700_000_000)],
                                       rotate: true)]),
        .signIn(HostSignInProgress(id: op, phase: .waiting, name: "Anthropic", authorizationURL: "https://claude.ai/oauth", wantsCode: true)),
        .signIn(HostSignInProgress(id: op, phase: .waiting, name: "GitHub Copilot", authorizationURL: "https://github.com/login/device", deviceCode: "AB-12")),
        .signIn(HostSignInProgress(id: op, phase: .failed, name: "linear", message: "Cancelled.")),
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
            InstalledSkill(name: "triage", summary: "Sorts issues.", updatedAt: 1_695_000_000,
                           copiedFrom: "/Users/me/.pi/agent/skills/triage"),
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
    static let hookHandler = HookHandler(raw: .object(["type": .string("command"), "command": .string("jq -r .tool_input.file_path\n| xargs prettier"),
                                                       "timeout": .number(10), "zeta": .array([.bool(true), .null]), "alpha": .string("kept in file order")]))
    static let hookEntry = HookEntry(slot: "/Users/sam/.shepherd/hooks.json#PreToolUse/0/0", scope: .mac, file: "/Users/sam/.shepherd/hooks.json",
                                     format: .shepherd, event: "PreToolUse", matcher: "Edit|Write", groupIndex: 0, handlerIndex: 0,
                                     handler: hookHandler, hash: "ab12", canonical: hookHandler.raw.canonical, editable: true, on: false)
    static let hooks = HookCatalogSnapshot(
        sources: [
            HookSource(path: "/Users/sam/.shepherd/hooks.json", scope: .mac, format: .shepherd, isTOML: false, state: .loaded(count: 1)),
            HookSource(path: "/Users/sam/.codex/config.toml", scope: .mac, format: .codex, isTOML: true, state: .readerOff),
            HookSource(path: "/Users/sam/code/web/.claude/settings.json", scope: .space(root: "/Users/sam/code/web"), format: .claude,
                       isTOML: false, state: .unreadable(line: 14, message: "expected “,”")),
            HookSource(path: "/Users/sam/code/web/.codex/hooks.json", scope: .space(root: "/Users/sam/code/web"), format: .codex,
                       isTOML: false, state: .unreadable(line: nil, message: "the file isn't UTF-8 text")),
            HookSource(path: "/Users/sam/code/web/.shepherd/hooks.json", scope: .space(root: "/Users/sam/code/web"), format: .shepherd,
                       isTOML: false, state: .notFound),
        ],
        entries: [hookEntry], settings: HookSettings(off: ["ab12"], readers: .init(claude: true, codex: false)), home: "/Users/sam")
    static let hooksRequests: [RemoteHooksRequest] = [
        .fetch,
        .setOn(hash: "ab12", on: true),
        .setReader(format: .codex, on: false),
        .save(drafts: [HookDraft(event: "PreToolUse", matcher: "Edit|Write", handler: hookHandler), HookDraft(event: "PreToolUse", handler: .command("ls"))],
              file: "/Users/sam/.shepherd/hooks.json", replacing: HookRef(hookEntry), kept: 0),
        .save(drafts: [HookDraft(event: "Stop", handler: .command("npm test"))], file: "/Users/sam/code/web/.shepherd/hooks.json", replacing: nil, kept: nil),
        .delete(HookRef(slot: "/Users/sam/.shepherd/hooks.json#Stop/1/0", hash: "cd34")),
        .test(command: "exit 2", event: .preToolUse, matcher: "Bash", timeout: 5, root: "/Users/sam/code/web"),
        .test(command: "true", event: .sessionEnd, matcher: "", timeout: nil, root: nil),
    ]
    static let hooksResults: [RemoteHooksResult] = [
        .hooks(hooks), .hooks(HookCatalogSnapshot(sources: [], entries: [], settings: HookSettings())),
        .tested(HookTestResult(exit: 2, stdout: "", stderr: "No edits to .env files.", milliseconds: 41, outcome: .blocked(reason: "No edits to .env files."))),
        .tested(HookTestResult(exit: nil, stdout: "", stderr: "", milliseconds: 5_000, outcome: .timedOut)),
        .tested(HookTestResult(exit: 0, stdout: "{}", stderr: "", milliseconds: 3, outcome: .context("Run make lint"))),
        .tested(HookTestResult(exit: 0, stdout: "lint ok\n", stderr: "warn\n", milliseconds: 9, outcome: .allowed, stdoutCut: true, stderrCut: false)),
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
        case .nativeThreadSubscribe, .fleetDigest, .pushRegistration, .pushUnregister, .nativeThread, .hello, .stateFetch, .attach, .detach, .input, .resize, .paste, .openPane,
             .closePane, .resizePaneSplit, .listDir, .listModels, .drain, .hostUpdateGate, .addSpace, .spaceAction, .projectRequest, .startThread, .focusThread, .projectExecutors, .createAgent, .upload,
             .creationOptions, .creationBranches, .agentQuery, .agentAction, .automation, .forge, .instructions, .suggestions, .hostSettings, .hostInventory, .hostUpdate, .skills, .hooks, .projects, .logicalProjects, .projectExecution, .design,
             .logicalProjectRuntime, .tunnel, .browserClaim, .browserRelease, .browserAnswer, .designRelayAnswer, .appRelayAnswer, .hostConfig, .apps,
             .fleetIdentify, .fleetPair, .fleetEstablish, .fleetIntroduce, .fleetRevoke, .fleetRead, .fleetAction, .fleetSync,
             .fleetPressure, .fleetReadiness, .fleetPressureNow, .fleetRepoManifest, .fleetSnapshotPart, .fleetBlobPush,
             .fleetDispatchCreate, .fleetDispatchControl, .fleetDispatchChanged, .fleetDispatchResult, .fleetRoutes, .fleetPeerAnswer,
             .fleetPairDevice, .fleetEnrollDevice, .fleetSyncDevices:
            return Wire.caseName(request)
        }
    }
    static let caseCount = 76

    static let samples: [RemoteRequest] = [
        .nativeThreadSubscribe(id: 95, agentIDs: [S.agent]),
        .nativeThreadSubscribe(id: 96, agentIDs: []),
        .fleetDigest(id: 97, agentID: S.agent, session: .init(piSessionID: "s", generation: "g"), revision: 9),
        .fleetDigest(id: 98, agentID: S.agent, session: nil, revision: nil),
        .pushRegistration(id: 93, registration: RemotePushRegistration(id: "11111111-2222-3333-4444-555555555555", sendToken: String(repeating: "a", count: 64))),
        .pushRegistration(id: 94, registration: RemotePushRegistration(id: "11111111-2222-3333-4444-555555555555", sendToken: String(repeating: "a", count: 64),
            preferences: RemotePushPreferences(topics: [.questions, .failures], awayOnly: false))),
        .pushUnregister(id: 94, registrationID: "11111111-2222-3333-4444-555555555555"),
        .fleetIdentify(id: 70),
        .fleetPair(id: 71, code: "482913", from: RemoteSamples.fleetIntroduction),
        .fleetEstablish(id: 72, from: RemoteSamples.fleetIntroduction),
        .fleetIntroduce(id: 73, introduction: FleetIntroduce(member: RemoteSamples.fleetMember, theirTokenHash: nil)),
        .fleetIntroduce(id: 74, introduction: FleetIntroduce(member: RemoteSamples.fleetMember, theirTokenHash: RemoteSamples.fleetHash)),
        .fleetRevoke(id: 75, hostID: RemoteSamples.fleetHost, at: 1_790_000_000_123),
        .fleetSync(id: 82, request: .hello(vector: RemoteSamples.fleetVector)),
        .fleetSync(id: 86, request: .hello(vector: RemoteSamples.fleetVector, fresh: true)),
        .fleetSync(id: 87, request: .op(RemoteSamples.fleetCredentialOp)),
        .fleetSync(id: 83, request: .ops([RemoteSamples.fleetOp, RemoteSamples.fleetSettingOp])),
        .fleetSync(id: 84, request: .op(RemoteSamples.fleetSettingOp)),
        .fleetSync(id: 85, request: .blob(hash: String(repeating: "cd", count: 32), offset: 262_144)),
        .fleetRead(id: 76),
        .fleetAction(id: 77, action: .startJoin),
        .fleetAction(id: 78, action: .stopJoin),
        .fleetAction(id: 79, action: .pair(host: "192.168.1.40", port: 7434, code: "482913")),
        .fleetAction(id: 130, action: .findAndPair(code: "482913")),
        .fleetAction(id: 131, action: .pairAt(hostID: UUID(uuidString: "5B1F7A52-0F3C-4C55-A5A3-61C0E3F2B9D4")!, port: 7434,
                                              routes: [FleetReportedRoute(host: "192.168.20.14", kind: .lan), FleetReportedRoute(host: "mac-mini.local", kind: .hostname)],
                                              code: "482913", expiresAt: 1_770_000_000_000)),
        .fleetAction(id: 132, action: .pairAt(hostID: UUID(uuidString: "5B1F7A52-0F3C-4C55-A5A3-61C0E3F2B9D4")!, port: 7434,
                                              routes: [FleetReportedRoute(host: "100.86.12.4", kind: .tailscale)], code: "482913", expiresAt: nil)),
        .fleetAction(id: 80, action: .remove(hostID: RemoteSamples.fleetHost)),
        .fleetAction(id: 81, action: .adopt([FleetLegacyHost(id: RemoteSamples.fleetHost, name: "Mac mini", host: "192.168.1.40", port: 7434, token: "shared")])),
        .fleetAction(id: 101, action: .watching(true)),
        .fleetAction(id: 102, action: .watching(false)),
        .fleetAction(id: 103, action: .reconnect(hostID: RemoteSamples.fleetHost)),
        .fleetPressure(id: 104, sample: RemoteSamples.fleetSample),
        .fleetReadiness(id: 105, report: RemoteSamples.fleetReadiness),
        .fleetPressureNow(id: 106),
        .fleetRepoManifest(id: 107, update: RemoteSamples.fleetManifestFull),
        .fleetRepoManifest(id: 108, update: RemoteSamples.fleetManifestDelta),
        .fleetRepoManifest(id: 109, update: RemoteSamples.fleetManifestHead),
        .fleetDispatchCreate(id: 110, create: RemoteSamples.dispatchCreate),
        .fleetDispatchCreate(id: 118, create: RemoteSamples.dispatchCreateWithSnapshot),
        .fleetDispatchCreate(id: 122, create: RemoteSamples.dispatchCreateCloning),
        .fleetDispatchCreate(id: 129, create: FleetDispatchCreate(dispatchID: RemoteSamples.dispatchID, kind: .userThread, task: "Look.", title: "", repoKey: "github.com/acme/orders-svc",
                                                                  commitSHA: String(repeating: "b", count: 40), branch: "feat/orders",
                                                                  from: FleetDispatchSender(hostID: RemoteSamples.fleetHost, hostName: "MacBook Pro", agentTitle: ""),
                                                                  start: FleetThreadStart(place: .existingBranch, branch: "feat/orders"))),
        .fleetDispatchCreate(id: 125, create: FleetDispatchCreate(dispatchID: RemoteSamples.dispatchID, kind: .userThread, task: "Look.", title: "", repoKey: "local/0123456789ab",
                                                                  commitSHA: String(repeating: "a", count: 40), from: FleetDispatchSender(hostID: RemoteSamples.fleetHost, hostName: "MacBook Pro", agentTitle: ""),
                                                                  snapshot: RemoteSamples.repoOnlyHeader, repo: FleetRepoSource(origin: nil, spaceID: SpaceID(rawValue: "S1"), name: "web"))),
        .fleetDispatchCreate(id: 123, create: FleetDispatchCreate(dispatchID: RemoteSamples.dispatchID, kind: .userThread, task: "Look.", title: "", repoKey: "github.com/acme/web",
                                                                  from: FleetDispatchSender(hostID: RemoteSamples.fleetHost, hostName: "MacBook Pro", agentTitle: ""),
                                                                  repo: FleetRepoSource(origin: nil))),
        .fleetSnapshotPart(id: 119, dispatchID: RemoteSamples.dispatchID, part: RemoteSamples.snapshotPart),
        .fleetSnapshotPart(id: 120, dispatchID: RemoteSamples.dispatchID, part: FleetSnapshotPart(index: -1, wantsNeeds: true)),
        .fleetBlobPush(id: 121, dispatchID: RemoteSamples.dispatchID, chunk: RemoteSamples.blobChunk),
        .fleetDispatchCreate(id: 111, create: FleetDispatchCreate(dispatchID: RemoteSamples.dispatchID, kind: .userThread, task: "Look at the logs.", title: "",
                                                                  repoKey: "github.com/acme/web", from: FleetDispatchSender(hostID: RemoteSamples.fleetHost, hostName: "MacBook Pro", agentTitle: ""))),
        .fleetDispatchControl(id: 112, dispatchID: RemoteSamples.dispatchID, control: .status),
        .fleetDispatchControl(id: 113, dispatchID: RemoteSamples.dispatchID, control: .cancel),
        .fleetDispatchControl(id: 114, dispatchID: RemoteSamples.dispatchID, control: .message(text: "Also update the docs.", delivery: .steer)),
        .fleetDispatchChanged(id: 115, record: RemoteSamples.dispatchRecord),
        .fleetDispatchChanged(id: 124, record: RemoteSamples.dispatchRecordCloning),
        .fleetDispatchResult(id: 116, dispatchID: RemoteSamples.dispatchID, text: "Fixed: the test raced the clock.", branchFacts: RemoteSamples.branchFacts),
        .fleetDispatchResult(id: 117, dispatchID: RemoteSamples.dispatchID, text: "Nothing to change.", branchFacts: nil),
        .fleetRoutes(id: 140, report: RemoteSamples.routeReport),
        .fleetRoutes(id: 141, report: FleetRouteReport(port: 7434, routes: [])),
        .fleetPeerAnswer(id: 142, reply: .ok(id: 142)),
        .fleetPeerAnswer(id: 143, reply: .fleetSyncReply(id: 143, reply: .state(vector: RemoteSamples.fleetVector))),
        .fleetPeerAnswer(id: 144, reply: .error(id: 144, code: "forbidden", message: "Only a Mac in the fleet syncs.")),
        .fleetPairDevice(id: 82, code: "482913", device: RemoteSamples.fleetDevice),
        .fleetEnrollDevice(id: 83, device: RemoteSamples.fleetDevice),
        .fleetSyncDevices(id: 84, devices: RemoteSamples.fleetDeviceEntries),
        .fleetSyncDevices(id: 85, devices: []),
        .fleetAction(id: 86, action: .startDeviceCode),
        .fleetAction(id: 87, action: .stopDeviceCode),
        .fleetAction(id: 88, action: .revokeDevice(RemoteSamples.fleetDevice.deviceID)),
        .fleetAction(id: 89, action: .forgetLegacyClient("Shepherd iOS@192.168.1.31")),
        .fleetAction(id: 99, action: .retireSharedToken),
        .fleetAction(id: 100, action: .enrollApp(name: "MacBook Pro")),
        .fleetAction(id: 101, action: .sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "s1"), task: "Profile the orders import.", host: nil))),
        .fleetAction(id: 102, action: .sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "s1"), task: "Profile the orders import.", title: "Profile import",
                                                                    host: "Mac mini", model: "acme/model-1", thinking: "high"))),
        .fleetAction(id: 126, action: .sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "s1"), task: "Profile the orders import.", host: "Mac mini",
                                                                    start: FleetThreadStart(place: .newWorktree, base: "origin/main", branch: "fix/orders-import")))),
        .fleetAction(id: 127, action: .sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "s1"), task: "Profile the orders import.",
                                                                    start: FleetThreadStart(place: .existingBranch, branch: "feat/orders")))),
        .fleetAction(id: 128, action: .sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "s1"), task: "Profile the orders import.", start: FleetThreadStart(place: .checkout)))),
        .fleetAction(id: 103, action: .retryDispatch(id: RemoteSamples.dispatchID, host: nil)),
        .fleetAction(id: 104, action: .retryDispatch(id: RemoteSamples.dispatchID, host: RemoteSamples.fleetHost)),
        .fleetAction(id: 105, action: .cancelDispatch(id: RemoteSamples.dispatchID)),
        .hostUpdate(id: 90, request: .status),
        .hostUpdate(id: 91, request: .check),
        .hostUpdate(id: 92, request: .install(offerID: S.op, authorized: true)),
        .logicalProjectRuntime(id: 81, request: .action(projectID: ProjectID(), expectedRevision: 1, request: .read)),
        .nativeThread(id: 80, agentID: S.agent, request: .snapshot(expectedSessionID: "s", beforeEntryID: "m:3", afterRevision: 9)),
        .hello(id: 2, token: "", clientName: "Alex's MacBook \"Pro\"", protocolVersion: 99),
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
        .drain(id: 10),
        .hostUpdateGate(id: 11, step: .reserve),
        .hostUpdateGate(id: 12, step: .canTerminate),
        .addSpace(id: 5, path: "/Users/demo/Developer/project"),
        .spaceAction(id: 5, spaceID: S.space, action: .rename(name: "acme-web")),
        .spaceAction(id: 5, spaceID: S.space, action: .setWorktreeBase(base: nil)),
        .spaceAction(id: 5, spaceID: S.space, action: .setWorktreeBase(base: "origin/release")),
        .spaceAction(id: 5, spaceID: S.space, action: .setSidebarHidden(hidden: true)),
        .spaceAction(id: 5, spaceID: S.space, action: .move(before: nil)),
        .spaceAction(id: 5, spaceID: S.space, action: .delete),
        .spaceAction(id: 5, spaceID: S.space, action: .relocate(path: "/Users/demo/Developer/acme-web")),
        .projectRequest(id: 5, request: .register(path: "/Users/demo/Developer/acme-web", name: "acme-web")),
        .projectRequest(id: 5, request: .edit(spaceID: S.space, edit: ProjectEdit(parentProjectID: ""))),
        .projectRequest(id: 5, request: .child(parentPath: "/Users/demo/Developer/acme", path: "/Users/demo/Developer/acme/web", name: "web", create: true)),
        .startThread(id: 6, thread: RemoteThreadStart(spaceID: nil, agentID: S.agent)),
        .focusThread(id: 7, agentID: S.agent),
        .focusThread(id: 7, agentID: nil),
        .focusThread(id: 7, agentID: S.agent, paneID: S.pane),
        .projectExecutors(id: 7, update: .hosts([
            ProjectHostOption(reference: .remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                                 bindingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
                              name: "build-01", spaces: [Space(name: "acme-web", path: "/srv/acme-web")]),
            ProjectHostOption(reference: .remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
                                                 bindingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!), name: "old-mac"),
        ])),
        .projectExecutors(id: 8, update: .changed(host: .remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                                                bindingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
                                                  key: ProjectExecutionKey(ownerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                                                           projectID: ProjectID(rawValue: "acme-release"),
                                                                           operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!))),
        .projectExecutors(id: 9, update: .changed(host: .local, key: nil)),
        .startThread(id: 6, thread: RemoteThreadStart(spaceID: S.space, cwd: "/tmp/acme-web-worktrees/fix", model: "anthropic/claude-4", thinking: .high,
                                                      serviceTier: .fast, initialPrompt: "fix it", name: "Fix it (fork)", piSessionID: "sess-1",
                                                      agentID: S.agent, worktreeBranch: "agent/fix", worktreeBase: "main",
                                                      worktreePath: "/tmp/acme-web-worktrees/fix")),
        .createAgent(id: 6, spaceID: S.space, cwd: "/tmp/checkout", model: "anthropic/claude-4", thinking: .high,
                     initialPrompt: "fix the \"thing\"\nplease", worktreeBranch: "worktree/a", worktreeBase: "origin/release",
                     worktreeFetchFirst: false,
                     initialImages: [NativeImage(mimeType: "image/png", data: Data([0x89, 0x50]), name: "shot.png")], serviceTier: .fast),
        .upload(id: 50, action: .begin(sessionID: S.session, name: "image.png", size: 20)),
        .creationOptions(id: 54, spaceID: S.space, cwd: "/host/repo", fetchFirst: false),
        .creationBranches(id: 55, spaceID: S.space),
        .agentQuery(id: 31, agentID: S.agent, query: .children),
        .agentAction(id: 20, agentID: S.agent, action: .rename(name: "new \"name\"")),
        .automation(id: 21, automationID: S.automation, request: .setEnabled(enabled: false)),
        .forge(id: 22, request: .merge(ref: ForgeSamples.pull, method: .squash, whenReady: true, deleteBranch: true)),
        .instructions(id: 23, request: .save(file: .appendSystem, content: "Never force-push.\n", origin: "studio", sync: true)),
        .suggestions(id: 25, request: .add(id: S.op, line: "- Ask for join keys first.", file: nil)),
        .hostSettings(id: 27, request: .change(.bundledExtension(id: "review", on: true))),
        .hostInventory(id: 28, request: .mcp),
        .hostConfig(id: 28, request: .mcpRefresh),
        .skills(id: 29, request: .install(repo: "anthropics/skills", paths: ["skills/pdf"], commit: nil, invocation: nil)),
        .hooks(id: 29, request: .setOn(hash: "ab12", on: false)),
        .apps(id: 35, request: .list(spaceID: S.space)),
        .apps(id: 36, request: .run(spaceID: S.space, name: "Web app", mac: false, agentID: S.agent)),
        .apps(id: 37, request: .run(spaceID: S.space, name: "Simulator", mac: true, agentID: nil)),
        .apps(id: 38, request: .stop(spaceID: S.space, name: "Web app", mac: false)),
        .apps(id: 39, request: .run(spaceID: nil, name: "Postgres", mac: true, agentID: nil)),
        .apps(id: 40, request: .stop(spaceID: nil, name: "Postgres", mac: true)),
        .apps(id: 41, request: .processes),
        .apps(id: 42, request: .restart(spaceID: S.space, name: "Web app")),
        .apps(id: 43, request: .output(spaceID: nil, name: "Postgres", tail: 5000)),
        .projects(id: 30, request: .list()),
        .logicalProjects(id: 31, request: .list),
        .projectExecution(id: 33, request: .execute(ProjectExecutionWireTests.assignment)),
        .design(id: 31, request: .boards(designID: RemoteDesignSamples.design, paths: nil, knownShas: [:])),
        .tunnel(.open(tunnel: 7, agentID: S.agent, port: 5173)),
        .browserClaim(id: 33, agentID: S.agent),
        .browserRelease(agentID: S.agent),
        .browserAnswer(requestToken: 12, outcome: .text("Clicked button \"Pay\".")),
        .browserAnswer(requestToken: 13, outcome: .result(text: "Screenshot.", image: BrowserImage(data: "/9j/4AAQ", mimeType: "image/jpeg"))),
        .browserAnswer(requestToken: 14, outcome: .failure(code: "refused_url", message: "That address is on your network.")),
        .designRelayAnswer(requestToken: 3, result: .rendered(DesignRendered(image: BrowserImage(data: "iVBORw0K", mimeType: "image/png"),
                                                                             text: "Two.dc.html at 400×300", diagnostics: ["1 font missing"]))),
        .designRelayAnswer(requestToken: 4, result: .exported),
        .designRelayAnswer(requestToken: 5, result: .captured(DesignReferenceCaptured(
            boards: [.init(picture: .init(name: "board.png", bytes: 1_024, pixelWidth: 800, pixelHeight: 600), html: nil)],
            computedStyles: ["color": "#111111"]))),
        .designRelayAnswer(requestToken: 6, result: .failed(code: "render_failed", message: "Two.dc.html couldn't be drawn.")),
        .appRelayAnswer(requestToken: 7, result: .done(text: "Review ready in the side pane's Changes tab.")),
        .appRelayAnswer(requestToken: 8, result: .failed(code: "no_such_agent", message: "unknown agent a")),
        .appRelayAnswer(requestToken: 9, result: .hostUpdate(status: HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: .idle))),
        .appRelayAnswer(requestToken: 10, result: .nativeThread(result: .failure(code: "starting", message: "The agent is starting."))),
        .appRelayAnswer(requestToken: 11, result: .projectExecution(result: ProjectExecutionResult(receipt: ProjectExecutionReceipt(
            key: ProjectExecutionKey(ownerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, projectID: ProjectID(rawValue: "acme-release"),
                                     operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!), phase: .settled)))),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    /// What the host writes to a relay's job file.
    @Test(arguments: [DesignRelayJob]([
        .render(DesignRenderJob(designID: RemoteReplyTests.relayDesign, path: DesignPath("Two.dc.html")!,
                                request: DesignRenderRequest(path: "Two.dc.html"), files: RemoteReplyTests.files,
                                deadline: Date(timeIntervalSince1970: 1_000))),
        .export(DesignExportJob(designID: RemoteReplyTests.relayDesign, request: DesignExportRequest(format: .png),
                                files: RemoteReplyTests.files, destination: URL(fileURLWithPath: "/tmp/acme/exports/Two.png"))),
        .capture(DesignReferenceCaptureRequest(
            reference: DesignReference(designID: RemoteReplyTests.relayDesign, board: DesignPath("Two.dc.html"))!,
            boards: [.init(path: DesignPath("Two.dc.html")!, source: "<x-dc></x-dc>", isCurrent: true, picture: "board.png", html: "board.html")],
            folder: URL(fileURLWithPath: "/tmp/acme/refs"), files: RemoteReplyTests.files)),
    ]))
    func relayJobsRoundTrip(_ job: DesignRelayJob) throws {
        #expect(try NDJSON.decode(DesignRelayJob.self, from: NDJSON.encode(job)) == job)
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

    @Test(arguments: [RemoteAgentAction.rename(name: "x"), .move(spaceID: SpaceID(rawValue: "destination")), .deleteKeepingWorktree, .reorder(target: AgentID(rawValue: "b")),
                      .renameTerminal(paneID: PaneID(rawValue: "p"), title: "logs"), .renameTerminal(paneID: PaneID(rawValue: "p"), title: nil),
                      .killTerminalProcess(paneID: PaneID(rawValue: "p")), .startTerminal(paneID: PaneID(rawValue: "p")),
                      .openTerminal(cwd: "/host/repo/apps/web", command: "pnpm dev"), .restartPi(newConversation: true), .restartPi(newConversation: false, model: "anthropic/claude-x"), .markSeen(upTo: 1_760_000_000_123), .mutePushes(true), .mutePushes(false), .readCheckout])
    func everyAgentActionRoundTrips(_ action: RemoteAgentAction) throws {
        #expect(try Wire.roundTrip(RemoteRequest.agentAction(id: 1, agentID: S.agent, action: action))
            == .agentAction(id: 1, agentID: S.agent, action: action))
    }

    /// Run in terminal is gone: an older client's `typeInTerminal` is no action this side knows.
    /// An older host's skill carries no `copiedFrom`: it decodes as installed from a repository or
    /// by hand, as before.
    @Test func anOlderHostsSkillSaysNothingOfBeingCopied() throws {
        let json = #"{"name":"pdf","summary":"PDFs.","isOn":true,"invocation":"automatic","updatedAt":1,"files":[]}"#
        let skill = try JSONDecoder().decode(InstalledSkill.self, from: Data(json.utf8))
        #expect(skill.copiedFrom == nil && skill.source == nil)
    }

    /// An older client's `changes*` reads name no folder: the agent's own.
    @Test func anOlderClientsChangesReadsNameNoFolder() throws {
        for json in [#"{"changesOverview":{}}"#, #"{"changesBranches":{}}"#] {
            let query = try JSONDecoder().decode(RemoteAgentQuery.self, from: Data(json.utf8))
            #expect(query.isChanges && query.changesCwd == nil)
        }
        #expect(String(decoding: try JSONEncoder().encode(RemoteAgentQuery.changesOverview()), as: UTF8.self) == #"{"changesOverview":{}}"#)
    }

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
    }

    @Test(arguments: RemoteSamples.configRequests)
    func everyConfigRequestRoundTrips(_ request: RemoteHostConfigRequest) throws {
        let message = RemoteRequest.hostConfig(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: RemoteSamples.inventoryRequests)
    func everyInventoryRequestRoundTrips(_ request: RemoteHostInventoryRequest) throws {
        let message = RemoteRequest.hostInventory(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test func fetchingHostSettingsRoundTrips() throws {
        #expect(try Wire.roundTrip(RemoteRequest.hostSettings(id: 2, request: .fetch)) == .hostSettings(id: 2, request: .fetch))
    }

    @Test(arguments: RemoteSamples.hooksRequests)
    func everyHooksRequestRoundTrips(_ request: RemoteHooksRequest) throws {
        let message = RemoteRequest.hooks(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
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
        (#"{"type":"hello","id":1,"token":"t","clientName":"legacy","protocolVersion":1,"capabilities":["projects.v1"]}"#,
         .hello(id: 1, token: "t", clientName: "legacy", protocolVersion: 1, capabilities: ["projects.v1"])),
        (#"{"type":"hello","id":1,"token":"t","clientName":"current","protocolVersion":1,"capabilities":["projects.v2"]}"#,
         .hello(id: 1, token: "t", clientName: "current", protocolVersion: 1, capabilities: ["projects.v2"])),
    ])
    func clientShapesDecodeWithDefaults(json: String, expected: RemoteRequest) throws {
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
        case .nativeThreadChanged, .fleetDigest, .nativeThread, .uploadResult, .creationOptions, .helloOk, .agentResult, .ok, .paneOpened, .error,
             .state, .stateChanged, .attached, .output, .sessionExited, .dirListing, .models, .spaceAdded,
             .agentCreated, .automationResult, .forgeResult, .instructions, .suggestions, .hostSettings, .hostInventory, .hostUpdate, .skills, .hooks, .projects, .logicalProjects, .projectExecution, .projectExecutionChanged, .design, .designChanged, .designSystemsChanged, .fleetViewChanged,
             .logicalProjectRuntime, .capabilitiesChanged, .tunnel, .browserClaimed, .browserDrive, .designRelay, .agentNotify, .appRelay, .settingsChanged, .fleetIdentity, .fleetPaired, .fleetResult, .fleetSyncReply, .fleetRepoManifestAck, .fleetSnapshotAck, .fleetDevices, .fleetPressureSample, .fleetDispatchAccepted, .fleetDispatchState, .fleetPeerCall, .toolFinished, .threadNotice, .agentStartProblem, .automationsChanged, .automationNotify, .designNotesChanged, .designGitChanged, .designImportProgress, .hostConfig, .apps, .appsChanged, .pullRequestLinks:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 68

    static let samples: [RemoteReply] = [
        .nativeThreadChanged(agentID: S.agent),
        .fleetDigest(id: 97, result: .unchanged(piSessionID: "s", generation: "g", revision: 9)),
        .fleetDigest(id: 98, result: .digest(.init(session: .init(piSessionID: "s", generation: "g"), revision: 9, running: true,
            question: .init(dialogID: "q", kind: .select, title: "Choose", options: ["yes", "no"])))),
        .hostUpdate(id: 90, status: HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: .available,
                                                  offerID: S.op, offeredVersion: "2", canInstall: true)),
        .logicalProjectRuntime(id: 81, result: .project(Project(name: "Owner"))),
        .nativeThread(id: 80, result: .accepted(operationID: S.op)),
        .uploadResult(id: 51, result: .complete(path: "/host/private/image.png")),
        .creationOptions(id: 52, options: RemoteCreationOptions(base: "origin/main", note: "cached", fetchFirst: false,
                                                                model: "host/model", thinking: .high, serviceTier: .fast)),
        .helloOk(id: 1, protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities),
        .helloOk(id: 2, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.localCapability], hostBuild: "2611071"),
        .helloOk(id: 3, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.fleetCapability], hostBuild: "2611071", hostID: S.fleetHost),
        .fleetIdentity(id: 4, hostID: S.fleetHost, name: "Mac mini", build: "412", fleetEnabled: true),
        .fleetIdentity(id: 5, hostID: S.fleetHost, name: "Mac mini", build: nil, fleetEnabled: false),
        .fleetPaired(id: 6, hostID: S.fleetHost, name: "Mac mini", myTokenHash: S.fleetHash),
        .fleetPeerCall(id: 150, request: .fleetPressureNow(id: 150)),
        .fleetPeerCall(id: 151, request: .fleetRoutes(id: 151, report: S.routeReport)),
        .fleetPeerCall(id: 152, request: .fleetDispatchResult(id: 152, dispatchID: S.dispatchID, text: "Fixed.", branchFacts: nil)),
        .fleetDispatchAccepted(id: 16, record: S.dispatchRecord),
        .fleetDispatchState(id: 17, record: S.dispatchRecord),
        .fleetDispatchState(id: 25, record: S.dispatchRecordCloning),
        .fleetSyncReply(id: 11, reply: .state(vector: S.fleetVector)),
        .fleetSyncReply(id: 12, reply: .blob(hash: String(repeating: "cd", count: 32), offset: 0, total: 5, data: Data("hello".utf8))),
        .fleetResult(id: 7, result: FleetResult(snapshot: S.fleetSnapshot)),
        .fleetResult(id: 17, result: FleetResult(snapshot: { var snapshot = S.fleetSnapshot; snapshot.index = S.fleetIndexStatus; return snapshot }())),
        .fleetResult(id: 11, result: FleetResult(snapshot: { var snapshot = S.fleetSnapshot; snapshot.devices = S.fleetDevicesSnapshot; return snapshot }(),
                                                 deviceCode: .init(code: "482913", expiresAt: 1_790_000_300_000))),
        .fleetResult(id: 14, result: FleetResult(snapshot: S.fleetSnapshot, appToken: String(repeating: "cd", count: 32))),
        .fleetResult(id: 18, result: FleetResult(snapshot: S.fleetSnapshot, dispatch: S.dispatchRecord)),
        .fleetDevices(id: 13, result: FleetDevicesResult(hostID: S.fleetHost, name: "Mac mini", members: [S.fleetMember], devices: S.fleetDeviceEntries)),
        .fleetDevices(id: 15, result: FleetDevicesResult(hostID: S.fleetHost, name: "Mac mini")),
        .fleetResult(id: 8, result: FleetResult(snapshot: S.fleetSnapshot, join: .init(code: "482913", expiresAt: 1_790_000_300_000))),
        .fleetResult(id: 9, result: FleetResult(snapshot: S.fleetSnapshot, paired: S.fleetSnapshot.peers[0])),
        .fleetPressureSample(id: 11, sample: S.fleetSample, readiness: S.fleetReadiness),
        .fleetPressureSample(id: 13, sample: S.fleetSample, readiness: nil),
        .fleetRepoManifestAck(id: 14, ack: FleetRepoManifestAck(repo: "github.com/acme/web", generation: 7, seq: 3)),
        .fleetRepoManifestAck(id: 16, ack: FleetRepoManifestAck(repo: "space:2F1D", generation: 7, seq: 0, resend: true)),
        .fleetSnapshotAck(id: 17, ack: FleetSnapshotAck(dispatchID: RemoteSamples.dispatchID, parts: 2, needs: [RemoteSamples.snapshotHash], needsCount: 1)),
        .fleetSnapshotAck(id: 18, ack: FleetSnapshotAck(dispatchID: RemoteSamples.dispatchID, parts: 2, complete: true)),
        .fleetResult(id: 10, result: FleetResult(snapshot: S.fleetSnapshot, adopted: [
            FleetAdoption(id: S.fleetHost, outcome: .established(hostID: S.fleetHost, name: "Mac mini")),
            FleetAdoption(id: S.fleetHost, outcome: .notFleet), FleetAdoption(id: S.fleetHost, outcome: .unreachable),
            FleetAdoption(id: S.fleetHost, outcome: .refused(code: "unauthorized"))])),
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
                thinkingLevels: ["anthropic/claude-4": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]],
                serviceTiers: ["openai/gpt-5": ["standard", "fast"]], contexts: ["openai/gpt-5": "400K"],
                withoutImages: ["openai/gpt-5"]),
        .spaceAdded(id: 6, spaceID: S.space),
        .agentCreated(id: 7, agentID: S.agent),
        .automationResult(id: 22, result: .runs(S.runs)),
        .forgeResult(id: 23, result: .pullRequest(ForgeSamples.detail)),
        .instructions(id: 24, snapshot: S.instructions),
        .suggestions(id: 26, snapshot: S.suggestions),
        .hostSettings(id: 28, settings: S.hostSettings),
        .hostInventory(id: 29, result: .mcp(S.mcpInventory)),
        .hostConfig(id: 29, result: .mcp(S.mcpInventory)),
        .skills(id: 30, result: .skills(S.skills)),
        .hooks(id: 30, result: .hooks(S.hooks)),
        .apps(id: 35, result: RemoteAppsResult(space: "acme-web", apps: [
            RemoteApp(app: AppDefinition(name: "Web app", command: "npm run dev", folder: "apps/web", opens: .browser,
                                         address: "http://localhost:3000", quickAction: true),
                      mac: false, run: RemoteAppRun(status: .running, port: 3000)),
            RemoteApp(app: AppDefinition(name: "Storybook", command: "npm run storybook", quickAction: true), mac: false,
                      run: RemoteAppRun(status: .exited(code: 1))),
            RemoteApp(app: AppDefinition(name: "Simulator", command: "open -a Simulator", opens: .window), mac: true,
                      run: RemoteAppRun(status: .failed("Its folder doesn’t exist."), stopping: true)),
            RemoteApp(app: AppDefinition(name: "Docs", command: "make docs"), mac: true),
        ])),
        .apps(id: 36, result: RemoteAppsResult(space: "", apps: [], processes: [
            RemoteAppProcess(spaceID: S.space, name: "Web app",
                             run: RemoteAppRun(status: .running, port: 3000, command: "npm run dev", directory: "/tmp/acme-web", revision: 7)),
        ], lines: ["ready on localhost:3000"])),
        .appsChanged(processes: [RemoteAppProcess(spaceID: nil, name: "Postgres", run: RemoteAppRun(status: .starting))]),
        .pullRequestLinks(links: [S.agent: ThreadPullRequest(ref: ForgeItemRef(kind: .pullRequest, repo: "acme/web", number: 31), state: .open)],
                          notes: [S.agent: "2 uncommitted changes"]),
        .pullRequestLinks(links: [:], notes: [:]),
        .projects(id: 31, result: .listing(ProjectListing(projects: []))),
        .logicalProjects(id: 32, result: .projects([])),
        .projectExecution(id: 33, result: .init(receipt: .init(key: ProjectExecutionWireTests.key, phase: .cancelled))),
        .projectExecutionChanged(key: ProjectExecutionWireTests.key, revision: 2),
        .design(id: 32, result: .ok),
        .designChanged(designID: RemoteDesignSamples.design, revision: 8, commentsRevision: 2),
        .designSystemsChanged,
        .fleetViewChanged,
        .capabilitiesChanged(capabilities: [RemoteProtocol.designsCapability]),
        .tunnel(.data(tunnel: 7, bytes: Data("HTTP/1.1 200 OK\r\n\r\n".utf8))),
        .browserClaimed(id: 33, url: "http://localhost:5173/checkout"),
        .browserClaimed(id: 34, url: nil),
        .browserDrive(.request(token: 12, agentID: S.agent, request: .click(ref: "e4", double: false, note: "paying"))),
        .browserDrive(.opened(agentID: S.agent, url: "http://localhost:5173/checkout")),
        .agentNotify(agentID: AgentID(rawValue: "a"), title: "CI passed", body: "PR #42 is green"),
        .appRelay(token: 6, job: .review(agentID: AgentID(rawValue: "a"), cwd: "/tmp/acme-web", reference: "pr")),
        .appRelay(token: 6, job: .browserPageURL(agentID: AgentID(rawValue: "a"))),
        .appRelay(token: 7, job: .confirmSpaceDelete(spaceID: SpaceID(rawValue: "6f1c2a9e-3b7d-4c51-9e2a-0d4b8f7a1c34"))),
        .appRelay(token: 8, job: .hostUpdate(request: .install(offerID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, authorized: true))),
        .appRelay(token: 9, job: .projectPlacement(
            host: .remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, bindingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
            request: .pause(key: ProjectExecutionKey(ownerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                                     projectID: ProjectID(rawValue: "acme-release"),
                                                     operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!)))),
        .appRelay(token: 10, job: .projectWorkerThread(
            host: .remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, bindingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
            agentID: AgentID(rawValue: "a"), request: .snapshot())),
        .designRelay(token: 3, jobFile: "/tmp/acme/design-relay/3.json"),
        .settingsChanged(page: .instructions),
        .settingsChanged(page: .slashCommands),
        .settingsChanged(page: .fleetPressure),
        .toolFinished(agentID: AgentID(rawValue: "a"), tool: "edit"),
        .designNotesChanged(designID: DesignID(rawValue: "d1")),
        .designGitChanged(designID: DesignID(rawValue: "d1")),
        .designImportProgress(.boards(done: 2, of: 5, title: "Checkout funnel", system: nil)),
        .threadNotice(agentID: AgentID(rawValue: "a"), message: "Switched Anthropic to work: personal hit its limit."),
        .agentStartProblem(agentID: AgentID(rawValue: "a"), problem: NativeStartProblem(kind: .notSignedIn, exitCode: 1, lines: ["No models available"])),
        .agentStartProblem(agentID: AgentID(rawValue: "a"), problem: nil),
        .automationsChanged,
        .automationNotify(title: "Watch CI", body: "The run couldn't start: acme-web is missing."),
    ]

    static let relayDesign = DesignID(rawValue: "6f1c2a9e-3b7d-4c51-9e2a-0d4b8f7a1c33")

    /// A design's files as a relay carries them: canvas.json's index, a board, a support file and an upload.
    static let files = DesignExportFiles(index: try! DesignIndex.decode(Data(#"{"v":3,"title":"Two"}"#.utf8)), boards: [DesignPath("Two.dc.html")!],
                                         members: [DesignPath("Two.dc.html")!], sources: [DesignPath("Two.dc.html")!: "<x-dc></x-dc>"],
                                         support: ["ds/tokens.css": Data(":root{}".utf8)], assets: ["a1": .init(name: "a1.png", data: Data([0x89, 0x50]))])

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

    @Test(arguments: RemoteSamples.hooksResults)
    func everyHooksResultRoundTrips(_ result: RemoteHooksResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.hooks(id: 1, result: result)) == .hooks(id: 1, result: result))
    }

    /// A test reply without output or cut marks decodes as empty and uncut.
    @Test func aHookTestResultWithoutOutputDecodesEmpty() throws {
        let json = #"{"exit":0,"milliseconds":4,"outcome":{"allowed":{}}}"#
        let result = try JSONDecoder().decode(HookTestResult.self, from: Data(json.utf8))
        #expect(result == HookTestResult(exit: 0, stdout: "", stderr: "", milliseconds: 4, outcome: .allowed))
    }

    /// A handler keeps its keys in file order on the wire, so a remote edit leaves unknown keys where they were.
    @Test func aHookHandlerKeepsItsKeyOrderOnTheWire() throws {
        guard case .hooks(_, .hooks(let snapshot)) = try Wire.roundTrip(RemoteReply.hooks(id: 1, result: .hooks(S.hooks))) else {
            Issue.record("expected hooks"); return
        }
        #expect(snapshot.entries[0].handler.raw.objectValue?.map(\.key) == ["type", "command", "timeout", "zeta", "alpha"])
    }

    /// An older host's snapshot lacks `home`: it decodes as empty, and labels keep full paths.
    @Test func aHooksSnapshotWithoutHomeDecodes() throws {
        let snapshot = try JSONDecoder().decode(HookCatalogSnapshot.self, from: Data(#"{"sources":[],"entries":[],"settings":{"off":[]}}"#.utf8))
        #expect(snapshot.home == "" && snapshot.settings.readers.codex)
    }

    @Test(arguments: RemoteSamples.skillsResults)
    func everySkillsResultRoundTrips(_ result: RemoteSkillsResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.skills(id: 1, result: result)) == .skills(id: 1, result: result))
    }

    @Test(arguments: RemoteSamples.inventoryResults)
    func everyInventoryResultRoundTrips(_ result: RemoteHostInventoryResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.hostInventory(id: 1, result: result)) == .hostInventory(id: 1, result: result))
    }

    @Test(arguments: RemoteSamples.configResults)
    func everyConfigResultRoundTrips(_ result: RemoteHostConfigResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.hostConfig(id: 1, result: result)) == .hostConfig(id: 1, result: result))
    }

    /// An older host's settings carry none of the newer fields: they read as the Mac's defaults.
    @Test func hostSettingsFromAnOlderHostDecodeWithDefaults() throws {
        var object = try Wire.object(RemoteReply.hostSettings(id: 1, settings: S.hostSettings))
        var settings = try #require(object["settings"] as? [String: Any])
        for key in ["designToolEnabled", "subagentDefaults", "worktreeDeleteAction",
                    "skillsInSlashMenu", "mcpProjectConfig", "slashCommands", "hiddenSlashCommands", "closeOnMerge", "backgroundService"] {
            settings[key] = nil
        }
        object["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .hostSettings(_, let decoded) = try JSONDecoder().decode(RemoteReply.self, from: data) else {
            Issue.record("expected settings"); return
        }
        #expect(!decoded.designToolEnabled)
        #expect(decoded.subagentDefaults == HostSettings.SubagentDefaults())
        #expect(decoded.worktreeDeleteAction == .ask && decoded.skillsInSlashMenu && !decoded.mcpProjectConfig)
        #expect(decoded.slashCommands.isEmpty && decoded.hiddenSlashCommands.isEmpty)
        #expect(!decoded.closeOnMerge, "an older host never closes threads on merge")
        #expect(decoded.backgroundService == nil, "an older host doesn't say whether agents outlive a quit")
    }

    /// A provider's row never carries a credential: the wire has the state and its words only.
    @Test func aProvidersStatusCarriesNoSecretField() throws {
        let keys = try Wire.object(RemoteReply.hostInventory(id: 1, result: RemoteSamples.inventoryResults[4]))["result"]
            .flatMap { ($0 as? [String: Any])?["providers"] as? [String: Any] }
            .flatMap { ($0["_0"] as? [[String: Any]])?.flatMap(\.keys) } ?? []
        #expect(!keys.isEmpty && !keys.contains { $0.lowercased().contains("key") || $0.lowercased().contains("token") })
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

    /// A host from before `hostSettings.agentDefaults.v1` sends none of the three fields: Standard,
    /// Automatic text generation and pi's own compaction; a tier this client does not know reads
    /// as Standard. The text generation model travels as `textGenerationModel`; the `namingModel`
    /// a host from before the rename reports is not read (its picker needs the newer host).
    @Test func aLegacyHostsAgentDefaultsReadAsTheMacsDefaults() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteSamples.hostSettings)) as? [String: Any])
        #expect(json["textGenerationModel"] as? String == "anthropic/claude-haiku" && json["namingModel"] == nil)
        for key in ["defaultServiceTier", "textGenerationModel", "compactAtPercent"] { json.removeValue(forKey: key) }
        var expected = RemoteSamples.hostSettings
        expected.defaultServiceTier = .standard
        expected.textGenerationModel = nil
        expected.compactAtPercent = nil
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        json["namingModel"] = "anthropic/claude-haiku"
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        json.removeValue(forKey: "namingModel")
        json["defaultServiceTier"] = "hyperspeed"
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        #expect(HostSettingChange.defaultServiceTier(.fast).capability == RemoteProtocol.hostSettingsAgentDefaultsCapability)
        #expect(HostSettingChange.textGenerationModel(nil).capability == RemoteProtocol.hostSettingsTextGenerationModelCapability)
        #expect(HostSettingChange.visionModel(nil).capability == RemoteProtocol.hostSettingsVisionModelCapability)
        #expect(HostSettingChange.defaultModel(nil).capability == nil)
        var applied = HostSettings()
        applied.apply(.compactAtPercent(90))
        applied.apply(.textGenerationModel("x/y"))
        applied.apply(.visionModel("v/w"))
        applied.apply(.defaultServiceTier(.fast))
        #expect(applied.compactAtPercent == 90 && applied.textGenerationModel == "x/y" && applied.visionModel == "v/w" && applied.defaultServiceTier == .fast)
        // An older client's naming-model change lands on the same setting.
        applied.apply(.namingModel("a/b"))
        #expect(applied.textGenerationModel == "a/b")
    }

    @Test func aLegacyHostNeverGrantsCrossProviderConsent() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteSamples.hostSettings)) as? [String: Any])
        json.removeValue(forKey: "goalCrossProviderEvaluation")
        let legacy = try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json))
        var expected = RemoteSamples.hostSettings
        expected.goalCrossProviderEvaluation = false
        #expect(legacy == expected)
        #expect(!HostSettings().goalCrossProviderEvaluation)
        json["goalCrossProviderEvaluation"] = NSNull()
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
    }

    @Test func legacyOrNullGoalExperimentSettingsAlwaysDefaultOff() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteSamples.hostSettings)) as? [String: Any])
        json.removeValue(forKey: "goalsEnabled")
        var expected = RemoteSamples.hostSettings
        expected.goalsEnabled = false
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        json["goalsEnabled"] = NSNull()
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        #expect(!HostSettings().goalsEnabled)
    }

    @Test func legacyOrNullProjectsExperimentSettingsAlwaysDefaultOff() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteSamples.hostSettings)) as? [String: Any])
        json.removeValue(forKey: "projectsEnabled")
        var expected = RemoteSamples.hostSettings
        expected.projectsEnabled = false
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        json["projectsEnabled"] = NSNull()
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        #expect(!HostSettings().projectsEnabled)
        var settings = HostSettings()
        settings.apply(.projectsEnabled(true))
        #expect(settings.projectsEnabled)
        settings.apply(.projectsEnabled(false))
        #expect(settings == HostSettings())
    }

    @Test func anOlderHostsSettingsLeaveFleetOff() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteSamples.hostSettings)) as? [String: Any])
        json.removeValue(forKey: "fleetEnabled")
        var expected = RemoteSamples.hostSettings
        expected.fleetEnabled = false
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        json["fleetEnabled"] = NSNull()
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: json)) == expected)
        var settings = HostSettings()
        #expect(!settings.fleetEnabled)
        settings.apply(.fleetEnabled(true))
        #expect(settings.fleetEnabled)
        #expect(HostSettingChange.fleetEnabled(true).capability == RemoteProtocol.fleetExperimentCapability)
    }

    /// The Dispatch settings: Auto dispatch is unset until the person chooses (it reads as on with a second Mac paired); battery counts half.
    @Test func autoDispatchReadsAsOnOnceAMacIsPairedUntilTheUserChooses() throws {
        var settings = HostSettings()
        #expect(settings.fleetAutoDispatch == nil && settings.fleetBatteryCountsHalf && !settings.fleetThreadsCanSend)
        #expect(!settings.autoDispatch(pairedMacs: 0) && settings.autoDispatch(pairedMacs: 1))
        settings.apply(.fleetAutoDispatch(false))
        #expect(!settings.autoDispatch(pairedMacs: 2), "a choice beats the default")
        // A host from before these settings decodes with the defaults.
        var object = try Wire.object(HostSettings(fleetAutoDispatch: true, fleetBatteryCountsHalf: false))
        object["fleetAutoDispatch"] = nil
        object["fleetBatteryCountsHalf"] = nil
        let older = try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.fleetAutoDispatch == nil && older.fleetBatteryCountsHalf)
        #expect(HostSettingChange.fleetAutoDispatch(true).capability == RemoteProtocol.fleetDispatchCapability)
        #expect(HostSettingChange.fleetBatteryCountsHalf(false).capability == RemoteProtocol.fleetDispatchCapability)
    }

    /// A host from before Fleet says no id in `helloOk`; its client reads that as a Mac without a fleet identity.
    @Test func aHelloOkWithoutAHostIDIsAnOlderHost() throws {
        #expect(try Wire.decode(RemoteReply.self, #"{"type":"helloOk","id":1,"protocolVersion":1,"capabilities":[]}"#)
            == .helloOk(id: 1, protocolVersion: 1, capabilities: [], hostBuild: nil, hostID: nil))
        let object = try Wire.object(RemoteReply.helloOk(id: 1, protocolVersion: 1, capabilities: []))
        #expect(object["hostID"] == nil)
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
        settings.apply(.goalCrossProviderEvaluation(false))
        #expect(!settings.goalCrossProviderEvaluation)
        var expected = RemoteSamples.hostSettings
        expected.bundledExtensions[1].on = true
        expected.defaultModel = nil
        expected.mergeMethod = .merge
        expected.goalCrossProviderEvaluation = false
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

    /// Finalize was removed: a client from before still decodes `worktreeInfo`, whose `defaults`
    /// it requires, and its Finalize requests no longer decode, so the host refuses them as
    /// unknown by their id (`SessionServer.handleRemoteLine`).
    @Test func finalizeLeftoversStayReadableByOlderClients() throws {
        let info = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteWorktreeInfo(path: "/r", branch: "b", warning: nil))) as? [String: Any]
        let defaults = try #require(info?["defaults"] as? [String: Any])
        #expect(Set(defaults.keys) == ["base", "title", "body", "autoCommit", "deleteLocalBranch", "autoMergePR", "mergeMethod"])

        let known = Data(#"{"type":"agentQuery","id":7,"agentID":"a","query":{"worktreeInfo":{}}}"#.utf8)
        #expect(try NDJSON.decode(RemoteRequest.self, from: known) == .agentQuery(id: 7, agentID: AgentID(rawValue: "a"), query: .worktreeInfo))
        for query in [#"{"finalizeWorktree":{"operationID":"\#(UUID().uuidString)","options":{}}}"#,
                      #"{"worktreeSetup":{"action":{"check":{}}}}"#, #"{"worktreeCommitCount":{"base":"main"}}"#,
                      #"{"worktreeDescription":{"base":"main","title":"t"}}"#] {
            let line = Data(#"{"type":"agentQuery","id":7,"agentID":"a","query":\#(query)}"#.utf8)
            #expect(throws: (any Error).self) { try NDJSON.decode(RemoteRequest.self, from: line) }
            #expect((try JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? Int == 7)
        }
    }
}

@Suite("Remote protocol constants")
struct RemoteProtocolConstantTests {
    @Test func versionIsOne() {
        #expect(RemoteProtocol.version == 1)
    }

    @Test func hostAdvertisesEveryNamedCapabilityOnce() {
        let named = [RemoteProtocol.pushNotificationsCapability, RemoteProtocol.projectResultCapability, RemoteProtocol.moveThreadCapability, RemoteProtocol.projectConversationThinkingCapability,
            RemoteProtocol.logicalProjectsCapability, RemoteProtocol.logicalProjectAutomationsCapability,
            RemoteProtocol.logicalProjectRuntimeCapability, RemoteProtocol.projectExecutionCapability,
            RemoteProtocol.projectPlacementCapability, RemoteProtocol.logicalProjectFilesCapability, RemoteProtocol.projectWorkerCapability, RemoteProtocol.projectMessageImagesCapability, RemoteProtocol.projectPublicationsCapability,
            RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeThreadV2Capability,
            RemoteProtocol.nativeThreadRevisionsCapability, RemoteProtocol.nativeFleetDigestCapability,
            RemoteProtocol.nativeThreadStartingCapability, RemoteProtocol.nativeQueueCapability, RemoteProtocol.nativeStartupDialogsCapability,
            RemoteProtocol.pasteCapability, RemoteProtocol.paneControlCapability,
            RemoteProtocol.agentActionsCapability, RemoteProtocol.agentInspectionCapability,
            RemoteProtocol.worktreeActionsCapability, RemoteProtocol.worktreeRecordCapability, RemoteProtocol.worktreeMoveCapability,
            RemoteProtocol.uploadCapability, RemoteProtocol.creationOptionsCapability, RemoteProtocol.creationBranchesCapability,
            RemoteProtocol.automationsCapability,
            RemoteProtocol.terminalActivityCapability,
            RemoteProtocol.reviewCommitCapability,
            RemoteProtocol.thinkingLevelsCapability,
            RemoteProtocol.changesCapability,
            RemoteProtocol.nativeContextCapability,
            RemoteProtocol.createAgentImagesCapability,
            RemoteProtocol.instructionsCapability, RemoteProtocol.suggestionsCapability,
            RemoteProtocol.hostUpdateCapability, RemoteProtocol.hostSettingsCapability, RemoteProtocol.hostSettingsAgentDefaultsCapability, RemoteProtocol.hostSettingsTextGenerationModelCapability, RemoteProtocol.hostSettingsVisionModelCapability,
            RemoteProtocol.hostInventoryCapability, RemoteProtocol.changesRevertCapability, RemoteProtocol.changesCwdCapability,
            RemoteProtocol.skillsCapability, RemoteProtocol.projectsV2Capability, RemoteProtocol.projectDetailsCapability,
            RemoteProtocol.projectMCPCapability, RemoteProtocol.projectResourcesCapability, RemoteProtocol.projectInheritanceCapability, RemoteProtocol.projectInheritedResourcesCapability, RemoteProtocol.projectParentCapability, RemoteProtocol.piSkillsCapability,
            RemoteProtocol.terminalControlCapability, RemoteProtocol.terminalStartCapability, RemoteProtocol.checkoutReadCapability, RemoteProtocol.pullRequestLinkCapability,
            RemoteProtocol.designContextCapability,
            RemoteProtocol.nativeRetryCapability, RemoteProtocol.nativeThreadPreviewCapability,
            RemoteProtocol.checkpointRecoveryCapability,
            RemoteProtocol.nativeQueueSubagentCapability, RemoteProtocol.nativeInterruptCapability, RemoteProtocol.browserTunnelCapability, RemoteProtocol.browserDriveCapability,
            RemoteProtocol.browserTabsCapability,
            RemoteProtocol.nativeServiceTierCapability, RemoteProtocol.nativeImagesCapability,
            RemoteProtocol.createAgentServiceTierCapability,
            RemoteProtocol.nativeGoalCapability, RemoteProtocol.goalExperimentCapability, RemoteProtocol.projectsExperimentCapability,
            RemoteProtocol.designToolExperimentCapability,
            RemoteProtocol.hostSettingsV2Capability, RemoteProtocol.hostSettingsCloseOnMergeCapability, RemoteProtocol.hostSettingsBackgroundServiceCapability,
            RemoteProtocol.hostConfigCapability, RemoteProtocol.hooksCapability, RemoteProtocol.appsCapability, RemoteProtocol.appsV2Capability, RemoteProtocol.agentRestartCapability, RemoteProtocol.completionSeenCapability,
            RemoteProtocol.pushMuteCapability,
            RemoteProtocol.automationTriggersCapability, RemoteProtocol.forgeCapability, RemoteProtocol.forgeBrowseCapability,
            RemoteProtocol.fleetExperimentCapability,
            // Offered only while the host's Fleet experiment is on (SessionServer.setFleetEnabled).
            RemoteProtocol.fleetCapability, RemoteProtocol.fleetPressureCapability, RemoteProtocol.fleetDispatchCapability,
            RemoteProtocol.fleetSyncCapability, RemoteProtocol.fleetSnapshotCapability, RemoteProtocol.fleetRendezvousCapability, RemoteProtocol.fleetLinkCapability, RemoteProtocol.fleetPairLinkCapability,
            // Offered to every client, a device included, while the host's Fleet experiment is on.
            RemoteProtocol.fleetViewCapability, RemoteProtocol.fleetFollowCapability,
            // Offered whenever the host runs, Fleet on or off, and never to a client device (FleetAccess).
            RemoteProtocol.fleetDevicesCapability,
            // Offered only while the host's Design tool is on (SessionServer.setDesignsServed).
            RemoteProtocol.designsCapability, RemoteProtocol.designMarkupCapability, RemoteProtocol.designDeleteCapability,
            RemoteProtocol.designAgentCapability, RemoteProtocol.designLifecycleCapability, RemoteProtocol.designSystemsCapability,
            RemoteProtocol.designReferencesCapability, RemoteProtocol.designImportCapability, RemoteProtocol.designBoardsCapability, RemoteProtocol.designThreadNotesCapability,
            RemoteProtocol.designGitCapability,
            // Offered only to a client that lists it in hello.
            RemoteProtocol.filesCapability, RemoteProtocol.filesWriteCapability,
        ]
        #expect(Set(RemoteProtocol.capabilities) == Set(named))
        #expect(RemoteProtocol.capabilities.count == named.count)
    }

    /// Capability strings are negotiated with older peers; they must never be renamed.
    @Test func capabilityStringsAreStable() {
        #expect(RemoteProtocol.nativeThreadRevisionsCapability == "native.revisions.v1")
        #expect(RemoteProtocol.nativeFleetDigestCapability == "native.fleetDigest.v1")
        #expect(RemoteProtocol.fleetCapability == "fleet.v1")
        #expect(RemoteProtocol.fleetPressureCapability == "fleet.pressure.v1")
        #expect(RemoteProtocol.fleetSnapshotCapability == "fleet.snapshot.v1")
        #expect(RemoteProtocol.fleetRendezvousCapability == "fleet.rendezvous.v1")
        #expect(RemoteProtocol.fleetPairLinkCapability == "fleet.pairlink.v1")
        #expect(RemoteProtocol.fleetDispatchCapability == "fleet.dispatch.v1")
        #expect(RemoteProtocol.fleetDevicesCapability == "fleet.devices.v1")
        #expect(RemoteProtocol.fleetFollowCapability == "fleet.follow.v1")
        #expect(RemoteProtocol.fleetExperimentCapability == "experiments.fleet.v1")
        #expect(RemoteProtocol.logicalProjectsCapability == "logicalProjects.v1")
        #expect(RemoteProtocol.projectMessageImagesCapability == "logicalProjectRuntime.images.v1")
        #expect(RemoteProtocol.projectConversationThinkingCapability == "logicalProjects.conversationThinking.v1")
        #expect(RemoteProtocol.projectsCapability == "projects.v1")
        #expect(RemoteProtocol.projectsV2Capability == "projects.v2")
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.projectsV2Capability))
        #expect(!RemoteProtocol.capabilities.contains(RemoteProtocol.projectsCapability))
        #expect(RemoteProtocol.projectTrustCapability == "projects.trust.v1")
        #expect(RemoteProtocol.projectResourcesCapability == "projects.resources.v1")
        #expect(RemoteProtocol.projectInheritanceCapability == "projects.inheritance.v1")
        #expect(RemoteProtocol.projectInheritedResourcesCapability == "projects.inheritance.resources.v1")
        #expect(RemoteProtocol.projectParentCapability == "projects.parent.v1")
        #expect(RemoteProtocol.nativeThreadCapability == "native.thread.v1")
        #expect(RemoteProtocol.nativeThreadV2Capability == "native.thread.v2")
        #expect(RemoteProtocol.changesCapability == "changes.v1")
        #expect(RemoteProtocol.changesRevertCapability == "changes.revert.v1")
        #expect(RemoteProtocol.changesCwdCapability == "changes.cwd.v1")
        #expect(RemoteProtocol.hostSettingsAgentDefaultsCapability == "hostSettings.agentDefaults.v1")
        #expect(RemoteProtocol.hostSettingsTextGenerationModelCapability == "hostSettings.textGenerationModel.v1")
        #expect(RemoteProtocol.hostSettingsVisionModelCapability == "hostSettings.visionModel.v1")
        #expect(RemoteProtocol.hostInventoryCapability == "hostInventory.v1")
        #expect(RemoteProtocol.hostSettingsV2Capability == "hostSettings.v2")
        #expect(RemoteProtocol.hostSettingsCloseOnMergeCapability == "hostSettings.closeOnMerge.v1")
        #expect(RemoteProtocol.hostSettingsBackgroundServiceCapability == "hostSettings.backgroundService.v1")
        #expect(RemoteProtocol.hostConfigCapability == "hostConfig.v1")
        #expect(RemoteProtocol.designToolExperimentCapability == "experiments.designTool.v1")
        #expect(!RemoteProtocol.designCapabilities.contains(RemoteProtocol.designToolExperimentCapability))
        #expect(RemoteProtocol.filesCapability == "files.v1")
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.filesCapability))
        #expect(RemoteProtocol.nativeThreadStartingCapability == "native.thread.starting.v1")
        #expect(RemoteProtocol.nativeQueueCapability == "native.queue.v1")
        #expect(RemoteProtocol.nativeStartupDialogsCapability == "native.startup-dialogs.v1")
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.nativeStartupDialogsCapability))
        #expect(RemoteProtocol.pasteCapability == "session.paste.v1")
        #expect(RemoteProtocol.paneControlCapability == "pane.control.v1")
        #expect(RemoteProtocol.uploadCapability == "session.upload.v1")
        #expect(RemoteProtocol.terminalActivityCapability == "terminal.activity.v1")
        #expect(RemoteProtocol.terminalStartCapability == "terminal.start.v1")
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
        #expect(RemoteProtocol.browserTunnelCapability == "browser.tunnel.v1")
        #expect(RemoteProtocol.browserDriveCapability == "browser.drive.v1")
        #expect(RemoteProtocol.designContextCapability == "design.context.v1")
        #expect(RemoteProtocol.nativeRetryCapability == "native.retry.v1")
        #expect(RemoteProtocol.nativeInterruptCapability == "native.interrupt.v1")
        #expect(RemoteProtocol.nativeServiceTierCapability == "native.serviceTier.v1")
        #expect(RemoteProtocol.nativeImagesCapability == "native.images.v1")
        #expect(RemoteProtocol.designsCapability == "designs.v1")
        #expect(RemoteProtocol.designMarkupCapability == "design.markup.v1")
        #expect(RemoteProtocol.designDeleteCapability == "design.delete.v1")
        #expect(RemoteProtocol.designAgentCapability == "design.agent.v1")
        #expect(RemoteProtocol.designLifecycleCapability == "design.lifecycle.v1")
        #expect(RemoteProtocol.designSystemsCapability == "design.systems.v1")
        #expect(RemoteProtocol.designReferencesCapability == "design.references.v1")
        #expect(RemoteProtocol.designImportCapability == "design.import.v1")
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
