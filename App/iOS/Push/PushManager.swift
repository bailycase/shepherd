import Foundation
import Observation
import UIKit
import UserNotifications
import ShepherdProtocol
import ShepherdRemote

/// All mutations for a host share a FIFO gate, including token refresh and forgetting.
@MainActor
@Observable
final class PushManager {
    struct HostPushState: Equatable {
        var enabled = false
        var registering = false
        var registered = false
        var permissionDenied = false
        var error: String?
        var revokeFailed = false
    }
    private(set) var hostStates: [UUID: HostPushState] = [:]
    private(set) var deviceTokenHex: String?
    @ObservationIgnored private let keychain: PushKeychainAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let authorize: () async throws -> Bool
    @ObservationIgnored private let registerToken: @MainActor () -> Void
    @ObservationIgnored private var renewedThisSession: Set<UUID> = []
    @ObservationIgnored private var forgottenHosts: Set<UUID> = []
    @ObservationIgnored private var foregroundGeneration = 0
    @ObservationIgnored private var inflight: Set<UUID> = []
    @ObservationIgnored private var queues: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var tokenWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private let tokenTimeout: Duration
    @ObservationIgnored var onEnabledHostsChanged: ((Set<UUID>) -> Void)?
    private static let enabledHostsKey = "shepherd.ios.push.enabledHosts"
    private static let revokingHostsKey = "shepherd.ios.push.revokingHosts"

    init(defaults: UserDefaults = .standard, keychain: PushKeychainAccess = .real,
         isFixture: Bool = false, session: URLSession? = nil, tokenTimeout: Duration = .seconds(10),
         authorize: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
         }, registerToken: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.defaults = defaults
        self.keychain = keychain
        self.isFixture = isFixture
        self.session = session
        self.tokenTimeout = tokenTimeout
        self.authorize = authorize
        self.registerToken = registerToken
        for raw in defaults.stringArray(forKey: Self.enabledHostsKey) ?? [] {
            if let id = UUID(uuidString: raw) { hostStates[id] = HostPushState(enabled: true) }
        }
        for raw in defaults.stringArray(forKey: Self.revokingHostsKey) ?? [] {
            if let id = UUID(uuidString: raw) {
                hostStates[id, default: HostPushState()].revokeFailed = true
                hostStates[id]?.error = "Push revocation pending. Tap Retry."
            }
        }
    }
    var enabledHosts: Set<UUID> { Set(hostStates.filter(\.value.enabled).map(\.key)) }
    var hasEnabledHosts: Bool { !enabledHosts.isEmpty }
    func isEnabled(host: UUID) -> Bool { hostStates[host]?.enabled == true }
    func hostSupportsPush(_ host: MobileHost) -> Bool { host.supports(RemoteProtocol.pushNotificationsCapability) }

    private func acquire(_ id: UUID) async {
        if inflight.insert(id).inserted { return }
        await withCheckedContinuation { queues[id, default: []].append($0) }
    }
    private func release(_ id: UUID) {
        if var waiting = queues[id], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queues[id] = waiting
            next.resume()
        } else { queues[id] = nil; inflight.remove(id) }
    }

    func enable(host: MobileHost) async {
        guard !isFixture else { return }
        await acquire(host.id)
        defer { release(host.id) }
        guard !forgottenHosts.contains(host.id) else { return }
        hostStates[host.id, default: HostPushState()].registering = true
        defer { hostStates[host.id]?.registering = false }
        do {
            guard hostSupportsPush(host) else { throw PushError.network("Update Shepherd on this Mac to enable push notifications.") }
            guard try await authorize() else {
                hostStates[host.id]?.permissionDenied = true
                throw PushError.permissionDenied
            }
            hostStates[host.id]?.permissionDenied = false
            let token = try await obtainDeviceToken()
            let credential = try await resolveCredential(hostID: host.id, tokenHex: token)
            // Persist opt-in once the relay is active, even if the Mac is temporarily unreachable.
            hostStates[host.id]?.enabled = true
            hostStates[host.id]?.revokeFailed = false
            persistEnabledHosts()
            try await registerWithHost(host, credential)
            hostStates[host.id]?.error = nil
            hostStates[host.id]?.revokeFailed = false
        } catch { hostStates[host.id]?.error = error.localizedDescription }
    }

    private func resolveCredential(hostID id: UUID, tokenHex: String) async throws -> PushKeychain.Credential {
        // Persisting a token records intent, not confirmation that the relay accepted it.
        renewedThisSession.remove(id)
        let existing = try keychain.read(id)
        var credential = try existing ?? PushKeychain.makeCredential(deviceToken: tokenHex)
        credential.deviceTokenHex = tokenHex
        // Own the identity and current target durably before any remote mutation.
        if credential != existing { try keychain.save(credential, id) }
        if existing != nil,
           try await PushRelay.update(registrationID: credential.registrationID, manageToken: credential.manageToken,
                                      deviceToken: tokenHex, environment: PushEnvironment.current, session: session) {
            return credential
        }
        // A missing registration or ambiguous POST retries the same persisted identity.
        _ = try await PushRelay.register(deviceToken: tokenHex, environment: PushEnvironment.current,
                                         hostID: id, credential: credential, session: session)
        return credential
    }

    func disable(host: MobileHost) async {
        await disable(hostID: host.id, client: host.connectedClient, supports: hostSupportsPush(host))
    }
    func disable(hostID: UUID, client: RemoteHostClient? = nil, supports: Bool = false) async {
        guard !isFixture else { return }
        await acquire(hostID)
        defer { release(hostID) }
        hostStates[hostID, default: HostPushState()].registering = true
        defer { hostStates[hostID]?.registering = false }
        do {
            markRevoking(hostID)
            try await revoke(hostID, client: supports ? client : nil)
            hostStates[hostID] = HostPushState()
            renewedThisSession.remove(hostID)
            persistEnabledHosts()
        } catch {
            hostStates[hostID]?.error = error.localizedDescription
            hostStates[hostID]?.revokeFailed = true
        }
    }
    private func revoke(_ id: UUID, client: RemoteHostClient? = nil) async throws {
        if let credential = try keychain.read(id) {
            try await PushRelay.revoke(registrationID: credential.registrationID, manageToken: credential.manageToken, session: session)
            try keychain.remove(id)
            try? await client?.unregisterPush(credential.registrationID)
        }
    }
    func retryRevoke(host: MobileHost) async { await disable(host: host) }
    func forget(host: UUID, removeHost: () throws -> Void) async throws {
        guard !isFixture else { try removeHost(); return }
        await acquire(host)
        defer { release(host) }
        do {
            markRevoking(host)
            try await revoke(host)
            hostStates[host] = HostPushState()
            renewedThisSession.remove(host)
            persistEnabledHosts()
            try removeHost()
            forgottenHosts.insert(host)
            hostStates[host] = nil
        } catch {
            hostStates[host, default: HostPushState()].error = error.localizedDescription
            throw error
        }
    }

    func renewOnForeground(hosts: [MobileHost]) async {
        guard !isFixture, hasEnabledHosts else { return }
        // APNs may rotate the token; callbacks queue another serialized renewal if it changes.
        registerToken()
        for host in hosts where isEnabled(host: host.id) {
            await renew(host: host)
        }
    }
    func renewOnReconnect(host: MobileHost) async {
        guard host.phase == .connected else { return }
        await renew(host: host, reconnect: true)
    }
    func renew(host: MobileHost, reconnect: Bool = false) async {
        guard !isFixture else { return }
        await acquire(host.id)
        defer { release(host.id) }
        guard isEnabled(host: host.id), hostStates[host.id]?.revokeFailed != true else { return }
        do {
            let existing = try keychain.read(host.id)
            let token = deviceTokenHex ?? existing?.deviceTokenHex
            guard let token else { throw PushError.noDeviceToken }
            let credential: PushKeychain.Credential
            if renewedThisSession.contains(host.id), let existing, existing.deviceTokenHex == token {
                guard reconnect else { return }
                credential = existing
            } else {
                let generation = foregroundGeneration
                credential = try await resolveCredential(hostID: host.id, tokenHex: token)
                if generation == foregroundGeneration { renewedThisSession.insert(host.id) }
            }
            try await registerWithHost(host, credential)
            hostStates[host.id]?.error = nil
        } catch { hostStates[host.id]?.error = error.localizedDescription }
    }
    private func registerWithHost(_ host: MobileHost, _ credential: PushKeychain.Credential) async throws {
        hostStates[host.id]?.registered = false
        if let client = host.connectedClient, hostSupportsPush(host) {
            try await client.registerPush(RemotePushRegistration(id: credential.registrationID, sendToken: credential.sendToken))
            hostStates[host.id]?.registered = true
        }
    }

    func refreshPermission() async {
        guard !isFixture else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        for id in hostStates.keys {
            if settings.authorizationStatus == .denied, hostStates[id]?.enabled == true {
                hostStates[id]?.permissionDenied = true
                hostStates[id]?.error = PushError.permissionDenied.localizedDescription
            } else if settings.authorizationStatus != .denied, hostStates[id]?.permissionDenied == true {
                hostStates[id]?.permissionDenied = false
                hostStates[id]?.error = nil
            }
        }
    }
    @ObservationIgnored var onTokenChanged: (() -> Void)?
    func setDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let changed = deviceTokenHex != hex
        deviceTokenHex = hex
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: hex) }
        if changed { onTokenChanged?() }
    }
    func setTokenError(_ error: Error) {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
        for id in enabledHosts { hostStates[id]?.error = error.localizedDescription }
    }
    func obtainDeviceToken() async throws -> String {
        if let token = deviceTokenHex { return token }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            tokenWaiters[id] = continuation
            Task { [weak self, tokenTimeout] in
                try? await Task.sleep(for: tokenTimeout)
                self?.tokenWaiters.removeValue(forKey: id)?.resume(throwing: PushError.noDeviceToken)
            }
            if tokenWaiters.count == 1 { registerToken() }
        }
    }
    func resetSession() {
        foregroundGeneration += 1
        renewedThisSession.removeAll()
    }
    private func markRevoking(_ id: UUID) {
        hostStates[id, default: HostPushState()].revokeFailed = true
        persistEnabledHosts()
    }
    private func persistEnabledHosts() {
        defaults.set(hostStates.filter(\.value.revokeFailed).map(\.key.uuidString), forKey: Self.revokingHostsKey)
        defaults.set(enabledHosts.map(\.uuidString), forKey: Self.enabledHostsKey)
        onEnabledHostsChanged?(enabledHosts)
    }
}

struct PushKeychainAccess: Sendable {
    var read: @Sendable (UUID) throws -> PushKeychain.Credential?
    var save: @Sendable (PushKeychain.Credential, UUID) throws -> Void
    var remove: @Sendable (UUID) throws -> Void
    static let real = PushKeychainAccess(
        read: { try PushKeychain.read(host: $0) },
        save: { try PushKeychain.save($0, host: $1) },
        remove: { try PushKeychain.remove(host: $0) }
    )
    static func memory(_ backing: PushKeychainMemory = PushKeychainMemory()) -> PushKeychainAccess {
        PushKeychainAccess(read: { backing.read(host: $0) }, save: { backing.save($0, host: $1) }, remove: { backing.remove(host: $0) })
    }
}
