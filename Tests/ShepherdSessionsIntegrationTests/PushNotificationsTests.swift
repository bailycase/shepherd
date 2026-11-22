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

    private typealias Mac = FleetPairingTests.Mac
    private typealias Device = FleetDevicesIntegrationTests.Device

    private func connect(_ device: Device, to mac: Mac) async throws -> RemoteHostClient {
        let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await device.pair(with: mac, code: code)
        return try await device.connect(to: mac)
    }

    @Test(arguments: [false, true])
    func revokingAPairedDeviceStopsItsDelivery(fromAnotherMac: Bool) async throws {
        let mac = try await Mac("Acme Studio")
        defer { mac.stop() }
        let peer = fromAnotherMac ? try await Mac("Acme Mini") : nil
        defer { peer?.stop() }
        if let peer {
            try await mac.pair(with: peer, code: try await peer.startJoin())
            try await mac.waitForLink(to: peer)
        }
        let phone = Device(), pad = Device("iPad", kind: .ipad)
        defer { phone.stop(); pad.stop() }
        let revoked = registration(), retained = registration()
        try await connect(phone, to: mac).registerPush(revoked)
        try await connect(pad, to: mac).registerPush(retained)
        let file = mac.host.dir.appendingPathComponent("push-registrations.json")
        let backup = try Data(contentsOf: file)
        let posted = Locked<[String]>([])
        let cancelled = Locked<[String]>([])
        await mac.server.queue.testHop {
            mac.server.pushNotifications.transport = { request, _ in
                let id = request.url!.deletingLastPathComponent().lastPathComponent
                posted.withValue { $0.append(id) }
                return { cancelled.withValue { $0.append(id) } }
            }
            mac.server.pushNotifications.send(agentID: AgentID(), kind: .done, title: "Acme build", preview: "First turn")
        }
        #expect(Set(posted.current) == [revoked.id, retained.id])
        _ = try await (peer ?? mac).local.fleetAction(.revokeDevice(phone.intro.deviceID))
        try await eventually("the revoked device disconnects") { phone.disconnected.current }
        posted.withValue { $0.removeAll() }
        await mac.server.queue.testHop {
            mac.server.pushNotifications.send(agentID: AgentID(), kind: .done, title: "Acme build", preview: "Next turn")
        }
        #expect(posted.current == [retained.id], "only the still-paired device receives the next alert")
        #expect(cancelled.current == [revoked.id], "only the revoked device's pending delivery is cancelled")
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)) == [retained])

        // A restored backup must not start sending to a device that was revoked after it was taken.
        try backup.write(to: file, options: .atomic)
        posted.withValue { $0.removeAll() }
        await mac.server.queue.testHop {
            mac.server.pushNotifications.send(agentID: AgentID(), kind: .done, title: "Acme build", preview: "Another turn")
        }
        #expect(posted.current == [retained.id])
    }

    @Test func aRepairedDeviceReclaimsItsRegistrationFromARestoredFile() async throws {
        let mac = try await Mac("Acme Studio")
        defer { mac.stop() }
        let oldPhone = Device(), newPhone = Device()
        defer { oldPhone.stop(); newPhone.stop() }
        let old = registration()
        try await connect(oldPhone, to: mac).registerPush(old)
        let file = mac.host.dir.appendingPathComponent("push-registrations.json")
        let backup = try Data(contentsOf: file)
        _ = try await mac.local.fleetAction(.revokeDevice(oldPhone.intro.deviceID))
        try backup.write(to: file, options: .atomic)

        let replacement = RemotePushRegistration(id: old.id, sendToken: String(repeating: "b", count: 64))
        try await connect(newPhone, to: mac).registerPush(replacement)
        let rows = try JSONDecoder().decode([PushNotifications.Registration].self, from: Data(contentsOf: file))
        #expect(rows == [.init(id: old.id, sendToken: replacement.sendToken, preferences: nil, deviceID: newPhone.intro.deviceID)])
        let posted = Locked<[URLRequest]>([])
        await mac.server.queue.testHop {
            let pushes = mac.server.pushNotifications
            pushes.transport = { request, _ in
                posted.withValue { $0.append(request) }
                return {}
            }
            pushes.send(agentID: AgentID(), kind: .done, title: "Acme build")
        }
        let request = try #require(posted.current.first)
        #expect(posted.current.count == 1)
        #expect(request.url?.deletingLastPathComponent().lastPathComponent == replacement.id)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(replacement.sendToken)")
    }

    @Test(arguments: [false, true])
    func registerKeepsRowsWithoutRevocationEvidence(pairingStoreUnreadable: Bool) async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fleetDir = dir.appendingPathComponent("fleet", isDirectory: true)
        try FileManager.default.createDirectory(at: fleetDir, withIntermediateDirectories: true)
        if pairingStoreUnreadable {
            try Data("not valid JSON".utf8).write(to: fleetDir.appendingPathComponent(FleetDevices.fileName))
        } else {
            try FleetDevices().save(to: fleetDir)
        }
        let file = dir.appendingPathComponent("push-registrations.json")
        let old = registration()
        let owned = PushNotifications.Registration(id: old.id, sendToken: old.sendToken, preferences: nil, deviceID: UUID())
        try JSONEncoder().encode([owned]).write(to: file)
        let mac = try await Mac("Acme Studio", dir: dir)
        defer { mac.stop(keepFiles: true) }
        let added = registration()
        try await mac.local.registerPush(added)
        let rows = try JSONDecoder().decode([PushNotifications.Registration].self, from: Data(contentsOf: file))
        #expect(rows.count == 2)
        #expect(rows.contains(owned))
        #expect(rows.contains { $0.id == added.id })
    }

    @Test func aPeerMacIsNotOfferedPushAndCannotRegister() async throws {
        let mac = try await Mac("Acme Studio"), peer = try await Mac("Acme Mini")
        defer { mac.stop(); peer.stop() }
        try await peer.pair(with: mac, code: try await mac.startJoin())
        let token = try #require(peer.record(of: mac.name)["myToken"] as? String)
        let client = try RawRemote(port: mac.port)
        let capability = RemoteProtocol.pushNotificationsCapability
        let offered = try await client.hello(token: token, capabilities: [capability])
        #expect(!offered.contains(capability))
        try client.send(.pushRegistration(id: 2, registration: registration()))
        _ = try await client.frames(until: {
            switch $0 {
            case .error(2, let code, _):
                #expect(code == "unsupported")
                return true
            case .ok(2):
                Issue.record("Peer Mac was allowed to register for push")
                return true
            default: return false
            }
        })
        #expect(!FileManager.default.fileExists(atPath: mac.host.dir.appendingPathComponent("push-registrations.json").path))
    }

    @Test func devicesCannotChangeEachOthersRegistrations() async throws {
        let mac = try await Mac("Acme Studio")
        defer { mac.stop() }
        let phone = Device(), pad = Device("iPad", kind: .ipad)
        defer { phone.stop(); pad.stop() }
        let owner = try await connect(phone, to: mac)
        let other = try await connect(pad, to: mac)
        let original = registration(), unused = registration()
        let replacement = RemotePushRegistration(id: original.id, sendToken: String(repeating: "b", count: 64),
                                                 preferences: .init(topics: [.questions]))
        try await owner.registerPush(original)
        // Valid unknown IDs get ok for both actions. A foreign ID must also get ok, but keep its owner and contents.
        try await other.registerPush(unused)
        try await other.unregisterPush(unused.id)
        let file = mac.host.dir.appendingPathComponent("push-registrations.json")
        try await other.registerPush(replacement)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)) == [original],
                "another device cannot overwrite the send credential or preferences")
        try await other.unregisterPush(original.id)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)) == [original],
                "another device cannot remove the registration")
        try await owner.registerPush(replacement)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)) == [replacement])
        try await owner.unregisterPush(replacement.id)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)).isEmpty)
    }

    @Test func oneDeviceLeavesRegistrationSlotsForAnother() async throws {
        let mac = try await Mac("Acme Studio")
        defer { mac.stop() }
        let phone = Device(), pad = Device("iPad", kind: .ipad)
        defer { phone.stop(); pad.stop() }
        let first = try await connect(phone, to: mac)
        let second = try await connect(pad, to: mac)
        let original = registration()
        try await first.registerPush(original)
        let secondSlot = registration(), overLimit = registration(), otherDevice = registration()
        try await first.registerPush(secondSlot)
        await #expect {
            try await first.registerPush(overLimit)
        } throws: { error in
            if case RemoteHostClientError.rejected("push_registration", _) = error { return true }
            return false
        }
        try await second.registerPush(otherDevice)
        // A device at its limit can still update its existing registration.
        try await first.registerPush(original)
        let file = mac.host.dir.appendingPathComponent("push-registrations.json")
        let rows = try JSONDecoder().decode([PushNotifications.Registration].self, from: Data(contentsOf: file))
        #expect(Set(rows.filter { $0.deviceID == phone.intro.deviceID }.map(\.id)) == [original.id, secondSlot.id])
        #expect(rows.first { $0.id == otherDevice.id }?.deviceID == pad.intro.deviceID)
    }

    @Test func aDeviceAdoptsALegacyRowAndAnOlderHostCanStillReadIt() async throws {
        let mac = try await Mac("Acme Studio")
        defer { mac.stop() }
        let phone = Device()
        defer { phone.stop() }
        let client = try await connect(phone, to: mac)
        let file = mac.host.dir.appendingPathComponent("push-registrations.json")
        let legacy = registration()
        try JSONEncoder().encode([legacy]).write(to: file)
        try await client.registerPush(legacy)
        let bytes = try Data(contentsOf: file)
        let rows = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(rows.first?["deviceID"] as? String == phone.intro.deviceID.uuidString)
        // Nightly reads the same bare array through PersistedFile with the unchanged wire type.
        guard case .loaded(let oldRows) = PersistedFile<[RemotePushRegistration]>.load(from: file) else {
            Issue.record("The older reader could not load an owned row")
            return
        }
        #expect(oldRows == [legacy])
        #expect(try Data(contentsOf: file) == bytes)
        try await mac.local.unregisterPush(legacy.id)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)).isEmpty)
    }

    @Test func authenticatedRegistrationPersistsPrivatelyAndRevocationCancels() async throws {
        let host = try await Mac("Acme Studio")
        defer { host.stop() }
        let registration = registration()
        let anonymous = try RawRemote(port: host.port)
        try anonymous.send(.pushRegistration(id: 2, registration: registration))
        #expect(try await anonymous.disconnected())
        #expect(await host.server.queue.testHop { host.server.pushNotifications.registrations.isEmpty })
        let phone = Device()
        defer { phone.stop() }
        let client = try await connect(phone, to: host)
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

    @Test func damagedFileReachesExistingClientErrorAndCanBeDeletedWithoutRestart() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let file = host.host.dir.appendingPathComponent("push-registrations.json")
        let client = try await host.typed()
        defer { client.disconnect() }
        let original = registration()
        try await client.registerPush(original)
        let registration = RemotePushRegistration(id: original.id, sendToken: String(repeating: "b", count: 64))
        let damaged = Data("{\"version\":99,\"value\":[]}".utf8)
        try damaged.write(to: file)
        for register in [true, false] {
            do {
                if register { try await client.registerPush(registration) }
                else { try await client.unregisterPush(registration.id) }
                Issue.record("Expected damaged push file to be refused")
            } catch let error as RemoteHostClientError {
                guard case .rejected("push_registration", let message) = error else {
                    Issue.record("Unexpected push error: \(error)")
                    continue
                }
                #expect(error.localizedDescription == message)
                #expect(message.contains("\(file.path) on the host"))
                #expect(message.contains("move or delete the file"))
            }
            #expect(try Data(contentsOf: file) == damaged)
        }
        try FileManager.default.removeItem(at: file)
        try await client.registerPush(registration)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: file)) == [registration])
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
            #expect(Set(body.keys) == ["eventID", "agentID", "kind", "group", "level", "relevance"])
            #expect(body["kind"] as? String == "needsAnswer")
        }
        try await eventually("hung transports cancelled at the ten second bound", timeout: .seconds(12)) { cancelled.current == 16 }
        #expect(requests.current.count == 16, "no retries")
    }

    @Test func previewsUseOnlyThisRunsFinalTextAndSanitizeActualPayload() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        let bodies = Locked<[[String: String]]>([])
        try host.server.queue.sync {
            let pushes = host.server.pushNotifications
            try pushes.register(registration())
            pushes.transport = { request, finished in
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
                bodies.withValue { $0.append(body.compactMapValues { $0 as? String }) }
                finished(nil)
                return {}
            }
            let thread = try #require(host.server.rpcThread(forAgent: pi.agent.id))
            // Feed real RPC event types; history and message_end must not become a final preview.
            thread.handle(.agentStart)
            thread.handle(.agentEnd(messages: [.init(role: "assistant", content: [.text("old reply")], stopReason: "stop")], willRetry: false))
            #expect(thread.pushFinalText == "old reply")
            thread.handle(.agentStart)
            #expect(thread.pushFinalText == nil)
            thread.handle(.messageEnd(message: .init(role: "assistant", content: [.text("intermediate"), .thinking("private reasoning")], stopReason: "toolUse")))
            #expect(thread.pushFinalText == nil)
            thread.handle(.agentEnd(messages: [
                .init(role: "assistant", content: [.text("intermediate")], stopReason: "toolUse"),
                .init(role: "toolResult", content: [.text("private tool log")]),
                .init(role: "assistant", content: [.thinking("private reasoning"), .text("Final\n\t answer")], stopReason: "stop")
            ], willRetry: false))
            pushes.send(agentID: pi.agent.id, kind: .done, title: "Current\n title", preview: thread.pushFinalText)
            thread.handle(.agentStart)
            thread.handle(.agentEnd(messages: [.init(role: "assistant", content: [.thinking("private reasoning")], stopReason: "stop")], willRetry: false))
            pushes.send(agentID: pi.agent.id, kind: .done, preview: thread.pushFinalText)
            thread.handle(.agentStart)
            thread.handle(.agentEnd(messages: [], willRetry: false))
            #expect(thread.pushFinalText == nil)
            pushes.send(agentID: pi.agent.id, kind: .done,
                title: String(repeating: "😀", count: 101),
                preview: String(repeating: "e\u{301}", count: 121))
            pushes.send(agentID: pi.agent.id, kind: .error, title: "\u{0}\n ", preview:
                "password=short token='two words' Authorization: Bearer abc " +
                "ghp_abcdefghijklmnopqrstuvwxyz -----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY----- " +
                "sk-abcdefghijklmnopqrstuvwxyz")
            pushes.send(agentID: pi.agent.id, kind: .needsAnswer, preview:
                "safe\u{0} text\n-----BEGIN PRIVATE KEY-----unterminated secret")
        }
        let values = bodies.current
        #expect(values.count == 5)
        #expect(values[0]["title"] == "Current title")
        #expect(values[0]["preview"] == "Final answer")
        #expect(values[1]["preview"] == nil)
        #expect(values[2]["title"]?.unicodeScalars.count == 100)
        #expect(values[2]["preview"]?.unicodeScalars.count == 240)
        #expect(values[3]["title"] == nil)
        #expect(values[3]["preview"] == Array(repeating: "[redacted]", count: 6).joined(separator: " "))
        #expect(values[4]["preview"] == "safe text [redacted]")
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

    @Test func theThreadWatchedOnThisMacSendsNoPush() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.focused")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let requests = Locked(0)
        let watched = AgentID()
        try queue.sync {
            try pushes.register(registration())
            pushes.transport = { _, finished in
                requests.withValue { $0 += 1 }
                finished(nil)
                return {}
            }
            pushes.focused = watched
            pushes.send(agentID: watched, kind: .done)
        }
        #expect(requests.current == 0)
        queue.sync { pushes.send(agentID: AgentID(), kind: .done) }
        #expect(requests.current == 1)
        queue.sync {
            pushes.focused = nil
            pushes.send(agentID: watched, kind: .done)
        }
        #expect(requests.current == 2)
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
            #expect(pushes.registrations[old.id]?.sendToken == replacement.sendToken)
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

    @Test(arguments: [nil, 400, 410] as [Int?])
    func damageAfterDeliveryStartsBlocksNewSendsFallbackAndPruning(_ status: Int?) throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.damaged-revocation")
        let file = dir.appendingPathComponent("push-registrations.json")
        let pushes = PushNotifications(file: file, queue: queue)
        let callback = Locked<(@Sendable (Int?) -> Void)?>(nil)
        let requests = Locked(0)
        try queue.sync {
            try pushes.register(registration())
            try pushes.register(registration())
            pushes.transport = { _, finished in
                requests.withValue { $0 += 1 }
                callback.withValue { $0 = finished }
                return {}
            }
            pushes.send(agentID: AgentID(), kind: .done)
        }
        #expect(requests.current == 2)
        let damage = Data("[null]".utf8)
        try damage.write(to: file)
        if let status {
            let finish = try #require(callback.current)
            finish(status)
        }
        try queue.sync {
            let saved = try Data(contentsOf: file)
            #expect(saved == damage)
            pushes.send(agentID: AgentID(), kind: .done)
            #expect(requests.current == 2, "damage suspends delivery and relay fallback")
        }
    }

    @Test(arguments: [false, true])
    func relayFallbackChecksPairingState(revoked: Bool) throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.fallback-pairing")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let deviceID = UUID()
        let callbacks = Locked<[@Sendable (Int?) -> Void]>([])
        try queue.sync {
            try pushes.register(registration(), deviceID: deviceID)
            pushes.canDeliverToDevice = { $0 == deviceID }
            pushes.transport = { _, finished in
                callbacks.withValue { $0.append(finished) }
                return {}
            }
            pushes.send(agentID: AgentID(), kind: .done, title: "Acme build")
            // Keep the registration and pending delivery intact so cancellation cannot mask a missing check.
            if revoked { pushes.canDeliverToDevice = { $0 != deviceID } }
        }
        let finish = try #require(callbacks.current.first)
        #expect(callbacks.current.count == 1)
        finish(400)
        queue.sync {
            #expect(callbacks.current.count == (revoked ? 1 : 2))
            pushes.stop()
        }
    }

    @Test func alertsCarryTheirStackLoudnessAndSummaryRankAndFallBackForAnOlderRelay() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.rich")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let bodies = Locked<[[String: Any]]>([])
        let agent = AgentID()
        try queue.sync {
            try pushes.register(registration())
            pushes.transport = { request, finished in
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
                bodies.withValue { $0.append(body) }
                // The deployed relay refuses fields it doesn't know.
                finished(body["group"] == nil ? 202 : 400)
                return {}
            }
            pushes.send(agentID: agent, kind: .done, title: "Investigate SwiftUI live preview", preview: "Done.",
                        subtitle: "Turn finished")
        }
        try queue.sync {} // the refusal's callback hops onto the queue
        let first = bodies.current
        #expect(first.count == 2)
        #expect(first[0]["group"] as? String == "thread:\(agent.rawValue)")
        #expect(first[0]["subtitle"] as? String == "Turn finished")
        #expect(first[0]["level"] as? String == "passive")
        #expect(first[0]["relevance"] as? Double == 0.2)
        #expect(Set(first[1].keys) == ["eventID", "agentID", "kind", "title", "preview"], "the same event in the old shape")
        #expect(first[1]["eventID"] as? String == first[0]["eventID"] as? String)
        try queue.sync {
            #expect(pushes.relay == .legacy)
            pushes.send(agentID: agent, kind: .needsAnswer)
        }
        try queue.sync {}
        #expect(bodies.current.count == 3, "an older relay gets the old shape at once, never twice")
        #expect(bodies.current[2]["group"] == nil)
        #expect(PushNotifications.presentation(.needsAnswer) == ("active", 0.8))
        #expect(PushNotifications.presentation(.error) == ("active", 0.6))
    }

    @Test func aRelayWithoutDetailGetsTheRest() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.detail")
        let pushes = PushNotifications(file: dir.appendingPathComponent("push.json"), queue: queue)
        let bodies = Locked<[(size: Int, json: [String: Any])]>([])
        let detail = PushDetail(options: ["Yes", "No"])
        try queue.sync {
            try pushes.register(registration())
            pushes.transport = { request, finished in
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
                bodies.withValue { $0.append((request.httpBody!.count, json)) }
                // The relay #3 deployed: it knows the stack fields but not `detail`.
                finished(json["detail"] == nil ? 202 : 400)
                return {}
            }
            pushes.send(agentID: AgentID(), kind: .needsAnswer, title: "Refunds in the ledger", subtitle: "Question", detail: detail)
        }
        try queue.sync {}
        var sent = bodies.current
        #expect(sent.count == 2)
        let first = try #require(sent[0].json["detail"] as? [String: Any])
        #expect(first["options"] as? [String] == ["Yes", "No"])
        #expect(sent[1].json["detail"] == nil && sent[1].json["group"] != nil, "the same event, keeping the stack fields")
        #expect(sent[1].json["eventID"] as? String == sent[0].json["eventID"] as? String)
        try queue.sync {
            #expect(pushes.relay == .rich)
            pushes.send(agentID: AgentID(), kind: .error, detail: detail)
        }
        try queue.sync {}
        sent = bodies.current
        #expect(sent.count == 3 && sent[2].json["detail"] == nil, "from then on, no detail and no second try")
    }

    @Test func eachPhoneGetsOnlyWhatItsSettingsAskForAndKeepsThemAcrossRestarts() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "push.preferences")
        let file = dir.appendingPathComponent("push.json")
        let pushes = PushNotifications(file: file, queue: queue)
        let sent = Locked<[String]>([])
        let idle = Locked<TimeInterval>(0)
        let older = registration()
        let quiet = RemotePushRegistration(id: UUID().uuidString, sendToken: String(repeating: "b", count: 64),
            preferences: RemotePushPreferences(topics: [.questions, .blocked, .failures], awayOnly: true))
        try queue.sync {
            try pushes.register(older)
            try pushes.register(quiet)
            pushes.idleSeconds = { idle.current }
            pushes.transport = { request, finished in
                sent.withValue { $0.append(String(request.value(forHTTPHeaderField: "Authorization")!.suffix(1))) }
                finished(202)
                return {}
            }
        }
        func send(_ kind: PushNotifications.Kind, topic: RemotePushPreferences.Topic? = nil) -> [String] {
            sent.withValue { $0 = [] }
            queue.sync { pushes.send(agentID: AgentID(), kind: kind, topic: topic) }
            return sent.current.sorted()
        }
        #expect(send(.needsAnswer) == ["a"], "away-only: the Mac is in use, so only the older phone hears it")
        idle.withValue { $0 = RemotePushPreferences.awayAfter }
        #expect(send(.needsAnswer) == ["a", "b"])
        #expect(send(.done) == ["a"], "Finished work is off")
        #expect(send(.error, topic: .blocked) == ["a", "b"])
        let restored = PushNotifications(file: file, queue: queue)
        #expect(restored.registrations[UUID(uuidString: quiet.id)!.uuidString]?.preferences == quiet.preferences)
    }

    private func record(_ server: SessionServer, payloads: Locked<[[String: String]]>? = nil) throws -> Locked<[String]> {
        let events = Locked<[String]>([])
        try server.queue.sync {
            try server.pushNotifications.register(registration())
            server.pushNotifications.transport = { request, finished in
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                events.withValue { $0.append(body?["kind"] as? String ?? "invalid") }
                payloads?.withValue { $0.append(body?.compactMapValues { $0 as? String } ?? [:]) }
                finished(nil)
                return {}
            }
        }
        return events
    }

    @Test func openingPromptQuestionsSettledCompletionAndProcessFailure() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let payloads = Locked<[[String: String]]>([])
        let events = try record(host.server, payloads: payloads)
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        #expect(events.current.isEmpty, "startup history must not replay")
        try await host.server.renameAgent(pi.agent.id, to: "Current thread title")
        await host.server.sendOpeningPrompt(try #require(OpeningPrompt("ask", agentID: pi.agent.id)), sessionID: pi.sessionID)
        let asked = try await pi.snapshot("opening prompt asks") { !$0.dialogs.isEmpty }
        try await eventually("one needsAnswer") { events.current == ["needsAnswer"] }
        #expect(payloads.current[0]["title"] == "Current thread title")
        #expect(payloads.current[0]["preview"] == asked.dialogs.first?.title)
        _ = try await pi.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true)))
        try await eventually("settled answer") { events.current == ["needsAnswer", "done"] }
        #expect(payloads.current[1]["preview"] == nil, "this legacy stub reply has no final stopReason")
        _ = try await pi.snapshot()
        #expect(events.current == ["needsAnswer", "done"], "status revisions do not duplicate")
        _ = try await pi.send("provider-error", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        try Data().write(to: host.dir.appendingPathComponent("fail-turn"))
        try await eventually("settled provider failure") { events.current == ["needsAnswer", "done", "error"] }
        #expect(payloads.current[2]["preview"] == "529 overloaded")
        _ = try? await pi.send("die", from: try await pi.ready())
        try await eventually("unexpected process failure") { events.current == ["needsAnswer", "done", "error", "error"] }
        #expect(payloads.current[3]["preview"] == nil, "never reuse the previous run's failure")
    }

    @Test func childQuestionExplicitlyAskedByParentUsesParentTitleAndQuestionOnce() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let payloads = Locked<[[String: String]]>([])
        let events = try record(host.server, payloads: payloads)
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        try await host.server.renameAgent(pi.agent.id, to: "Parent thread")
        host.server.queue.sync {
            let thread = host.server.rpcThread(forAgent: pi.agent.id)!
            thread.pushRunArmed = true
            // Child attention alone isn't a human question. The parent's explicit dialog is.
            thread.setSubagents([ChildRun(runID: "child", label: "Child", state: "running", needsAttention: true, attentionText: "Choose retention")])
            #expect(events.current.isEmpty)
            host.server.applyAgentQuestion(agentID: pi.agent.id, question: "Child asks: keep logs for 30 days?", reason: "retention?")
            host.server.applyAgentQuestion(agentID: pi.agent.id, question: "Child asks: keep logs for 30 days?", reason: "retention?")
        }
        #expect(events.current == ["needsAnswer"])
        #expect(payloads.current[0]["title"] == "Parent thread")
        #expect(payloads.current[0]["preview"] == "Child asks: keep logs for 30 days?")
    }

    @Test func settledSenderUsesLatestReplyAndTitleWhileThreadIsWatched() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let payloads = Locked<[[String: String]]>([])
        let events = try record(host.server, payloads: payloads)
        let pi = try await PiAgent.launch(on: host)
        try await host.server.renameAgent(pi.agent.id, to: "First title")
        _ = try await pi.send("tools:0 first", from: try await pi.ready())
        try await eventually("first run push") { events.current == ["done"] }
        #expect(payloads.current[0]["title"] == "First title")
        #expect(payloads.current[0]["preview"] == "Reply to tools:0 first")
        try await host.server.renameAgent(pi.agent.id, to: "Renamed title")
        _ = try await pi.send("tools:0 second", from: try await pi.ready())
        _ = try await pi.snapshot("watch the current thread") { !$0.running }
        try await eventually("second run push") { events.current == ["done", "done"] }
        #expect(payloads.current[1]["title"] == "Renamed title")
        #expect(payloads.current[1]["preview"] == "Reply to tools:0 second")
    }

    /// The background host with this Mac's app as its local client: the app's sends reach the
    /// host's threads over `host.sock`, each settled turn posts once to the relay, and the thread the
    /// app says it shows (`focusThread`) posts nothing until the app clears it.
    @Test func theBackgroundHostPushesTheAppsThreadsExceptTheWatchedOne() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let socket = host.dir.appendingPathComponent("h.sock").path, tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let registration = registration()
        let posts = Locked<[URLRequest]>([])
        try host.server.queue.sync {
            try host.server.pushNotifications.register(registration)
            host.server.pushNotifications.transport = { request, finished in
                posts.withValue { $0.append(request) }
                finished(202)
                return {}
            }
        }
        let pi = try await PiAgent.launch(on: host)
        try await host.server.renameAgent(pi.agent.id, to: "Fix the login redirect")
        let app = RemoteHostClient(localSocket: socket)
        _ = try await app.connect(host: "", port: 0, token: try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), clientName: "Shepherd")
        defer { app.disconnect() }
        func turn(_ text: String) async throws {
            let ready = try await pi.ready()
            _ = try await app.nativeThread(agentID: pi.agent.id, request: .send(
                expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(), text: text, delivery: .followUp))
            _ = try await pi.snapshot("\(text) settled") { s in !s.running && s.messages.contains { $0.blocks.contains { $0.text == "Reply to \(text)" } } }
        }

        try await turn("tools:0 first")
        try await eventually("the finished turn's push") { posts.current.count == 1 }
        let post = try #require(posts.current.first)
        #expect(post.url?.absoluteString == "https://api.useshepherd.app/api/push/registrations/\(registration.id)/events")
        #expect(post.httpMethod == "POST" && post.value(forHTTPHeaderField: "Authorization") == "Bearer \(registration.sendToken)")
        let body = try #require(JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: Any])
        #expect(body["agentID"] as? String == pi.agent.id.rawValue && body["kind"] as? String == "done")
        #expect(body["title"] as? String == "Fix the login redirect" && body["subtitle"] as? String == "Turn finished")
        #expect(body["preview"] as? String == "Reply to tools:0 first" && body["group"] as? String == "thread:\(pi.agent.id.rawValue)")

        try await app.focusThread(pi.agent.id)
        try await turn("tools:0 watched")
        try await app.focusThread(nil)
        try await turn("tools:0 third")
        try await eventually("the push after the watch cleared") { posts.current.count == 2 }
        try host.server.queue.sync {}
        #expect(posts.current.count == 2, "the watched thread's turn posted nothing")
        let last = try #require(posts.current.last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(last["preview"] as? String == "Reply to tools:0 third")
    }

    /// Mute, from the app over `host.sock` as from a phone (`RemoteAgentAction.mutePushes`): the host keeps it on the
    /// thread, and its settled turns post nothing to any phone until it is unmuted.
    @Test func aThreadMutedOnTheBackgroundHostPostsNothingUntilUnmuted() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        // The background host serves the app's threads itself (`Shepherd --host`).
        await MainActor.run {
            host.server.serveThreads(ThreadHosting(defaults: {
                ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                       worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
            }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        }
        let socket = host.dir.appendingPathComponent("h.sock").path, tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let events = try record(host.server)
        let pi = try await PiAgent.launch(on: host)
        let app = RemoteHostClient(localSocket: socket)
        _ = try await app.connect(host: "", port: 0, token: try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), clientName: "Shepherd")
        defer { app.disconnect() }
        #expect(app.capabilities.contains(RemoteProtocol.pushMuteCapability))
        func turn(_ text: String) async throws {
            _ = try await pi.send(text, from: try await pi.ready())
            _ = try await pi.snapshot("\(text) settled") { s in !s.running && s.messages.contains { $0.blocks.contains { $0.text == "Reply to \(text)" } } }
        }

        try await app.agentAction(agentID: pi.agent.id, action: .mutePushes(true))
        #expect(host.server.state.agents.first { $0.id == pi.agent.id }?.pushMuted == true)
        try await turn("tools:0 muted")
        try host.server.queue.sync {}
        #expect(events.current.isEmpty, "a muted thread posts nothing")

        try await app.agentAction(agentID: pi.agent.id, action: .mutePushes(false))
        #expect(host.server.state.agents.first { $0.id == pi.agent.id }?.pushMuted == false)
        try await turn("tools:0 heard")
        try await eventually("the unmuted thread's push") { events.current == ["done"] }
    }

    /// An automation's failed run says so under the automation's name: its thread's failed turn, and a run that
    /// never started (no thread, so the push names and opens the automation).
    @Test func anAutomationsFailedRunPushesAutomationFailed() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let payloads = Locked<[[String: String]]>([])
        let events = try record(host.server, payloads: payloads)
        let pi = try await PiAgent.launch(on: host)
        let watcher = Automation(name: "pr-watch acme-web", prompt: "Watch the PR", cwd: host.dir.path, agentID: pi.agent.id)
        let triggered = Automation(name: "issue triage", prompt: "Triage", cwd: host.dir.path)
        host.server.queue.sync { host.server.store.updateLive { $0.automations = [watcher, triggered] } }

        _ = try await pi.send("provider-error", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        try Data().write(to: host.dir.appendingPathComponent("fail-turn"))
        try await eventually("the run's failed turn") { events.current == ["error"] }
        #expect(payloads.current[0]["title"] == "pr-watch acme-web" && payloads.current[0]["subtitle"] == "Automation failed")
        #expect(payloads.current[0]["group"] == "automation:\(watcher.id.rawValue)" && payloads.current[0]["agentID"] == pi.agent.id.rawValue)
        #expect(payloads.current[0]["preview"] == "529 overloaded")

        await host.server.recordAutomationFailure(triggered.id, trigger: "acme-web#12 opened", triggerURL: nil, message: "Couldn't make the worktree")
        try await eventually("the run that never started") { events.current == ["error", "error"] }
        #expect(payloads.current[1]["title"] == "issue triage" && payloads.current[1]["subtitle"] == "Automation failed")
        #expect(payloads.current[1]["agentID"] == triggered.id.rawValue && payloads.current[1]["group"] == "automation:\(triggered.id.rawValue)")
        #expect(payloads.current[1]["preview"] == "Couldn't make the worktree")
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
