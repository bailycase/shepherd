import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

@Suite("Remote wire protocol")
struct RemoteProtocolTests {
    @Test func requestsRoundTrip() throws {
        let requests: [RemoteRequest] = [
            .hello(id: 1, token: "deadbeef", clientName: "macbook", protocolVersion: 1),
            .hello(id: 2, token: "", clientName: "Baily's MacBook \"Pro\"", protocolVersion: 99),
            .stateFetch(id: 3),
            .agentQuery(id: 70, agentID: AgentID(), query: .inspectorPane(tabID: TabID(), action: .split(paneID: PaneID(), axis: .vertical))),
            .agentQuery(id: 71, agentID: AgentID(), query: .inspectorPane(tabID: TabID(), action: .close(paneID: PaneID()))),
            .agentQuery(id: 72, agentID: AgentID(), query: .inspectorPane(tabID: TabID(), action: .resize(split: .leaf(LeafPane(cwd: "/tmp")), ratio: 0.6))),
            .agentQuery(id: 60, agentID: AgentID(), query: .deleteKeepingWorktree),
            .agentQuery(id: 61, agentID: AgentID(), query: .reviewPane(paneID: PaneID(), pullRequest: true)),
            .agentQuery(id: 62, agentID: AgentID(), query: .finishReview(paneID: PaneID(), text: "feedback")),
            .agentQuery(id: 63, agentID: AgentID(), query: .deleteWorktree(operationID: UUID(), confirmedWarning: "dirty", fingerprint: "hash")),
            .upload(id: 50, action: .begin(sessionID: SessionID(), name: "image.png", size: 20)),
            .upload(id: 51, action: .chunk(uploadID: UUID(), data: Data([0, 1, 2]))),
            .upload(id: 52, action: .finish(uploadID: UUID())),
            .upload(id: 53, action: .cancel(uploadID: UUID())),
            .creationOptions(id: 54, spaceID: SpaceID(), cwd: "/host/repo", fetchFirst: false),
            .creationOptions(id: 55, spaceID: SpaceID(), cwd: nil, fetchFirst: nil),
            .createAgent(id: 56, spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil, worktreeBranch: "worktree/a", worktreeBase: "origin/release", worktreeFetchFirst: false),
            .agentQuery(id: 40, agentID: AgentID(), query: .worktreeSetup(action: .check)),
            .agentQuery(id: 41, agentID: AgentID(), query: .worktreeSetup(action: .applyIdentity(name: "O'Neil", email: "test@example.invalid"))),
            .agentQuery(id: 42, agentID: AgentID(), query: .worktreeSetup(action: .installCommandLineTools)),
            .agentQuery(id: 43, agentID: AgentID(), query: .worktreeSetup(action: .enableDeleteBranchOnMerge)),
            .agentQuery(id: 44, agentID: AgentID(), query: .worktreeSetup(action: .enableAutoMerge)),
            .agentQuery(id: 45, agentID: AgentID(), query: .worktreeSetup(action: .loginShell)),
            .agentQuery(id: 46, agentID: AgentID(), query: .worktreeCommitCount(base: "release")),
            .agentQuery(id: 47, agentID: AgentID(), query: .worktreeDescription(base: "release", title: "fix")),
            .agentQuery(id: 30, agentID: AgentID(), query: .review(pullRequest: true)),
            .agentQuery(id: 31, agentID: AgentID(), query: .children),
            .agentQuery(id: 32, agentID: AgentID(), query: .inspect(childID: "child")),
            .agentQuery(id: 33, agentID: AgentID(), query: .search(query: "prompt")),
            .agentQuery(id: 34, agentID: AgentID(), query: .worktreeInfo),
            .agentQuery(id: 35, agentID: AgentID(), query: .deleteWorktree(operationID: UUID(), confirmedWarning: "dirty")),
            .agentQuery(id: 36, agentID: AgentID(), query: .finalizeWorktree(operationID: UUID(), options: .init(base: "main", title: "fix", body: "details", autoCommit: false, deleteLocalBranch: false, autoMergePR: true, mergeMethod: "merge"))),
            .agentQuery(id: 37, agentID: AgentID(), query: .worktreeStatus(operationID: UUID())),
            .createAgent(id: 38, spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil, worktreeBranch: "worktree/test"),
            .agentAction(id: 20, agentID: AgentID(), action: .rename(name: "new \"name\"")),
            .agentAction(id: 21, agentID: AgentID(), action: .deleteKeepingWorktree),
            .agentAction(id: 22, agentID: AgentID(), action: .reorder(target: AgentID())),
            .attach(id: 4, sessionID: SessionID(), cols: 120, rows: 40, viewportGeneration: 2),
            .detach(sessionID: SessionID()),
            .input(sessionID: SessionID(), data: Data([0x1B, 0x5B, 0x41])),
            .resize(sessionID: SessionID(), cols: 80, rows: 24, viewportGeneration: 3),
            .paste(id: 12, sessionID: SessionID(), text: "multi\nline \"prompt\"", submit: true),
            .paste(id: 13, sessionID: SessionID(), text: "", submit: false),
            .openPane(id: 14, agentID: AgentID(), axis: .vertical, relativeTo: PaneID()),
            .closePane(id: 15, agentID: AgentID(), paneID: PaneID()),
            .resizePaneSplit(
                id: 16,
                agentID: AgentID(),
                split: .split(
                    axis: .vertical,
                    ratio: 0.5,
                    first: .leaf(LeafPane(cwd: "/tmp")),
                    second: .leaf(LeafPane(cwd: "/tmp"))
                ),
                ratio: 0.7
            ),
            .listDir(id: 8, path: ""),
            .listModels(id: 10),
            .listDir(id: 9, path: "/Users/demo/Developer"),
            .addSpace(id: 5, path: "/Users/demo/Developer/project"),
            .createAgent(
                id: 6,
                spaceID: SpaceID(),
                cwd: "/tmp/checkout",
                model: "anthropic/claude-4",
                thinking: .high,
                initialPrompt: "fix the \"thing\"\nplease"
            ),
            .createAgent(id: 7, spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil),
        ]
        for request in requests {
            let line = try NDJSON.encode(request)
            #expect(line.last == 0x0A)
            let decoded = try NDJSON.decode(RemoteRequest.self, from: line.dropLast())
            #expect(decoded == request)
        }
    }

    @Test func repliesRoundTrip() throws {
        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])

        let replies: [RemoteReply] = [
            .helloOk(id: 1, protocolVersion: 1, capabilities: RemoteProtocol.capabilities),
            .ok(id: 12),
            .agentResult(id: 70, result: .inspectorFocus(PaneID())),
            .agentResult(id: 60, result: .ok),
            .uploadResult(id: 50, result: .ready(uploadID: UUID())),
            .uploadResult(id: 51, result: .complete(path: "/host/private/image.png")),
            .creationOptions(id: 52, options: .init(base: "origin/main", note: "cached", fetchFirst: false, model: "host/model", thinking: .high)),
            .agentResult(id: 40, result: .worktreeSetup(.init(repoPath: "/host/repo", checks: ["git": .pass("installed"), "identity": .fail("missing"), "remote": .checking, "gh": .pending], repoSettings: ["allowAutoMerge": .disabled, "deleteBranchOnMerge": .unavailable("admin required")]))),
            .agentResult(id: 41, result: .worktreeCommitCount(23)),
            .agentResult(id: 42, result: .worktreeCommitCount(nil)),
            .agentResult(id: 43, result: .worktreeDescription(body: "## Summary\nHost changes")),
            .agentResult(id: 30, result: .review(files: Data("[]".utf8), reference: "origin/main")),
            .agentResult(id: 31, result: .children([ChildRun(runID: "run", label: "child", state: "running")])),
            .agentResult(id: 32, result: .inspector(TabID())),
            .agentResult(id: 33, result: .search(snippet: "matched text")),
            .agentResult(id: 34, result: .worktreeInfo(.init(path: "/tmp/repo", branch: "worktree/test", warning: nil, defaults: .init(base: "main", title: "fix", body: "", autoCommit: true, deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash")))),
            .agentResult(id: 35, result: .worktreeOperation(.init(id: UUID(), finished: true, error: "failed", progress: ["push failed"], prURL: nil))),
            .paneOpened(id: 14, paneID: PaneID()),
            .error(id: 2, code: "unauthorized", message: "bad token"),
            .state(id: 3, state: state),
            .state(id: 4, state: ShepherdState()),
            .stateChanged(state: state),
            .attached(id: 5, attachment: RemoteAttachment(sessionID: SessionID(), cols: 80, rows: 24, viewportGeneration: 2)),
            .output(sessionID: SessionID(), data: Data("screen bytes \u{1B}[31m".utf8)),
            .sessionExited(sessionID: SessionID(), code: 0),
            .sessionExited(sessionID: SessionID(), code: nil),
            .dirListing(id: 8, path: "/Users/demo", parent: "/Users", dirs: ["Developer", "Documents"]),
            .dirListing(id: 9, path: "/", parent: nil, dirs: []),
            .models(id: 10, models: ["anthropic/claude-4", "openai/gpt-5"], defaultModel: "anthropic/claude-4"),
            .models(id: 11, models: [], defaultModel: nil),
            .spaceAdded(id: 6, spaceID: SpaceID()),
            .agentCreated(id: 7, agentID: AgentID()),
        ]
        for reply in replies {
            let line = try NDJSON.encode(reply)
            #expect(line.last == 0x0A)
            let decoded = try NDJSON.decode(RemoteReply.self, from: line.dropLast())
            #expect(decoded == reply)
        }
    }

    @Test func composedInputIsOneBracketedPasteAndOptionalReturn() {
        #expect(
            RemoteProtocol.composedInput(text: "one\ntwo", submit: true)
                == Data("\u{1B}[200~one\ntwo\u{1B}[201~\r".utf8)
        )
        #expect(
            RemoteProtocol.composedInput(text: "draft", submit: false)
                == Data("\u{1B}[200~draft\u{1B}[201~".utf8)
        )
    }

    @Test func legacyHelloWithoutCapabilitiesStillDecodes() throws {
        let wire = Data(#"{"type":"helloOk","id":1,"protocolVersion":1}"#.utf8)
        #expect(
            try NDJSON.decode(RemoteReply.self, from: wire)
                == .helloOk(id: 1, protocolVersion: 1, capabilities: [])
        )
    }

    /// The `type` discriminator is the wire contract: a host must be able to
    /// reject unknown request kinds cleanly rather than misdecoding them.
    @Test func unknownKindFailsToDecode() {
        let wire = Data(#"{"type":"launchMissiles","id":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try NDJSON.decode(RemoteRequest.self, from: wire)
        }
    }
}
