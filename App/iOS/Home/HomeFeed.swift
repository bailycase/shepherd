import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Home across every host (home track): Needs you, Recents, the hosts' cards and the
/// automations, derived once per change (`FleetModel`) from each host's pushed state and one
/// thread snapshot per agent that matters. Views read `model` and never derive rows.
///
/// Snapshots are asked for only while a Home surface is on screen (`watch()`), and only for
/// agents that run, wait on the user, or have subagents still running (`FleetDigest.watches`;
/// an unchanged thread costs one small answer). A thread open on this device is read from its
/// own store (`openSnapshot`) instead. The rest are read once per connection, a few per poll,
/// only from a host that serves them as previews from pi's session file without starting pi
/// (`nativeThreadPreviewCapability`); on an older host a snapshot request starts the agent's pi,
/// and a paired phone must not wake every idle agent (L23), so there their rows come from the
/// host's pushed state alone (`Agent.lastActiveAt`, `waitingOn`). Hosts are swept
/// concurrently, and a changed digest is published at the sweep's next wait (with whatever else
/// changed by then), so neither a slow host nor a slow thread later in a host's sweep holds back
/// what was already read. After a reconnect, a thread already digested is asked with its revision:
/// the host's `unchanged` (same pi session, generation and revision, which together name the
/// thread's content) keeps the digest without a page. A preview (pi not running) has no such
/// revision and is read again.
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
    @ObservationIgnored var projectNative: ((AgentRef, NativeThreadRequest) async throws -> NativeThreadResult)?
    /// The snapshot a thread store already holds for an agent (`ThreadStores`), when one does.
    @ObservationIgnored var openSnapshot: ((AgentRef) -> NativeThreadSnapshot?)?
    @ObservationIgnored private var inputs: [FleetHost] = []
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
    @ObservationIgnored private var digests: [FleetRef: FleetDigest] = [:]
    /// The host connection each digest was read in: a new connection reads every thread again.
    @ObservationIgnored private var readIn: [FleetRef: UUID] = [:]
    /// Threads whose digest's revision no longer names their content (another pi session or
    /// generation answered, or an answer was just sent): read whole next time.
    @ObservationIgnored private var readWhole: Set<FleetRef> = []
    /// A changed digest waits for `publish()`, at the sweep's next wait or its end.
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false

    /// Between polls of the threads that run or wait.
    static let interval: Duration = .seconds(3)
    /// Threads read once per connection as previews, at most this many per poll, so a host with
    /// many agents is read a few at a time.
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
        let designs = MobileDesigns.of(hosts)
        let (next, connections) = withObservationTracking {
            (hosts.hosts.map { host in
                FleetHost(id: host.id, name: host.name, address: host.record.address, port: host.record.port,
                          phase: host.phase, state: host.threadState, lastSeen: host.lastSeen, designs: designs.serving.contains(host.id))
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
        readWhole.formIntersection(live)
    }

    private func derive() {
        pending = false
        let next = FleetModel(hosts: inputs, digests: digests)
        if next != model { model = next }
    }

    /// A digest changed: Home shows it once the sweep next waits, in one derive with every other
    /// change made before then.
    private func publishSoon() {
        pending = true
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            publishScheduled = false
            publish()
        }
    }

    private func publish() {
        if pending { derive() }
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
            // One sequential sweep per host, all hosts at once; each publishes as it reads.
            await withTaskGroup(of: Void.self) { group in
                for host in hosts.hosts {
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return }
                        await self.sweep(host)
                        self.publish()
                    }
                }
            }
        } while again
    }

    /// Reads one host's threads that matter, publishing what changed as it goes.
    private func sweep(_ host: MobileHost) async {
        guard let client = host.connectedClient, let session = host.session,
              host.supports(RemoteProtocol.nativeThreadCapability) else { return }
        let previews = host.supports(RemoteProtocol.nativeThreadPreviewCapability)
        var quietReads = 0
        // A design's agent has no thread row to read for (its design is the row).
        // Nor has a mission's agent: its mission is the row.
        let state = host.threadState
        for agent in state.agents where !state.isDesignAgent(agent) {
            let ref = FleetRef(host: host.id, agent: agent.id)
            let digest = digests[ref]
            // A thread open on this device was read by its own store: Home takes that.
            if let value = openSnapshot?(ref.agentRef) {
                let next = FleetDigest(value)
                if next != digest {
                    digests[ref] = next
                    publishSoon()
                }
                readIn[ref] = session
                continue
            }
            let current = readIn[ref] == session
            if !FleetDigest.watches(status: agent.status, digest: digest) {
                guard previews, !current, quietReads < Self.quietReadsPerPoll else { continue }
                quietReads += 1
            }
            // Its revision even on a new connection: `unchanged` is checked against the digest's
            // pi session and generation below, so another process's equal number never passes.
            let request = NativeThreadRequest.snapshot(afterRevision: readWhole.contains(ref) ? nil : digest?.revision)
            let result: NativeThreadResult
            do {
                result = try await native(ref.agentRef, client: client, request: request)
            } catch RemoteHostClientError.rejected(let code, _) where code != "native_limit" {
                // This thread has none to read yet (pi starting) or any more (pi gone): the
                // host's other threads still answer.
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
                    publishSoon()
                }
                readIn[ref] = session
                readWhole.remove(ref)
            case .unchanged(let piSessionID, let generation, let revision):
                // Another session or generation: read the whole snapshot next time.
                if digest?.matches(piSessionID: piSessionID, generation: generation, revision: revision) == true {
                    readIn[ref] = session
                } else {
                    readIn[ref] = nil
                    readWhole.insert(ref)
                }
            case .failure, .accepted, .transcript, .imageChunk:
                // A thread still starting, or one that has none: try again next connection.
                readIn[ref] = session
            }
        }
    }

    // MARK: Answering

    /// Picks one of the offered options: pi's select takes it as its answer.
    func choose(_ item: FleetAttention, _ option: String) async {
        await answer(item, .select(value: option))
    }

    private func native(_ ref: AgentRef, client: RemoteHostClient, request: NativeThreadRequest) async throws -> NativeThreadResult {
        if let agent = hosts.host(ref.host)?.state.agents.first(where: { $0.id == ref.agent }),
           agent.coordinatorFor != nil || agent.projectWorkerFor != nil, let projectNative {
            return try await projectNative(ref, request)
        }
        return try await client.nativeThread(agentID: ref.agent, request: request)
    }

    /// Answers pi's question from Home.
    func answer(_ item: FleetAttention, _ answer: NativeDialogAnswer) async {
        await send(item) { session in
            guard let dialogID = item.dialogID else { return nil }
            return .answer(expectedSessionID: session.piSessionID, generation: session.generation, operationID: UUID(),
                           dialogID: dialogID, answer: answer)
        }
    }

    /// Sends the answer, then reads its thread again.
    private func send(_ item: FleetAttention, _ request: (NativeThreadSession) -> NativeThreadRequest?) async {
        guard let session = item.session, let request = request(session), !answering.contains(item.id),
              let client = hosts.host(item.ref.host)?.connectedClient else { return }
        answering.insert(item.id)
        failures[item.id] = nil
        defer { answering.remove(item.id) }
        do {
            let result = try await native(item.ref.agentRef, client: client, request: request)
            if case .failure(_, let message) = result { failures[item.id] = message }
        } catch RemoteHostClientError.rejected(_, let message), RemoteHostClientError.outcomeUnknown(let message) {
            failures[item.id] = message
        } catch {
            failures[item.id] = String(describing: error)
        }
        readIn[item.ref] = nil
        readWhole.insert(item.ref)
        await refresh()
    }
}
