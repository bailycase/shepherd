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

        let suite = "push-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let credential = PushKeychain.Credential(registrationID: UUID().uuidString,
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

        manager.resetSession()
        let replacement = UUID().uuidString
        RelayStub.set([(401, ""), (201, "{\"id\":\"\(replacement)\",\"sendToken\":\"\(credential.sendToken)\",\"manageToken\":\"\(credential.manageToken)\"}")])
        await manager.renewOnForeground(hosts: [host])
        assert(RelayStub.methods == ["PATCH", "POST"])
        assert(memory.read(host: hostID)?.registrationID == replacement)

        RelayStub.set([(401, ""), (401, "")])
        await manager.disable(hostID: hostID)
        assert(manager.isEnabled(host: hostID) && manager.hostStates[hostID]?.revokeFailed == true)
        do { try await manager.forget(host: hostID); assertionFailure("forget must fail") } catch {}
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

        try await manager.forget(host: hostID)
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
        windows.register(MobileWindowSeed(), navigator: navigator)
        router.drainPending(hosts: hosts, windows: windows)
        assert(router.pending == nil && navigator.selectedThread == payload.agentRef)
        navigator.open(.settings(.root))
        delegate.receive(payload)
        assert(router.pending == nil && navigator.selectedThread == payload.agentRef)
        print("PUSH CHECK COMPLETE: payload, renewal, expiry, failed revoke/forget, keychain, early/warm tap")
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
