import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Automations over the listener: every change a remote client asks for reaches the same
/// handler an agent's `automation_*` tools reach, the host checks what it can before asking,
/// and the runs it keeps follow each automation's agent across agents and launches.
@Suite("Remote automations", .integrationTimeLimit)
struct RemoteAutomationTests {
    static let draft = RemoteAutomationDraft(name: "  Nightly dry run ", prompt: "Run every migration", cwd: "", enabled: false)

    /// A host with one automation, a hidden space for its runs, and a handler that answers like
    /// the app's for the requests the test needs (it records every one).
    struct Host {
        let remote: RemoteHost
        let automation: Automation
        let runSpace: Space
        let folder: URL
        let seen = Locked<[AutomationRequest]>([])

        init() async throws {
            remote = try RemoteHost()
            folder = try makeScratchDirectory("repo")
            runSpace = Space(name: "Automations", path: "~", hidden: true)
            automation = Automation(name: "watch CI", prompt: "watch", cwd: folder.path, enabled: true)
            try await remote.host.seed(ShepherdState(spaces: [runSpace], automations: [automation]))
            let (server, seen) = (remote.server, seen)
            server.onAutomationRequest = { request, respond in
                seen.withValue { $0.append(request) }
                // The server takes the answer from any thread.
                nonisolated(unsafe) let respond = respond
                Task {
                    do {
                        switch request {
                        case .update(let id, _, _, _, let enabled):
                            if var saved = server.state.automations.first(where: { $0.id == id }), let enabled {
                                saved.enabled = enabled
                                try await server.updateAutomation(saved)
                            }
                        case .create(let automation, _): try await server.addAutomation(automation)
                        case .delete(let id): try await server.removeAutomation(id)
                        case .start, .stop, .list: break
                        }
                        respond(.ok)
                    } catch {
                        respond(.failed(code: "failed", message: String(describing: error)))
                    }
                }
            }
        }

        func stop() {
            remote.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Changes

    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case switchOff, run, stop, edit, delete
        var testDescription: String { rawValue }
    }

    /// Each change travels as the matching `AutomationRequest`, and the host answers ok.
    @Test(arguments: Change.allCases)
    func aChangeReachesTheAutomationHandler(_ change: Change) async throws {
        let h = try await Host()
        defer { h.stop() }
        let client = try await h.remote.typed()
        defer { client.disconnect() }
        let id = h.automation.id
        var draft = Self.draft
        draft.cwd = h.folder.path

        let expected: AutomationRequest
        switch change {
        case .switchOff:
            try await client.automation(id, request: .setEnabled(enabled: false))
            expected = .update(automationID: id, name: nil, prompt: nil, cwd: nil, enabled: false)
            #expect(h.remote.server.state.automations.map(\.enabled) == [false])
        case .run:
            try await client.automation(id, request: .run)
            expected = .start(automationID: id)
        case .stop:
            try await client.automation(id, request: .stop)
            expected = .stop(automationID: id)
        case .edit:
            try await client.automation(id, request: .update(draft: draft))
            expected = .update(automationID: id, name: "Nightly dry run", prompt: "Run every migration", cwd: h.folder.path,
                               enabled: false)
        case .delete:
            try await client.automation(id, request: .delete)
            expected = .delete(automationID: id)
            #expect(h.remote.server.state.automations.isEmpty)
        }
        #expect(h.seen.current == [expected])
    }

    /// A new automation is saved under the id the client minted, trimmed, and not started.
    @Test func createSavesUnderTheClientsIDWithoutStartingARun() async throws {
        let h = try await Host()
        defer { h.stop() }
        let client = try await h.remote.typed()
        defer { client.disconnect() }
        let minted = AutomationID()
        var draft = Self.draft
        draft.cwd = h.folder.path

        try await client.automation(minted, request: .create(draft: draft))

        let saved = Automation(id: minted, name: "Nightly dry run", prompt: "Run every migration", cwd: h.folder.path, enabled: false)
        #expect(h.seen.current == [.create(automation: saved, start: false)])
        #expect(h.remote.server.state.automations.last == saved)
        try await eventually("the new automation to broadcast") { h.remote.host.broadcasts.current.last?.automations.last == saved }
    }

    /// What the host can check itself never reaches the handler.
    @Test(arguments: [
        ("blank name", "invalid_automation"), ("blank prompt", "invalid_automation"), ("missing folder", "no_such_directory"),
        ("relative folder", "no_such_directory"), ("existing id", "conflict"), ("unknown automation", "no_such_automation"),
    ])
    func theHostRefusesWhatItCanCheck(_ scenario: String, code: String) async throws {
        let h = try await Host()
        defer { h.stop() }
        let raw = try await h.remote.raw()
        var draft = Self.draft
        draft.cwd = h.folder.path
        var target = AutomationID()
        switch scenario {
        case "blank name": draft.name = "  \n"
        case "blank prompt": draft.prompt = " "
        case "missing folder": draft.cwd = "/definitely/not/a/dir"
        case "relative folder": draft.cwd = "repo"
        case "existing id": target = h.automation.id
        default: break
        }
        let request: RemoteAutomationRequest = scenario == "unknown automation" ? .run : .create(draft: draft)

        try raw.send(.automation(id: 7, automationID: target, request: request))

        guard case .error(7, let replied, _) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(replied == code)
        #expect(h.seen.current.isEmpty)
        #expect(h.remote.server.state.automations == [h.automation])
    }

    @Test func aHostWithoutTheAppRefusesChangesButStillReadsRuns() async throws {
        let h = try await Host()
        defer { h.stop() }
        h.remote.server.onAutomationRequest = nil
        let raw = try await h.remote.raw()

        try raw.send(.automation(id: 3, automationID: h.automation.id, request: .run))
        guard case .error(3, "unsupported", _) = try await raw.next() else { Issue.record("expected unsupported"); return }
        try raw.send(.automation(id: 4, automationID: h.automation.id, request: .runs))
        #expect(try await raw.next() == .automationResult(id: 4, result: .runs([])))
    }

    @Test func aHandlerFailureReachesTheClient() async throws {
        let h = try await Host()
        defer { h.stop() }
        h.remote.server.onAutomationRequest = { _, respond in respond(.failed(code: "failed", message: "automation no longer exists")) }
        let client = try await h.remote.typed()
        defer { client.disconnect() }

        await #expect(throws: RemoteHostClientError.self) { try await client.automation(h.automation.id, request: .run) }
        #expect(client.capabilities.contains(RemoteProtocol.automationsCapability))
    }

    // MARK: - Runs

    /// A run opens when its automation gains an agent, follows that agent's status, and closes
    /// when the agent goes; its agent is offered only while it exists.
    @Test func runsFollowTheAutomationsAgent() async throws {
        let h = try await Host()
        defer { h.stop() }
        let server = h.remote.server
        let client = try await h.remote.typed()
        defer { client.disconnect() }
        let first = Fixture.agent(in: h.runSpace, name: "watch CI", status: .working)
        var automation = h.automation
        automation.agentID = first.agent.id
        try await server.putState(ShepherdState(spaces: [h.runSpace], tabs: [first.tab], agents: [first.agent],
                                                automations: [automation]))

        var runs = try await client.automationRuns(automation.id)
        #expect(runs.map(\.result) == [.running] && runs.map(\.agentID) == [first.agent.id])

        let ext = try ExtensionClient(path: h.remote.host.socketPath)
        for (status, result) in [(AgentStatus.blocked, AutomationRunResult.needsYou), (.done, .finished)] {
            try ext.send(.setAgentStatus(agentID: first.agent.id, status: status))
            try await eventually("the run to read \(result)") { await server.automationRuns(automation.id).last?.result == result }
        }
        try await server.deleteAgent(first.agent.id)

        runs = try await client.automationRuns(automation.id)
        let ended = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(ended.result == .finished && ended.agentID == nil)
        #expect(ended.settledAt != nil && ended.endedAt != nil)

        // A second run, stopped mid-turn.
        let second = Fixture.agent(in: h.runSpace, name: "watch CI", status: .working)
        automation.agentID = second.agent.id
        try await server.putState(ShepherdState(spaces: [h.runSpace], tabs: [second.tab], agents: [second.agent],
                                                automations: [automation]))
        try await server.deleteAgent(second.agent.id)
        #expect(try await client.automationRuns(automation.id).map(\.result) == [.finished, .stopped])
    }

    /// The runs outlive the host's launch; one still going when it quit reads as interrupted.
    @Test func runsSurviveARestartAndAnOpenOneReadsInterrupted() async throws {
        let first = try ScratchServer()
        let runSpace = Space(name: "Automations", path: "~", hidden: true)
        let run = Fixture.agent(in: runSpace, name: "watch CI", status: .working)
        var automation = Automation(name: "watch CI", prompt: "watch", cwd: first.dir.path, enabled: true)
        automation.agentID = run.agent.id
        try await first.server.putState(ShepherdState(spaces: [runSpace], tabs: [run.tab], agents: [run.agent],
                                                      automations: [automation]))
        #expect(await first.server.automationRuns(automation.id).map(\.result) == [.running])
        first.stop(keepFiles: true)

        let second = try ScratchServer(dir: first.dir)
        defer { second.stop() }
        let runs = await second.server.automationRuns(automation.id)
        #expect(runs.map(\.result) == [.interrupted])
        #expect(runs.first?.endedAt != nil && runs.first?.agentID == nil)
    }

    @Test func removingAnAutomationForgetsItsRuns() async throws {
        let h = try await Host()
        defer { h.stop() }
        let server = h.remote.server
        let run = Fixture.agent(in: h.runSpace, name: "watch CI", status: .done)
        var automation = h.automation
        automation.agentID = run.agent.id
        try await server.putState(ShepherdState(spaces: [h.runSpace], tabs: [run.tab], agents: [run.agent], automations: [automation]))
        #expect(await server.automationRuns(automation.id).count == 1)

        try await server.removeAutomation(automation.id)
        #expect(await server.automationRuns(automation.id).isEmpty)
    }
}
