import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

@MainActor
enum ProjectFixtures {
    static let projectID = ProjectID(rawValue: "fixture-project")
    static let waitingID = ProjectTaskID(rawValue: "fixture-question")
    static let ref = LogicalProjectRef(home: .host(FixtureData.studio), id: projectID)

    static var screens: [FixtureScreen] {
        let backend = ProjectFixtureBackend()
        let host = backend.host
        var unsupported = FixtureHostData(id: FixtureData.studio, name: "Studio", state: ShepherdState())
        unsupported.capabilities = RemoteProtocol.capabilities.filter { !$0.hasPrefix("logicalProject") }
        let prepare: @MainActor (MobileApp) async -> Void = { app in
            await app.projects.model.refresh(ref.home)
            if app.navigator.layout == .pad, app.navigator.padSidebarOverlays, !app.navigator.padPath.isEmpty {
                await FixtureWindows.wait("project detail not covered by the sidebar", seconds: 5) {
                    app.navigator.padColumns == .detailOnly
                }
            }
        }
        return [
            FixtureScreen(name: "projects", hosts: [host], routes: [.projects(.list)], prepare: prepare),
            FixtureScreen(name: "project", hosts: [host], routes: [.projects(.project(ref))], prepare: prepare),
            FixtureScreen(name: "project-tasks", hosts: [host], routes: [.projects(.tasks(ref))], prepare: prepare),
            FixtureScreen(name: "project-task", hosts: [host], routes: [.projects(.task(ref, waitingID))], prepare: prepare),
            FixtureScreen(name: "project-files", hosts: [host], routes: [.projects(.files(ref, path: ""))], prepare: prepare),
            FixtureScreen(name: "project-settings", hosts: [host], routes: [.projects(.settings(ref))], prepare: prepare),
            FixtureScreen(name: "project-new", hosts: [host], presented: .projects(.create(host: FixtureData.studio)), prepare: prepare),
            FixtureScreen(name: "project-assign", hosts: [host], presented: .projects(.assign(ref)), prepare: prepare),
            FixtureScreen(name: "projects-unsupported", hosts: [unsupported], routes: [.projects(.list)]),
            FixtureScreen(name: "project-regressions", hosts: [host], routes: [.projects(.project(ref))], prepare: { app in
                await regressions(app, backend: backend)
            }),
        ]
    }

    private static func regressions(_ app: MobileApp, backend: ProjectFixtureBackend) async {
        let projects = app.projects, model = projects.model
        await model.refresh(ref.home)
        backend.includeCoordinatorQuestion()
        let feed = HomeFeed.of(app.hosts)
        await feed.refresh()
        await FixtureCheck.wait("project questions after orphan worker", seconds: 10) {
            feed.model.needsYou.filter { $0.origin == .project && $0.dialogID != nil }.count == 2
        }
        let questions = feed.model.needsYou.filter { $0.origin == .project && $0.dialogID != nil }
        check(questions.count == 2, "projects: removed workers do not prevent owner and worker questions reaching Needs you")
        for item in questions {
            check(projects.route(item).isProjects, "projects: attention opens a project destination")
            await feed.choose(item, "Beside the thread")
            check(feed.failures[item.id] == nil, "projects: inline answers use the owner's project transport")
        }
        check(projects.rows.contains { $0.ref == ref }, "projects: a paired owner's project is discoverable")
        let native = try? await projects.native(ref, request: .snapshot())
        check(native != nil, "projects: conversation uses owner-scoped runtime transport")
        let worker = try? await projects.native(ref, task: waitingID, request: .snapshot())
        check(worker != nil, "projects: worker transcript uses owner-scoped runtime transport")
        if case .snapshot(let snapshot)? = worker, let dialog = snapshot.dialogs.first {
            let request = NativeThreadRequest.answer(expectedSessionID: snapshot.piSessionID,
                                                    generation: snapshot.generation, operationID: UUID(),
                                                    dialogID: dialog.id, answer: .select(value: "Beside the thread"))
            check(await model.answer(ref, task: waitingID, request: request), "projects: questions let the owner choose managed or ordinary worker delivery")
        } else { FixtureCheck.fail("projects: the worker's question is visible") }
        if let listing = try? await model.files(ref, path: ""), let file = try? await model.read(ref, path: "summary.md") {
            check(listing.entries.contains { $0.relativePath == "summary.md" } && file.data == ProjectFixtureBackend.report,
                                "projects: files and preview bytes come from the owner")
        } else { FixtureCheck.fail("projects: owner-relative files are readable") }
        backend.failNextMessage()
        let unknown = await model.sendMessage(ref, text: "Keep this draft for an explicit retry")
        check(!unknown, "projects: ambiguous send is not reported as accepted")
        let accepted = await model.sendMessage(ref, text: "Keep this draft for an explicit retry")
        check(accepted && backend.messageOperations.count == 2 && Set(backend.messageOperations).count == 1,
                            "projects: explicit retry reuses its operation without an automatic retry")
        let changed = await model.edit(ref, name: "Ship the iOS client", goal: "One native client on every display")
        check(changed && model.project(ref)?.name == "Ship the iOS client", "projects: edit is revisioned through its owner")
        let settings = await model.saveSettings(ref) { $0.maxConcurrentWorkers = 2 }
        check(settings && model.project(ref)?.settings.maxConcurrentWorkers == 2, "projects: bounded settings are editable")
        let assigned = await model.run(ref, .assign(operationID: UUID(), spaceID: FixtureData.shepherdSpace.id,
                                                   title: "Check the release", prompt: "Run the release checks"))
        check(assigned && model.project(ref)?.tasks.contains { $0.title == "Check the release" } == true,
              "projects: task assignment is accepted by its owner")
        let newID = ProjectID(rawValue: "fixture-created")
        let created = await model.create(home: ref.home, id: newID, name: "Release checks", goal: "", spaces: [])
        check(created?.id == newID, "projects: creation retains the selected owner")
        if let created {
            check(await model.delete(LogicalProjectRef(home: ref.home, id: created.id)), "projects: deletion targets the new record only")
        }
        let wire = FixtureHost.running(FixtureData.studio)?.requests ?? []
        check(!wire.contains { $0.hasPrefix("nativeThread") }, "projects: no project action uses ordinary-agent transport")
        let thread = projects.thread(ref)
        thread.store.draft = "A draft kept while switching projects"
        check(projects.thread(ref).store === thread.store, "projects: conversation drafts keep one store per owner")
        guard case .host(let id) = ref.home, let host = app.hosts.host(id) else { FixtureCheck.fail("Missing fixture owner") }
        do {
            try app.hosts.edit(id, RemoteHostEntry(name: host.name, address: host.record.address,
                                                 port: String(host.record.port), token: FixtureHostData.token))
        } catch { FixtureCheck.fail("Cannot refresh fixture credentials: \(error)") }
        await FixtureCheck.wait("project owner reconnect", seconds: 10) {
            host.phase.isConnected && !host.state.projects.isEmpty
        }
        check(projects.thread(ref).store === thread.store && thread.store.draft == "A draft kept while switching projects",
              "projects: credential refresh keeps a confirmed owner's draft")
    }

    private static func check(_ condition: Bool, _ message: String) {
        FixtureCheck.report("FIXTURE CHECK \(condition ? "ok" : "FAILED"): \(message)")
    }
}

/// Only this track opts into project requests. Writes change this in-memory record, never files,
/// processes, a real host, or a model. The request path is the production remote client.
private final class ProjectFixtureBackend: @unchecked Sendable {
    static let report = Data("# Release checks\n\nThe native client renders in light and dark.\n".utf8)
    private let lock = NSLock()
    private var records: [Project]
    private var refuseMessage = false
    private var coordinatorQuestion = false
    func includeCoordinatorQuestion() { lock.withLock { coordinatorQuestion = true } }
    private var operations: [UUID] = []
    var messageOperations: [UUID] { lock.withLock { operations } }
    func failNextMessage() { lock.withLock { refuseMessage = true } }

    @MainActor init() {
        var question = ProjectTask(id: ProjectFixtures.waitingID, operationID: UUID(), workerAgentID: FixtureData.dock,
                                   spaceID: FixtureData.shepherdSpace.id, title: "Choose the release target", prompt: "Confirm the target.", phase: .waiting)
        question.question = "Which release target should I use?"
        let running = ProjectTask(operationID: UUID(), workerAgentID: FixtureData.extensions, spaceID: FixtureData.shepherdSpace.id,
                                  title: "Build the adaptive layout", prompt: "Build the native layout.", phase: .running)
        let stopped = ProjectTask(operationID: UUID(), workerAgentID: FixtureData.preview, spaceID: FixtureData.shepherdSpace.id,
                                  title: "Check accessibility", prompt: "Check keyboard and VoiceOver.", phase: .settled)
        var project = Project(id: ProjectFixtures.projectID, name: "Native iOS client", goal: "Ship one native client on every display.",
                              revision: 4, linkedSpaces: [ProjectSpaceLink(spaceID: FixtureData.shepherdSpace.id, linkedAt: FixtureData.start)])
        project.tasks = [question, running, stopped]
        project.coordinatorAgentID = AgentID(rawValue: "fixture-coordinator")
        records = [project]
    }

    var host: FixtureHostData {
        var data = FixtureHostData(id: FixtureData.studio, name: "Studio", state: state)
        data.projectReply = { [self] request in reply(request) }
        data.reply = { [self] request in
            if case .stateFetch(let id) = request { return .state(id: id, state: state) }
            return reply(request)
        }
        return data
    }

    private var state: ShepherdState {
        lock.withLock {
            var state = ShepherdState(spaces: [FixtureData.shepherdSpace])
            state.projects = records
            for project in records {
                if let id = project.coordinatorAgentID {
                    state.agents.append(Agent(id: id, name: "Project owner", spaceID: FixtureData.shepherdSpace.id,
                                              tabID: TabID(), status: .blocked, coordinatorFor: project.id))
                }
                for task in project.tasks where task.question != nil {
                    let id = task.workerAgentID
                    var worker = Agent(id: id, name: task.title, spaceID: FixtureData.shepherdSpace.id,
                                       tabID: TabID(), status: .blocked)
                    worker.projectWorkerFor = project.id
                    state.agents.append(worker)
                }
            }
            var orphan = Agent(id: AgentID(rawValue: "fixture-orphan-worker"), name: "Removed Project's worker",
                               spaceID: FixtureData.shepherdSpace.id, tabID: TabID(), status: .blocked)
            orphan.projectWorkerFor = ProjectID(rawValue: "fixture-removed-project")
            state.agents.insert(orphan, at: 0)
            return state
        }
    }

    private func reply(_ request: RemoteRequest) -> RemoteReply? {
        lock.withLock {
            switch request {
            case .hello(let id, let token, _, _, _):
                guard token == FixtureHostData.token else { return .error(id: id, code: "unauthorized", message: "Bad token") }
                return .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities)
            case .logicalProjects(let id, let request):
                switch request {
                case .list: return .logicalProjects(id: id, result: .projects(records))
                case .create(let projectID, let name, let goal, let spaces):
                    if let old = records.first(where: { $0.id == projectID }) { return .logicalProjects(id: id, result: .project(old)) }
                    let project = Project(id: projectID, name: name, goal: goal,
                                          linkedSpaces: spaces.map { ProjectSpaceLink(spaceID: $0, linkedAt: FixtureData.start) })
                    records.append(project)
                    return .logicalProjects(id: id, result: .project(project))
                default: break
                }
                guard let index = records.firstIndex(where: { $0.id == request.projectID }) else {
                    return .error(id: id, code: "project_not_found", message: "The project no longer exists.")
                }
                if let revision = request.expectedRevision, revision != records[index].revision {
                    return .error(id: id, code: "stale_project", message: "The project changed. Review it and try again.")
                }
                switch request {
                case .get: return .logicalProjects(id: id, result: .project(records[index]))
                case .files(let projectID, let path):
                    let entry = LogicalProjectFileEntry(name: "summary.md", relativePath: "summary.md", kind: .file,
                                                        size: Int64(Self.report.count), modifiedAt: FixtureData.start)
                    return .logicalProjects(id: id, result: .files(LogicalProjectFileListing(projectID: projectID, path: path, entries: [entry], truncated: false)))
                case .read(let projectID, let path):
                    guard path == "summary.md" else { return .error(id: id, code: "file_not_found", message: "No such file.") }
                    return .logicalProjects(id: id, result: .file(LogicalProjectFile(projectID: projectID, relativePath: path, mimeType: "text/markdown", data: Self.report)))
                case .edit(_, _, let name, let goal): records[index].name = name; records[index].goal = goal
                case .settings(_, _, let settings): records[index].settings = settings
                case .delete(let projectID, _): records.remove(at: index); return .logicalProjects(id: id, result: .deleted(projectID: projectID))
                default: return .error(id: id, code: "unsupported", message: "No fixture answer for this action.")
                }
                records[index].revision += 1
                return .logicalProjects(id: id, result: .project(records[index]))
            case .logicalProjectRuntime(let id, let request):
                switch request {
                case .hosts: return .logicalProjectRuntime(id: id, result: .hosts([]))
                case .conversation(_, let native):
                    return .logicalProjectRuntime(id: id, result: .native(nativeReply(native, worker: false)))
                case .worker(_, _, let native):
                    return .logicalProjectRuntime(id: id, result: .native(nativeReply(native, worker: true)))
                case .answer:
                    return .error(id: id, code: "project_scope", message: "The worker route must choose the question's current owner.")
                case .action(let projectID, let revision, let action):
                    guard let index = records.firstIndex(where: { $0.id == projectID }), revision == records[index].revision else {
                        return .error(id: id, code: "stale_project", message: "The project changed.")
                    }
                    if case .message(let operationID, _, _) = action {
                        operations.append(operationID)
                        if refuseMessage { refuseMessage = false; return .error(id: id, code: "unknown", message: "The reply did not arrive. Retry explicitly.") }
                    } else if case .assign(let operation, let space, let title, let prompt, _, _, _) = action {
                        records[index].tasks.append(ProjectTask(operationID: operation, spaceID: space,
                                                                 title: title, prompt: prompt, phase: .queued))
                    } else { return .error(id: id, code: "unsupported", message: "No fixture answer for this action.") }
                    records[index].revision += 1
                    return .logicalProjectRuntime(id: id, result: .project(records[index]))
                }
            default: return nil
            }
        }
    }

    private func nativeReply(_ request: NativeThreadRequest, worker: Bool) -> NativeThreadResult {
        if case .snapshot = request {
            let snapshot = worker || coordinatorQuestion ? FixtureData.questionThread() : FixtureData.snapshot([
                FixtureData.user("p1", "Finish the iPhone and iPad client, and keep me in the loop when a release decision needs me."),
                FixtureData.assistant("p2", "The adaptive layout is underway. One thread is checking accessibility, and the release thread has a question for you.", at: 15_000),
            ])
            return .snapshot(value: snapshot)
        }
        switch request {
        case .send(_, _, let operation, _, _, _, _, _, _), .answer(_, _, let operation, _, _), .abort(_, _, let operation):
            return .accepted(operationID: operation)
        default:
            return .failure(code: "unsupported", message: "This fixture has no answer for that action.")
        }
    }
}
