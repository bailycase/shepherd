import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Push notifications", .integrationTimeLimit)
struct PushNotificationsTests {
    private func registration() -> RemotePushRegistration {
        .init(id: UUID().uuidString, sendToken: String(repeating: "a", count: 64))
    }

    @Test func authenticatedRegistrationPersistsPrivatelyAndRevocationCancels() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let registration = registration()
        let anonymous = try await host.raw(authenticated: false)
        try anonymous.send(.pushRegistration(id: 2, registration: registration))
        #expect(try await anonymous.disconnected())
        #expect(host.server.queue.sync { host.server.pushNotifications.registrations.isEmpty })
        let client = try await host.typed()
        defer { client.disconnect() }
        try await client.registerPush(registration)
        let file = host.host.dir.appendingPathComponent("push-registrations.json")
        let saved = try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file))
        #expect(saved == [registration])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let requests = Locked<[URLRequest]>([])
        let cancelled = Locked(0)
        host.server.queue.sync {
            host.server.pushNotifications.transport = { request, _ in
                requests.withValue { $0.append(request) }
                return { cancelled.withValue { $0 += 1 } }
            }
            host.server.pushNotifications.send(agentID: AgentID(), kind: .done)
        }
        try await client.unregisterPush(registration.id)
        #expect(cancelled.current == 1)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)).isEmpty)
        let restored = PushNotifications(file: file, queue: DispatchQueue(label: "push.restore"))
        #expect(restored.registrations.isEmpty)
        #expect(requests.current.count == 1)
    }

    @Test func payloadValidationRegistrationAndFlightCapsAndDeadline() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.bounds")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let requests = Locked<[URLRequest]>([])
        let cancelled = Locked(0)
        try queue.sync {
            pushes.transport = { request, _ in
                requests.withValue { $0.append(request) }
                return { cancelled.withValue { $0 += 1 } }
            }
            #expect(throws: PushNotifications.Failure.self) { try pushes.register(.init(id: "../escape", sendToken: String(repeating: "a", count: 64))) }
            #expect(throws: PushNotifications.Failure.self) { try pushes.register(.init(id: UUID().uuidString, sendToken: "secret\r\nheader")) }
            for _ in 0..<16 { try pushes.register(registration()) }
            #expect(throws: PushNotifications.Failure.self) { try pushes.register(registration()) }
            pushes.send(agentID: AgentID(), kind: .needsAnswer)
            pushes.send(agentID: AgentID(), kind: .error)
        }
        #expect(requests.current.count == 16)
        for request in requests.current {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "api.useshepherd.app")
            #expect(request.url?.path.hasPrefix("/api/push/registrations/") == true)
            #expect(request.url?.path.hasSuffix("/events") == true)
            #expect(request.httpMethod == "POST")
            #expect(request.timeoutInterval == 10)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64))
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(body.keys) == ["eventID", "agentID", "kind"])
            #expect(body["kind"] as? String == "needsAnswer")
        }
        try await eventually("hung transports cancelled at the ten second bound", timeout: .seconds(12)) { cancelled.current == 16 }
        #expect(requests.current.count == 16, "no retries")
    }

    @Test func relayNeverFollowsRedirects() throws {
        let url = URL(string: "https://api.useshepherd.app/api/push/registrations/id/events")!
        let task = PushHTTP.session.dataTask(with: url) // Never resumed: no network.
        defer { task.cancel() }
        let refused = Locked(false)
        PushHTTP().urlSession(PushHTTP.session, task: task,
            willPerformHTTPRedirection: try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)),
            newRequest: URLRequest(url: URL(string: "https://other.example/steal")!)) { request in
                refused.withValue { $0 = request == nil }
            }
        #expect(refused.current)
    }

    @Test func eventRateIsBoundedAndResetsWithoutReplay() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.rate")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let requests = Locked(0)
        try queue.sync {
            try pushes.register(registration())
            pushes.now = { Date(timeIntervalSince1970: 100) }
            pushes.transport = { _, finished in
                requests.withValue { $0 += 1 }
                finished(nil)
                return {}
            }
        }
        for _ in 0..<40 { queue.sync { pushes.send(agentID: AgentID(), kind: .done) } }
        #expect(requests.current == 30)
        queue.sync {
            pushes.now = { Date(timeIntervalSince1970: 160) }
            pushes.send(agentID: AgentID(), kind: .done)
        }
        #expect(requests.current == 31)
        let restored = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        #expect(restored.registrations.count == 1)
        #expect(requests.current == 31)
    }

    @Test func revokedRelaySlotsAreReclaimedButStaleResponsesAndOtherFailuresAreRetained() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.revocation")
        let file = dir.appendingPathComponent("push.json")
        let pushes = PushNotifications(file: file, queue: queue)
        let callbacks = Locked<[String: @Sendable (Int?) -> Void]>([:])
        let registrations = (0..<16).map { _ in registration() }
        try queue.sync {
            for registration in registrations { try pushes.register(registration) }
            pushes.transport = { request, finished in
                callbacks.withValue { $0[request.url!.deletingLastPathComponent().lastPathComponent] = finished }
                return {}
            }
            pushes.send(agentID: AgentID(), kind: .done)
        }
        let old = registrations[2]
        let replacement = RemotePushRegistration(id: old.id, sendToken: String(repeating: "b", count: 64))
        try queue.sync { try pushes.register(replacement) }
        callbacks.current[registrations[0].id]?(401)
        callbacks.current[registrations[1].id]?(410)
        callbacks.current[old.id]?(410)
        callbacks.current[registrations[3].id]?(500)
        callbacks.current[registrations[4].id]?(nil)
        try queue.sync {
            #expect(pushes.registrations.count == 14)
            #expect(pushes.registrations[old.id] == replacement)
            #expect(pushes.registrations[registrations[3].id] != nil)
            #expect(pushes.registrations[registrations[4].id] != nil)
            let restored = PushNotifications(file: file, queue: queue)
            #expect(restored.registrations == pushes.registrations)
            try pushes.register(registration())
            try pushes.register(registration())
            #expect(pushes.registrations.count == 16)
            #expect(throws: PushNotifications.Failure.self) { try pushes.register(registration()) }
            pushes.stop()
        }
        #expect(callbacks.current.count == 16, "revocation never retries")
    }

    private func record(_ server: SessionServer) throws -> Locked<[String]> {
        let events = Locked<[String]>([])
        try server.queue.sync {
            try server.pushNotifications.register(registration())
            server.pushNotifications.transport = { request, finished in
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                events.withValue { $0.append(body?["kind"] as? String ?? "invalid") }
                finished(nil)
                return {}
            }
        }
        return events
    }

    @Test func openingPromptQuestionsSettledCompletionAndProcessFailure() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let events = try record(host.server)
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        #expect(events.current.isEmpty, "startup history must not replay")
        await host.server.sendOpeningPrompt(try #require(OpeningPrompt("ask", agentID: pi.agent.id)), sessionID: pi.sessionID)
        let asked = try await pi.snapshot("opening prompt asks") { !$0.dialogs.isEmpty }
        try await eventually("one needsAnswer") { events.current == ["needsAnswer"] }
        _ = try await pi.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true)))
        try await eventually("settled answer") { events.current == ["needsAnswer", "done"] }
        _ = try await pi.snapshot()
        #expect(events.current == ["needsAnswer", "done"], "status revisions do not duplicate")
        _ = try await pi.send("provider-error", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        try Data().write(to: host.dir.appendingPathComponent("fail-turn"))
        try await eventually("settled provider failure") { events.current == ["needsAnswer", "done", "error"] }
        _ = try? await pi.send("die", from: try await pi.ready())
        try await eventually("unexpected process failure") { events.current == ["needsAnswer", "done", "error", "error"] }
    }

    @Test func retryInsideATurnDoesNotNotifyUntilFinalSettlement() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let events = try record(host.server)
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.send("tools:1 compact-retry", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        pi.finishTool(1)
        _ = try await pi.snapshot("compaction retry") { $0.messages.contains { $0.blocks.contains { $0.text.hasPrefix("Reply to") } } }
        #expect(events.current.isEmpty)
        try Data().write(to: host.dir.appendingPathComponent("compact-go"))
        try await eventually("retry final settlement") { events.current == ["done"] }
    }

    @Test func queuedWorkStopAndParentOnlyChildQuestionsDoNotNotifyEarly() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let events = try record(host.server)
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.send("slow", from: try await pi.ready())
        let running = try await pi.snapshot { $0.running }
        _ = try await pi.send("followup", from: running)
        let children = try ExtensionClient(path: host.socketPath)
        let rows = [ChildRun(runID: "child", label: "Child", state: "running", needsAttention: true, attentionText: "Choose")]
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: rows))
        _ = try await pi.snapshot("parent sees child question") { $0.subagents?.first?.needsAttention == true }
        #expect(events.current.isEmpty, "children ask the parent, not the user")
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: rows))
        pi.release(1)
        pi.release(2)
        _ = try await pi.snapshot("queued work finished") { !$0.running && $0.queue?.items.isEmpty != false }
        #expect(events.current.isEmpty)
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "child", label: "Child", state: "complete")]))
        try await eventually("all work settled") { events.current == ["done"] }
        _ = try await pi.send("tools:2", from: try await pi.ready())
        let active = try await pi.snapshot { $0.running }
        _ = try await pi.request(.abort(expectedSessionID: active.piSessionID, generation: active.generation, operationID: UUID()))
        _ = try await pi.snapshot("stopped") { !$0.running }
        #expect(events.current == ["done"])
    }
}
