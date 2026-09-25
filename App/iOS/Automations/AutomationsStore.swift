import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's automations (automations track): the rows and details the screens draw,
/// derived once per change (`AutomationsModel`) from each host's pushed state and the runs it
/// kept, and the changes sent from here. Views read `model` and `details` and never derive.
///
/// Runs are read only while an Automations screen is on screen (`watch()`): once for every
/// automation on a host that serves them, and again for one whose run starts, ends or changes
/// state, which the host's pushed state says.
@MainActor
@Observable
final class AutomationsStore {
    struct Failure: Equatable, Identifiable {
        let id = UUID()
        let message: String
    }

    private(set) var model = AutomationsModel()
    /// Each automation's detail, derived with the model.
    private(set) var details: [AutomationKey: AutomationDetail] = [:]
    /// One line per connected host whose automations are read-only here, saying why.
    private(set) var readOnlyNotes: [String] = []
    /// Switches flipped here, until the host's state agrees or the change fails.
    private(set) var pendingEnabled: [AutomationKey: Bool] = [:]
    /// Automations with a change on its way: their controls wait.
    private(set) var busy: Set<AutomationKey> = []
    /// The last change a host refused.
    var failure: Failure?
    /// The automation the iPad shows beside the list; the first one when nil or gone.
    var chosen: AutomationKey?

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private var inputs: [AutomationHost] = []
    @ObservationIgnored private var runs: [AutomationKey: [AutomationRun]] = [:]
    /// What each automation's run looked like when its runs were last read (its agent and status).
    @ObservationIgnored private var readAt: [AutomationKey: String] = [:]
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
    @ObservationIgnored private var watchers = 0

    private static var stores: [ObjectIdentifier: AutomationsStore] = [:]

    /// The store of the app's hosts: one per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> AutomationsStore {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = AutomationsStore(hosts: hosts)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        track()
    }

    /// The switch as drawn: a change sent from here shows at once.
    func isOn(_ row: AutomationListRow) -> Bool {
        pendingEnabled[row.key] ?? row.enabled
    }

    /// Hosts a new automation can be saved on: connected, and serving automations.
    var editableHosts: [MobileHost] {
        hosts.hosts.filter { $0.phase.isConnected && $0.supports(RemoteProtocol.automationsCapability) }
    }

    // MARK: Inputs

    private func track() {
        let (next, connections) = withObservationTracking {
            (hosts.hosts.map { host in
                AutomationHost(id: host.id, name: host.name, connected: host.phase.isConnected,
                               manageable: host.supports(RemoteProtocol.automationsCapability), state: host.state)
            }, Dictionary(hosts.hosts.compactMap { host in host.session.map { (host.id, $0) } }, uniquingKeysWith: { a, _ in a }))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        if connections != sessions {
            // A new connection reads every run again.
            sessions = connections
            readAt = [:]
        }
        guard next != inputs else { return }
        inputs = next
        let live = Set(next.flatMap { host in host.state.automations.map { AutomationKey(host: host.id, automation: $0.id) } })
        runs = runs.filter { live.contains($0.key) }
        for (key, enabled) in pendingEnabled where Self.automation(key, in: next)?.enabled == enabled || !live.contains(key) {
            pendingEnabled[key] = nil
        }
        derive()
        if watchers > 0 { Task { await refreshRuns() } }
    }

    private func derive() {
        let next = AutomationsModel(hosts: inputs, runs: runs)
        var nextDetails: [AutomationKey: AutomationDetail] = [:]
        for row in next.rows {
            nextDetails[row.key] = next.detail(row.key, runs: runs[row.key])
        }
        var seen = Set<String>()
        let notes = next.rows.compactMap { row -> String? in
            guard !row.offline, let reason = row.abilities.readOnlyReason, seen.insert(reason).inserted else { return nil }
            return reason
        }
        if next != model { model = next }
        if nextDetails != details { details = nextDetails }
        if notes != readOnlyNotes { readOnlyNotes = notes }
    }

    private static func automation(_ key: AutomationKey, in hosts: [AutomationHost]) -> Automation? {
        hosts.first { $0.id == key.host }?.state.automations.first { $0.id == key.automation }
    }

    /// What decides whether an automation's runs need reading again: its agent and that agent's
    /// status.
    private static func signature(_ key: AutomationKey, in hosts: [AutomationHost]) -> String {
        guard let host = hosts.first(where: { $0.id == key.host }),
              let automation = host.state.automations.first(where: { $0.id == key.automation }) else { return "" }
        guard let agentID = automation.agentID else { return "none" }
        let status = host.state.agents.first { $0.id == agentID }?.status.rawValue ?? "gone"
        return "\(agentID.rawValue):\(status)"
    }

    // MARK: Runs

    /// Keeps the runs fresh while the calling view is on screen: run it from the view's `.task`.
    func watch() async {
        watchers += 1
        await refreshRuns()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watchers -= 1
    }

    /// Reads the runs of every automation whose run moved since they were last read.
    func refreshRuns() async {
        var changed = false
        for host in hosts.hosts {
            guard let client = host.connectedClient, host.supports(RemoteProtocol.automationsCapability) else { continue }
            for automation in host.state.automations {
                let key = AutomationKey(host: host.id, automation: automation.id)
                let signature = Self.signature(key, in: inputs)
                guard readAt[key] != signature else { continue }
                readAt[key] = signature
                guard let read = try? await client.automationRuns(automation.id) else {
                    readAt[key] = nil
                    continue
                }
                if runs[key] != read {
                    runs[key] = read
                    changed = true
                }
            }
        }
        if changed { derive() }
    }

    // MARK: Changes

    func setEnabled(_ key: AutomationKey, _ on: Bool) {
        pendingEnabled[key] = on
        send(key, .setEnabled(enabled: on)) { [weak self] ok in
            if !ok { self?.pendingEnabled[key] = nil }
        }
    }

    func run(_ key: AutomationKey) { send(key, .run) }

    func stop(_ key: AutomationKey) { send(key, .stop) }

    func delete(_ key: AutomationKey) { send(key, .delete) }

    /// Saves a new automation (`key` names the id this client minted) or an edited one. Throws
    /// the host's reason when it refuses.
    func save(_ key: AutomationKey, draft: RemoteAutomationDraft, creating: Bool) async throws {
        guard let client = hosts.host(key.host)?.connectedClient else { throw RemoteHostClientError.disconnected }
        busy.insert(key)
        defer { busy.remove(key) }
        try await client.automation(key.automation, request: creating ? .create(draft: draft) : .update(draft: draft))
    }

    private func send(_ key: AutomationKey, _ request: RemoteAutomationRequest, done: ((Bool) -> Void)? = nil) {
        guard !busy.contains(key) else { return }
        guard let client = hosts.host(key.host)?.connectedClient else {
            failure = Failure(message: "The host is offline.")
            done?(false)
            return
        }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await client.automation(key.automation, request: request)
                done?(true)
            } catch {
                failure = Failure(message: AutomationsModel.failureText(request, error))
                done?(false)
            }
        }
    }
}
