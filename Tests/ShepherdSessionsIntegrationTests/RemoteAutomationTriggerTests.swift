import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Trigger controls over the listener: status, pause and resume, Pause all, pending events and
/// settings on a draft, answered by the host's trigger engine.
@Suite("Remote automation triggers", .integrationTimeLimit)
struct RemoteAutomationTriggerTests {
    @Test func statusPauseResumeAndPauseAll() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let folder = try makeScratchDirectory("repo")
        let automation = Automation(name: "brief", prompt: "brief me", cwd: folder.path,
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")))
        try await remote.host.seed(ShepherdState(automations: [automation]))
        let client = try await remote.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.automationTriggersCapability))

        func status() async throws -> AutomationTriggerStatus {
            guard case .status(let status) = try await client.automation(automation.id, request: .status) else {
                throw CommandFailure("status", "not a status")
            }
            return status
        }
        #expect(try await status().state == .active)
        _ = try await client.automation(automation.id, request: .pause)
        #expect(try await status().state == .paused)
        _ = try await client.automation(automation.id, request: .resume)
        #expect(try await status().state == .active)
        _ = try await client.automation(automation.id, request: .setAllPaused(paused: true))
        let all = try await status()
        #expect(all.state == .paused && all.allPaused)
        _ = try await client.automation(automation.id, request: .setAllPaused(paused: false))
        // A pending event that isn't there is a clear refusal, not a silent ok.
        await #expect(throws: (any Error).self) {
            _ = try await client.automation(automation.id, request: .runEvent(eventID: "nope"))
        }
    }

    /// A draft's settings are validated by the host before anything is saved, and a draft
    /// without settings (an older client) keeps the trigger.
    @Test func draftSettings() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let folder = try makeScratchDirectory("repo")
        let server = remote.server
        server.onAutomationRequest = { request, respond in
            nonisolated(unsafe) let respond = respond
            Task {
                if case .create(let automation, _) = request { try? await server.addAutomation(automation) }
                if case .update(let id, _, let prompt, _, _, let settings) = request,
                   var saved = server.state.automations.first(where: { $0.id == id }) {
                    if let prompt { saved.prompt = prompt }
                    try? settings?.apply(to: &saved)
                    try? await server.updateAutomation(saved)
                }
                respond(.ok)
            }
        }
        let client = try await remote.typed()
        defer { client.disconnect() }
        let id = AutomationID()
        var draft = RemoteAutomationDraft(name: "loop", prompt: "p", cwd: folder.path, enabled: true,
                                          settings: AutomationSettings(trigger: .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY"))))
        await #expect(throws: (any Error).self) { _ = try await client.automation(id, request: .create(draft: draft)) }
        #expect(server.state.automations.isEmpty)

        draft.settings = AutomationSettings(trigger: .github([GitHubTrigger(repo: "acme/app", events: [.issueLabeled], labels: ["shepherd"])]))
        _ = try await client.automation(id, request: .create(draft: draft))
        try await eventually("the automation to save") { server.state.automations.first?.isTriggered == true }

        draft.settings = nil
        draft.prompt = "new prompt"
        _ = try await client.automation(id, request: .update(draft: draft))
        try await eventually("the edit to save") { server.state.automations.first?.prompt == "new prompt" }
        #expect(server.state.automations.first?.isTriggered == true)
    }
}
