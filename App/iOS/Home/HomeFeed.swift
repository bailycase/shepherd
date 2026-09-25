import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Home across every host (home track): Needs you, Recents, the hosts' cards and the
/// automations, derived once per change (`FleetModel`) from each host's pushed state and one
/// thread snapshot per agent that matters. Views read `model` and never derive rows.
///
/// Snapshots are asked for only while a Home surface is on screen (`watch()`): every few
/// seconds for agents that run, wait on the user, or have subagents still running
/// (`FleetDigest.watches`; an unchanged thread costs one small answer), and once per connection for the rest, so Recents knows when each last moved.
@MainActor
@Observable
final class HomeFeed {
    /// Everything Home draws; written only when it changes.
    private(set) var model = FleetModel()
    /// Needs you items whose answer is on its way, by id.
    private(set) var answering: Set<String> = []
    /// Why an answer from Home did not land, by item id.
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private var inputs: [FleetHost] = []
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
    @ObservationIgnored private var digests: [FleetRef: FleetDigest] = [:]
    /// The host connection each digest was read in: a new connection reads every thread again.
    @ObservationIgnored private var readIn: [FleetRef: UUID] = [:]
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false

    /// Between polls of the threads that run or wait.
    static let interval: Duration = .seconds(3)
    /// Threads read once per connection, at most this many per poll, so a host with many
    /// agents is read a few at a time.
    static let quietReadsPerPoll = 6

    private static var feeds: [ObjectIdentifier: HomeFeed] = [:]

    /// The feed of the app's hosts: one per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> HomeFeed {
        if let feed = feeds[ObjectIdentifier(hosts)] { return feed }
        let feed = HomeFeed(hosts: hosts)
        feeds[ObjectIdentifier(hosts)] = feed
        return feed
    }

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        track()
    }

    // MARK: Inputs

    /// Reads the hosts under observation tracking, derives when they changed, and tracks again.
    private func track() {
        let (next, connections) = withObservationTracking {
            (hosts.hosts.map { host in
                FleetHost(id: host.id, name: host.name, address: host.record.address, port: host.record.port,
                          phase: host.phase, state: host.state)
            }, Dictionary(hosts.hosts.compactMap { host in host.session.map { (host.id, $0) } }, uniquingKeysWith: { a, _ in a }))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        let reconnected = connections != sessions
        sessions = connections
        if next != inputs {
            inputs = next
            prune()
            derive()
        }
        if reconnected, watchers > 0 { Task { await refresh() } }
    }

    private func prune() {
        let live = Set(inputs.flatMap { host in host.state.agents.map { FleetRef(host: host.id, agent: $0.id) } })
        for ref in digests.keys where !live.contains(ref) { digests[ref] = nil }
        for ref in readIn.keys where !live.contains(ref) { readIn[ref] = nil }
    }

    private func derive() {
        let next = FleetModel(hosts: inputs, digests: digests)
        if next != model { model = next }
    }

    // MARK: Polling

    /// Keeps the threads' digests fresh while the calling view is on screen: run it from the
    /// view's `.task`. Several surfaces share one poll.
    func watch() async {
        watchers += 1
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: Self.interval)
                }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watchers -= 1
        if watchers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    /// Reads what changed on every connected host now (pull to refresh, a new connection).
    func refresh() async {
        guard !refreshing else {
            again = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            again = false
            var changed = false
            for host in hosts.hosts {
                guard let client = host.connectedClient, let session = host.session,
                      host.supports(RemoteProtocol.nativeThreadCapability) else { continue }
                var quietReads = 0
                for agent in host.state.agents {
                    let ref = FleetRef(host: host.id, agent: agent.id)
                    let digest = digests[ref]
                    let current = readIn[ref] == session
                    let hot = FleetDigest.watches(status: agent.status, digest: digest)
                    if !hot {
                        if current || quietReads >= Self.quietReadsPerPoll { continue }
                        quietReads += 1
                    }
                    let request = NativeThreadRequest.snapshot(afterRevision: current ? digest?.revision : nil)
                    let result: NativeThreadResult
                    do {
                        result = try await client.nativeThread(agentID: agent.id, request: request)
                    } catch RemoteHostClientError.rejected(let code, _) where code != "native_limit" {
                        // This thread has none to read yet (pi starting) or any more (pi gone): the
                        // host's other threads still answer. A quiet one waits for the next connection.
                        readIn[ref] = session
                        continue
                    } catch {
                        // The connection is going, or the host asks for fewer requests; its host
                        // reports a lost connection itself.
                        break
                    }
                    guard hosts.host(host.id)?.session == session else { break }
                    switch result {
                    case .snapshot(let value):
                        let next = FleetDigest(value)
                        if next != digest {
                            digests[ref] = next
                            changed = true
                        }
                        readIn[ref] = session
                    case .unchanged(let piSessionID, let generation, let revision):
                        // Another session or generation: read the whole snapshot next time.
                        if digest?.matches(piSessionID: piSessionID, generation: generation, revision: revision) != true {
                            readIn[ref] = nil
                        }
                    case .failure, .accepted, .transcript:
                        // A thread still starting, or one that has none: try again next connection.
                        readIn[ref] = session
                    }
                }
            }
            if changed { derive() }
        } while again
    }

    // MARK: Answering

    /// Answers a question from Home, then reads its thread again.
    func answer(_ item: FleetAttention, _ answer: NativeDialogAnswer) async {
        guard let dialogID = item.dialogID, let session = item.session, !answering.contains(item.id),
              let client = hosts.host(item.ref.host)?.connectedClient else { return }
        answering.insert(item.id)
        failures[item.id] = nil
        defer { answering.remove(item.id) }
        do {
            let result = try await client.nativeThread(agentID: item.ref.agent, request: .answer(
                expectedSessionID: session.piSessionID, generation: session.generation, operationID: UUID(),
                dialogID: dialogID, answer: answer))
            if case .failure(_, let message) = result { failures[item.id] = message }
        } catch RemoteHostClientError.rejected(_, let message), RemoteHostClientError.outcomeUnknown(let message) {
            failures[item.id] = message
        } catch {
            failures[item.id] = String(describing: error)
        }
        readIn[item.ref] = nil
        await refresh()
    }
}
