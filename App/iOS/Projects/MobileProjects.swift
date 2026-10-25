import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

struct MobileProjectRow: Identifiable, Equatable {
    let ref: LogicalProjectRef
    let name: String
    let owner: String
    let summary: String
    let needsYou: Int
    let connected: Bool
    var id: LogicalProjectRef { ref }
}

struct MobileProjectOwner: Identifiable, Equatable {
    let id: UUID
    let name: String
    let connected: Bool
    let supported: Bool
    let spaces: [Space]
}

struct MobileProjectThreadKey: Hashable {
    let ref: LogicalProjectRef
    let owner: UUID?
    let task: ProjectTaskID?
}

@MainActor
final class MobileProjectThread {
    let store = NativeThreadStore()
    let composer = ComposerState()
    let viewers: NativeThreadViewers
    init() { viewers = NativeThreadViewers(store: store) }
}

/// Projects belong to a paired host. The phone owns only presentation, drafts and viewers.
@MainActor @Observable
final class MobileProjects {
    let model: LogicalProjectsModel
    private(set) var rows: [MobileProjectRow] = []
    private(set) var owners: [MobileProjectOwner] = []
    private(set) var pages: [LogicalProjectRef: ProjectPagePresentation] = [:]
    @ObservationIgnored let hosts: MobileHosts
    @ObservationIgnored private var threads: [MobileProjectThreadKey: MobileProjectThread] = [:]
    @ObservationIgnored private var bindings: [UUID: UUID] = [:]

    init(hosts: MobileHosts) {
        self.hosts = hosts
        model = LogicalProjectsModel(send: { home, request in
            try await Self.request(hosts, home: home, capability: RemoteProtocol.logicalProjectsCapability) {
                try await $0.logicalProjects(request)
            }
        }, pushed: { home in
            guard case .host(let id) = home else { return [] }
            return hosts.host(id)?.state.projects ?? []
        }, runtime: { ref, revision, request in
            let reply = try await Self.runtime(hosts, ref: ref, request: .action(projectID: ref.id, expectedRevision: revision, request: request))
            guard case .project(let project) = reply else { throw Self.unexpected }
            return project
        })
        model.answerQuestion = { ref, _, task, request in
            let reply = try await Self.runtime(hosts, ref: ref, request: .worker(projectID: ref.id, taskID: task, request: request))
            guard case .native(let native) = reply else { throw Self.unexpected }
            return native
        }
        model.ownerHosts = { home in
            let reply = try await Self.request(hosts, home: home, capability: RemoteProtocol.logicalProjectRuntimeCapability) {
                try await $0.projectRuntime(.hosts)
            }
            guard case .hosts(let options) = reply else { throw Self.unexpected }
            return options
        }
        track()
    }

    func host(_ ref: LogicalProjectRef) -> MobileHost? {
        guard case .host(let id) = ref.home else { return nil }
        return hosts.host(id)
    }

    func canEdit(_ ref: LogicalProjectRef) -> Bool {
        guard let host = host(ref) else { return false }
        return host.connectedClient != nil && host.supports(RemoteProtocol.logicalProjectsCapability) && !model.busy.contains(ref)
    }

    func canRun(_ ref: LogicalProjectRef) -> Bool {
        canEdit(ref) && host(ref)?.supports(RemoteProtocol.logicalProjectRuntimeCapability) == true
    }

    func thread(_ ref: LogicalProjectRef, task: ProjectTaskID? = nil) -> MobileProjectThread {
        let key = MobileProjectThreadKey(ref: ref, owner: model.project(ref)?.ownerID, task: task)
        if let thread = threads[key] { return thread }
        let thread = MobileProjectThread()
        threads[key] = thread
        return thread
    }

    func native(_ ref: LogicalProjectRef, task: ProjectTaskID? = nil, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let owner = model.project(ref)?.ownerID else {
            return .failure(code: NativeThreadCode.unavailable, message: "The Project is no longer available.")
        }
        let transport: ProjectRuntimeTransport = task.map { .worker(projectID: ref.id, taskID: $0, request: request) }
            ?? .conversation(projectID: ref.id, request: request)
        let reply = try await Self.runtime(hosts, ref: ref, request: transport)
        guard model.project(ref)?.ownerID == owner else { throw CancellationError() }
        guard case .native(let native) = reply else { throw Self.unexpected }
        return native
    }

    func native(agent ref: AgentRef, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let agent = hosts.host(ref.host)?.state.agents.first(where: { $0.id == ref.agent }) else {
            return .failure(code: NativeThreadCode.unavailable, message: "The thread is no longer available.")
        }
        if let id = agent.coordinatorFor {
            return try await native(LogicalProjectRef(home: .host(ref.host), id: id), request: request)
        }
        if let id = agent.projectWorkerFor {
            let project = LogicalProjectRef(home: .host(ref.host), id: id)
            guard let record = model.project(project),
                  let task = record.tasks.first(where: { $0.workerAgentID == ref.agent }) else {
                return .failure(code: NativeThreadCode.unavailable, message: "The Project's thread is no longer available.")
            }
            return try await native(project, task: task.id, request: request)
        }
        return .failure(code: NativeThreadCode.unavailable, message: "The Project's thread is no longer available.")
    }

    func refresh() async {
        for owner in owners where owner.connected && owner.supported {
            await model.refresh(.host(owner.id))
        }
    }

    func forget(_ id: UUID) {
        rebind(id)
        for key in threads.keys where key.ref.home == .host(id) { threads[key]?.composer.forget() }
        threads = threads.filter { $0.key.ref.home != .host(id) }
    }

    private func rebind(_ id: UUID) {
        model.forget(.host(id))
        for (key, thread) in threads where key.ref.home == .host(id) {
            thread.viewers.rest(detached: true)
        }
        bindings.removeValue(forKey: id)
    }

    private func track() {
        withObservationTracking {
            for host in hosts.hosts {
                if let previous = bindings[host.id], previous != host.projectBinding { rebind(host.id) }
                bindings[host.id] = host.projectBinding
            }
            let current = Set(hosts.hosts.map(\.id))
            for id in bindings.keys where !current.contains(id) { forget(id) }
            owners = hosts.hosts.map { .init(id: $0.id, name: $0.name, connected: $0.connectedClient != nil,
                                            supported: $0.supports(RemoteProtocol.logicalProjectsCapability), spaces: $0.state.spaces) }
            var pages: [LogicalProjectRef: ProjectPagePresentation] = [:]
            rows = hosts.hosts.flatMap { host in
                model.list(.host(host.id)).map { project in
                    let ref = LogicalProjectRef(home: .host(host.id), id: project.id)
                    let page = ProjectPagePresentation(project)
                    pages[ref] = page
                    return MobileProjectRow(ref: ref, name: project.name, owner: host.name,
                                            summary: page.summary ?? project.goal, needsYou: page.needsYou,
                                            connected: host.connectedClient != nil)
                }
            }
            self.pages = pages
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private static var unexpected: LogicalProjectsError { .init("protocol", "Unexpected Project reply.") }

    private static func runtime(_ hosts: MobileHosts, ref: LogicalProjectRef, request: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult {
        try await Self.request(hosts, home: ref.home, capability: RemoteProtocol.logicalProjectRuntimeCapability) {
            try await $0.projectRuntime(request)
        }
    }

    private static func request<Value>(_ hosts: MobileHosts, home: LogicalProjectHome, capability: String,
                                       body: (RemoteHostClient) async throws -> Value) async throws -> Value {
        guard case .host(let id) = home, let host = hosts.host(id), let session = host.session,
              let client = host.connectedClient else {
            throw LogicalProjectsError("disconnected", "Connect to the project's host to continue.")
        }
        guard host.supports(capability) else {
            throw LogicalProjectsError("unsupported", "This host needs a newer Shepherd version for this Project action.")
        }
        let binding = host.projectBinding
        let result: Result<Value, Error>
        do { result = .success(try await body(client)) }
        catch { result = .failure(error) }
        guard hosts.host(id) === host, host.projectBinding == binding,
              host.session == session, host.connectedClient === client else { throw CancellationError() }
        return try result.get()
    }
}
