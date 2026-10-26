import Foundation
import ShepherdCore
import ShepherdRemote

/// Run with run-push.sh: injected HTTP, memory credentials, no APNs or permission requests.
@main
struct PushTests {
    @MainActor static func main() async throws {
        let hostID = UUID(), agentID = UUID(), eventID = UUID()
        let payload = PushPayload.from(["shepherd": ["hostID": hostID.uuidString,
            "agentID": agentID.uuidString, "eventID": eventID.uuidString, "kind": "done"]])!
        assert(payload.agentRef == AgentRef(host: hostID, agent: AgentID(rawValue: agentID.uuidString.lowercased())))
        assert(PushPayload.from(["shepherd": ["hostID": hostID.uuidString, "agentID": 3,
            "eventID": eventID.uuidString, "kind": "done"]]) == nil)
        assert(PushPayload.from(["shepherd": ["hostID": hostID.uuidString, "agentID": agentID.uuidString,
            "eventID": "bad", "kind": "done"]]) == nil)

        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("push-check-\(UUID())").path
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let memory = PushKeychainMemory()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let host = MobileHost(record: RemoteHostRecord(id: hostID, name: "Fixture", address: "localhost", port: 1))
        let fresh = PushManager(defaults: defaults, keychain: .memory(memory), session: session,
                                authorize: { fatalError("permission requested") }, registerToken: {})
        assert(!fresh.isEnabled(host: hostID))
        defaults.set([hostID.uuidString], forKey: "shepherd.ios.push.enabledHosts")
        let manager = PushManager(defaults: defaults, keychain: .memory(memory), session: session,
                                  authorize: { fatalError("permission requested") }, registerToken: {})
        let credential = PushKeychain.Credential(registrationID: UUID().uuidString.lowercased(),
            sendToken: String(repeating: "ab", count: 32), manageToken: String(repeating: "cd", count: 32), deviceTokenHex: "1122")
        memory.save(credential, host: hostID)
        RelayStub.set([(204, "")])
        await manager.renewOnForeground(hosts: [host])
        await manager.renewOnForeground(hosts: [host])
        assert(RelayStub.methods == ["PATCH"])
        assert(memory.read(host: hostID) == credential)

        manager.resetSession()
        RelayStub.set([(204, "")])
        async let first: Void = manager.renew(host: host)
        async let second: Void = manager.renew(host: host)
        _ = await (first, second)
        assert(RelayStub.methods == ["PATCH"], "concurrent renewals must serialize")
        manager.setDeviceToken(Data([0x33, 0x44]))
        RelayStub.set([(204, "")])
        await manager.renew(host: host)
        assert(memory.read(host: hostID)?.deviceTokenHex == "3344")
        manager.setDeviceToken(Data([0x55, 0x66]))
        RelayStub.set([(500, "")])
        await manager.renew(host: host)
        assert(manager.hostStates[hostID]?.error != nil)
        RelayStub.set([(204, "")])
        await manager.renew(host: host)
        assert(RelayStub.methods == ["PATCH"] && manager.hostStates[hostID]?.error == nil,
               "a persisted rotated token must not suppress retry after a failed PATCH")

        manager.resetSession()
        let replacement = credential.registrationID
        RelayStub.set([(401, ""), (201, "{\"id\":\"\(replacement)\",\"sendToken\":\"\(credential.sendToken)\",\"manageToken\":\"\(credential.manageToken)\"}")])
        await manager.renewOnForeground(hosts: [host])
        assert(RelayStub.methods == ["PATCH", "POST"])
        assert(memory.read(host: hostID)?.registrationID == replacement)

        RelayStub.set([(401, ""), (401, "")])
        await manager.disable(hostID: hostID)
        assert(manager.isEnabled(host: hostID) && manager.hostStates[hostID]?.revokeFailed == true)
        do { try await manager.forget(host: hostID) {}; assertionFailure("forget must fail") } catch {}
        assert(manager.isEnabled(host: hostID) && memory.read(host: hostID) != nil)

        let restored = PushManager(defaults: defaults, keychain: .memory(memory), session: session, registerToken: {})
        RelayStub.set([])
        await manager.renew(host: host)
        await restored.renew(host: host)
        assert(RelayStub.methods.isEmpty && restored.hostStates[hostID]?.revokeFailed == true)

        let timeout = PushManager(defaults: defaults, keychain: .memory(), tokenTimeout: .milliseconds(1), registerToken: {})
        do { _ = try await timeout.obtainDeviceToken(); assertionFailure("token wait must time out") } catch {}
        timeout.setDeviceToken(Data([0x11]))
        let recoveredToken = try await timeout.obtainDeviceToken()
        assert(recoveredToken == "11")

        var enabled: Set<UUID> = [hostID]
        manager.onEnabledHostsChanged = { enabled = $0 }
        RelayStub.set([(200, "")])
        await manager.disable(hostID: hostID)
        assert(manager.isEnabled(host: hostID), "DELETE must confirm 204")
        RelayStub.set([(204, "")])
        await manager.disable(hostID: hostID)
        assert(!manager.isEnabled(host: hostID) && enabled.isEmpty && memory.read(host: hostID) == nil)

        try await manager.forget(host: hostID) {}
        await manager.enable(host: host)
        assert(manager.hostStates[hostID] == nil, "a stale window must not re-enable a forgotten host")

        memory.save(credential, host: hostID)
        var locked = PushKeychainAccess.memory(memory)
        locked.remove = { _ in throw PushError.keychainFailure("locked") }
        let failed = PushManager(defaults: defaults, keychain: locked, session: session, registerToken: {})
        RelayStub.set([(204, "")])
        await failed.disable(hostID: hostID)
        assert(failed.hostStates[hostID]?.error != nil && memory.read(host: hostID) == credential)

        // Early tap survives delegate configuration without a window, then drains once.
        defaults.set(RemoteHostRecord.encodeList([host.record]), forKey: MobileHosts.recordsKey)
        let hosts = MobileHosts(defaults: defaults, tokens: .memory())
        let router = PushRouter(), windows = MobileWindows(), delegate = PushAppDelegate()
        delegate.receive(payload)
        delegate.configure(push: manager, router: router, hosts: hosts, windows: windows)
        assert(router.pending == payload)
        let navigator = MobileNavigator()
        let firstWindow = MobileWindowSeed(), secondWindow = MobileWindowSeed()
        let secondNavigator = MobileNavigator()
        windows.register(firstWindow, navigator: navigator)
        windows.register(secondWindow, navigator: secondNavigator)
        router.drainPending(hosts: hosts, windows: windows)
        assert(router.pending == payload, "registration alone is not a ready foreground scene")
        windows.setPhase(firstWindow.id, .background, hosts: hosts)
        windows.setPhase(secondWindow.id, .active, hosts: hosts)
        router.drainPending(hosts: hosts, windows: windows)
        assert(router.pending == nil && secondNavigator.selectedThread == payload.agentRef)
        assert(navigator.selectedThread == nil)
        windows.setPhase(firstWindow.id, .active, hosts: hosts)
        navigator.open(.settings(.root))
        delegate.receive(payload)
        assert(router.pending == nil && navigator.selectedThread == payload.agentRef)
        windows.setPhase(firstWindow.id, .inactive, hosts: hosts)
        navigator.open(.settings(.root))
        delegate.receive(payload)
        assert(navigator.selectedThread == nil, "active beats most recently active")
        windows.setPhase(secondWindow.id, .inactive, hosts: hosts)
        delegate.receive(payload)
        assert(navigator.selectedThread == payload.agentRef, "most recent wins among inactive scenes")
        hosts.setForeground(false)

        host.enablePushFixture()
        let intentMemory = PushKeychainMemory()
        var failingSave = PushKeychainAccess.memory(intentMemory)
        failingSave.save = { _, _ in throw PushError.keychainFailure("locked") }
        let noSave = PushManager(defaults: defaults, keychain: failingSave, session: session,
                                 authorize: { true }, registerToken: {})
        noSave.setDeviceToken(Data([0x55]))
        RelayStub.set([])
        await noSave.enable(host: host)
        assert(RelayStub.methods.isEmpty && intentMemory.read(host: hostID) == nil)

        let retry = PushManager(defaults: defaults, keychain: .memory(intentMemory), session: session,
                                authorize: { true }, registerToken: {})
        retry.setDeviceToken(Data([0x55]))
        RelayStub.set([(0, "")]) // the relay may have committed before the connection dropped
        await retry.enable(host: host)
        let intent = intentMemory.read(host: hostID)!
        assert(intent.sendToken.count == 64 && intent.manageToken.count == 64 && intent.sendToken != intent.manageToken)
        assert(RelayStub.methods == ["POST"])
        retry.setDeviceToken(Data([0x66]))
        RelayStub.set([(401, ""), (201, "echo")])
        await retry.enable(host: host)
        let retained = intentMemory.read(host: hostID)!
        assert(retained.registrationID == intent.registrationID && retained.sendToken == intent.sendToken)
        assert(retained.manageToken == intent.manageToken && retained.deviceTokenHex == "66")
        assert(retry.isEnabled(host: hostID) && retry.hostStates[hostID]?.error == nil)

        var hostTokens = HostTokens.memory()
        hostTokens.remove = { _ in throw PushError.keychainFailure("host token locked") }
        let retryableHosts = MobileHosts(defaults: defaults, tokens: hostTokens)
        RelayStub.set([(204, "")])
        do {
            try await retry.forget(host: hostID) { try retryableHosts.forget(hostID) }
            assertionFailure("host removal must fail")
        } catch {}
        assert(retryableHosts.host(hostID) != nil)
        assert(!retry.isEnabled(host: hostID) && retry.hostStates[hostID]?.revokeFailed == false,
               "successful revocation stays confirmed even if host removal fails")
        RelayStub.set([(201, "echo")])
        await retry.enable(host: host)
        assert(retry.isEnabled(host: hostID) && retry.hostStates[hostID]?.error == nil,
               "failed host removal must not tombstone a retryable host")
        RelayStub.set([(204, "")])
        try await retry.forget(host: hostID) {}
        RelayStub.set([])
        await retry.enable(host: host)
        assert(RelayStub.methods.isEmpty && retry.hostStates[hostID] == nil)

        // Replies must match the pre-owned identity and use full-length credentials.
        for send in ["ab", String(repeating: "ef", count: 32)] {
            RelayStub.set([(201, "{\"id\":\"\(intent.registrationID)\",\"sendToken\":\"\(send)\",\"manageToken\":\"\(intent.manageToken)\"}")])
            do {
                _ = try await PushRelay.register(deviceToken: "55", environment: PushEnvironment.current,
                                                 hostID: hostID, credential: intent, session: session)
                assertionFailure("invalid or mismatched credential must be rejected")
            } catch {}
        }

        let alerts = GoalNotifications()
        let allowed = try await alerts.authorizeLocalAlert(host: hostID) {
            await Task.yield()
            alerts.pushEnabledHosts.insert(hostID)
            return true
        }
        assert(!allowed, "push enabled during permission must suppress the local post")
        print("PUSH CHECK COMPLETE: payload, renewal, durable intent, failed revoke/forget, multiwindow taps, permission race")
    }
}

private final class RelayStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies: [(Int, String)] = []
    private static var requests: [String] = []
    static var methods: [String] { lock.withLock { requests } }
    static func set(_ values: [(Int, String)]) { lock.withLock { replies = values; requests = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests.append(request.httpMethod!)
            precondition(!Self.replies.isEmpty, "Unexpected relay request")
            return Self.replies.removeFirst()
        }
        if reply.0 == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var body = reply.1
        if body == "echo" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let fields = try! JSONDecoder().decode([String: String].self, from: data)
            precondition(fields.count == 6 && fields["deviceToken"] != nil)
            body = String(data: try! JSONEncoder().encode(fields.filter { ["id", "sendToken", "manageToken"].contains($0.key) }), encoding: .utf8)!
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
