import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The client's decisions that happen before any byte is written: capability gates on a host
/// that advertised nothing, requests on a closed connection, and connect failures from an
/// injected socket opener. Nothing here opens a socket.
@Suite("Remote host client (no connection)")
struct RemoteHostClientTests {
    private func code(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let error as RemoteHostClientError {
            switch error {
            case .rejected(let code, _): return code
            case .disconnected: return "disconnected"
            default: return String(describing: error)
            }
        } catch { return String(describing: error) }
    }

    @Test(arguments: [
        (RemoteHostClientError.resolveFailed(host: "mini.local"), "could not resolve mini.local"),
        (.rejected(code: "unauthorized", message: "bad token"), "unauthorized: bad token"),
        (.outcomeUnknown(message: "Refresh first."), "Refresh first."),
        (.disconnected, "connection closed"),
        (.timeout, "request timed out"),
        (.system(call: "connect", errno: ECONNREFUSED), "connect failed: Connection refused (errno 61)"),
    ])
    func errorsDescribeThemselves(error: RemoteHostClientError, description: String) {
        #expect(error.description == description)
    }

    @Test func aNewClientAdvertisesNoCapabilities() {
        #expect(RemoteHostClient().capabilities.isEmpty)
    }

    /// A host from before `native_starting` said `native_unavailable` while an agent's pi
    /// started; only its answers are read as starting.
    @Test(arguments: [
        (NativeThreadCode.unavailable, true, NativeThreadCode.starting),
        (NativeThreadCode.unavailable, false, NativeThreadCode.unavailable),
        (NativeThreadCode.starting, false, NativeThreadCode.starting),
        ("stale_session", true, "stale_session"),
    ])
    func olderHostsUnavailableThreadsReadAsStarting(code: String, legacyHost: Bool, read: String) {
        #expect(RemoteHostClient.availabilityCode(code, legacyHost: legacyHost) == read)
    }

    /// An older host shows its automations read-only: nothing is sent to it.
    @Test(arguments: [RemoteAutomationRequest.setEnabled(enabled: true), .run, .stop, .runs, .delete,
                      .create(draft: RemoteAutomationDraft(name: "n", prompt: "p", cwd: "/", enabled: true))])
    func automationsNeedAHostThatAdvertisesThem(_ request: RemoteAutomationRequest) async {
        let client = RemoteHostClient()
        #expect(await code { try await client.automation(AutomationID(), request: request) } == "update_required")
    }

    @Test(arguments: [
        NativeThreadRequest.snapshot(),
        .setModel(expectedSessionID: "s", generation: "g", operationID: UUID(), model: "p/m"),
        .send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "t", delivery: .followUp,
              images: [NativeImage(mimeType: "image/png", data: Data([1]))]),
    ])
    func nativeThreadsNeedAHostThatAdvertisesThem(_ request: NativeThreadRequest) async {
        let client = RemoteHostClient()
        #expect(await code { _ = try await client.nativeThread(agentID: AgentID(), request: request) } == "update_required")
    }

    @Test(arguments: [
        RemoteAgentQuery.children, .review(pullRequest: false), .search(query: "q"),
        .worktreeInfo, .worktreeStatus(operationID: UUID()), .deleteKeepingWorktree,
        .worktreeSetup(action: .check), .worktreeCommitCount(base: "main"), .worktreeDescription(base: "main", title: "t"),
    ])
    func agentQueriesAreGatedBeforeSending(_ query: RemoteAgentQuery) async {
        let client = RemoteHostClient()
        #expect(await code { _ = try await client.agentQuery(agentID: AgentID(), query: query) } == "update_required")
    }

    @Test(arguments: [RemoteAgentAction.rename(name: "t"), .deleteKeepingWorktree, .reorder(target: AgentID())])
    func agentActionsAreGatedBeforeSending(_ action: RemoteAgentAction) async {
        let client = RemoteHostClient()
        #expect(await code { try await client.agentAction(agentID: AgentID(), action: action) } == "update_required")
    }

    @Test func paneControlNeedsAHostThatSupportsIt() async {
        let client = RemoteHostClient()
        #expect(await code { try await client.openPane(agentID: AgentID(), relativeTo: PaneID(), axis: .vertical) } == "unsupported")
        #expect(await code { try await client.closePane(agentID: AgentID(), paneID: PaneID()) } == "unsupported")
        #expect(await code { try await client.resizePaneSplit(agentID: AgentID(), split: .leaf(LeafPane(cwd: "/")), ratio: 0.5) } == "unsupported")
    }

    @Test func uploadsAreRefusedWithoutReadingTheFile() async {
        let client = RemoteHostClient()
        #expect(await code { _ = try await client.upload(file: URL(fileURLWithPath: "/must-not-read"), sessionID: SessionID()) } == "update_required")
    }

    @Test func worktreeCreationOptionsNeedAHostThatSupportsThem() async {
        let client = RemoteHostClient()
        #expect(await code { _ = try await client.creationOptions(spaceID: SpaceID(), cwd: "/must-not-probe", fetchFirst: nil) } == "update_required")
        #expect(await code { _ = try await client.creationOptions(spaceID: SpaceID(), cwd: nil, fetchFirst: false) } == "update_required")
        #expect(await code {
            _ = try await client.createAgent(spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil, worktreeBranch: "w/x")
        } == "update_required")
        #expect(await code {
            _ = try await client.createAgent(spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil, worktreeBase: "main")
        } == "update_required")
    }

    /// A request on a closed connection is refused before it is written, so it is safe to retry.
    @Test func requestsWithoutAConnectionAreNotSent() async {
        let client = RemoteHostClient()
        #expect(await code { _ = try await client.attach(sessionID: SessionID(), cols: 80, rows: 24) } == "not_sent")
        #expect(await code { _ = try await client.listDir(path: "") } == "not_sent")
        #expect(await code { _ = try await client.listModels() } == "not_sent")
        #expect(await code { _ = try await client.addSpace(path: "/tmp") } == "not_sent")
    }

    @Test func aLegacyPasteWithoutAConnectionReportsDisconnected() async {
        let client = RemoteHostClient()
        #expect(await code { try await client.paste(sessionID: SessionID(), text: "hi", submit: true) } == "disconnected")
    }

    @Test func fireAndForgetCallsWithoutAConnectionAreHarmless() {
        let client = RemoteHostClient()
        client.write(sessionID: SessionID(), data: Data("x".utf8))
        client.resize(sessionID: SessionID(), cols: 80, rows: 24)
        client.detach(sessionID: SessionID())
        client.disconnect()
        #expect(client.capabilities.isEmpty)
    }

    @Test func aFailedSocketOpenFailsConnectAndLeavesTheClientReusable() async {
        let attempts = Counter()
        let client = RemoteHostClient { host, _ in
            attempts.increment()
            throw RemoteHostClientError.resolveFailed(host: host)
        }
        for _ in 0..<2 {
            #expect(await code { _ = try await client.connect(host: "nowhere.invalid", port: 7433, token: "t", clientName: "c") }
                == "could not resolve nowhere.invalid")
        }
        #expect(attempts.value == 2, "a failed attempt must not leave the client looking connected")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
