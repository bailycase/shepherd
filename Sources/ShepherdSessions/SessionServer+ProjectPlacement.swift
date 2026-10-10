import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension SessionServer {
    /// Advertised by the owner's transport directory, not by a viewer or a model.
    public func setProjectExecutionSpaces(_ spaces: [ProjectHostReference: [Space]]) {
        queue.async {
            self.projectExecutionSpaces = spaces
        }
    }

    func validateProjectDestination(_ host: ProjectHostReference, spaceID: SpaceID) throws {
        let spaces = host == .local ? store.state.spaces : projectExecutionSpaces[host] ?? []
        guard Project.validID(spaceID.rawValue), spaces.contains(where: { $0.id == spaceID && !$0.hidden }) else {
            throw LogicalProjectsError(host == .local ? "no_such_space" : "project_destination", "Space or exact host binding is unavailable, offline or does not support Project execution. No local fallback is allowed.")
        }
    }

    func validateProjectPlacement(_ p: Project, host: ProjectHostReference, spaceID: SpaceID) throws {
        try requireProjectsEnabled()
        guard p.settings.hostPolicy == .anyConnected || p.settings.allowedHosts.contains(host),
              p.linkedSpaces.contains(where: { $0.destination == host && $0.spaceID == spaceID }) else {
            throw LogicalProjectsError("project_scope", "Choose an explicitly linked Space on a permitted owner-relative host.")
        }
        try validateProjectDestination(host, spaceID: spaceID)
        if host != .local, onProjectPlacement == nil { throw LogicalProjectsError("unsupported", "Owner placement is unavailable.") }
    }

    func projectAssignment(_ project: Project, task: ProjectTask, defaultModel: String?) throws -> ProjectExecutionAssignment {
        // A nil executor model would silently pick that host's provider. Pin the owner's model.
        guard let model = project.settings.threadModel ?? defaultModel else {
            throw LogicalProjectsError("project_model", "Choose an explicit worker model before remote placement; the owner default is unavailable.")
        }
        var assignment = ProjectExecutionAssignment(key: .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID),
            taskID: task.id, reservedWorkerID: task.workerAgentID, executorSpaceID: task.spaceID,
            title: NativeRedaction.projectData(task.title), prompt: NativeRedaction.projectData(task.prompt),
            goal: NativeRedaction.projectData(project.goal), instructions: NativeRedaction.projectData(project.settings.instructions),
            memory: NativeRedaction.projectData(project.memory.map(\.text).joined(separator: "\n")), model: model)
        assignment.publicationsEnabled = true
        try assignment.validate()
        guard assignment.nativePrompt.utf8.count <= RPCThreadState.textLimit else {
            throw LogicalProjectsError("invalid_execution", "Assignment plus selected Project context exceeds 16 KiB. Shorten it before dispatch.")
        }
        return assignment
    }

    /// Change hints and reconnects only pull retained receipts; never mint an operation or launch.
    public func reconcileProjectExecutions(host: ProjectHostReference, key: ProjectExecutionKey? = nil) {
        queue.async {
            for project in self.store.state.projects {
                for artifact in project.artifacts where artifact.executor == host && artifact.state == .staged {
                    self.startPublicationTransfer(artifact)
                }
                for task in project.tasks where task.destination == host {
                    guard let assignment = task.executionAssignment, key == nil || key == assignment.key else { continue }
                    self.requestProjectPlacement(task, request: .snapshot(key: assignment.key, watch: true))
                }
            }
        }
    }

    public func validateProjectPlacementRequest(_ request: ProjectExecutionRequest) async throws {
        try await enqueue { try self.requireProjectPlacementAdmission(request) }
    }

    private func requireProjectPlacementAdmission(_ request: ProjectExecutionRequest) throws {
        switch request {
        case .execute, .resume, .answer:
            try requireProjectsEnabled()
            guard let project = store.state.projects.first(where: { $0.id == request.key.projectID && $0.ownerID == request.key.ownerID }),
                  !project.paused, projectRunStarts[project.id] != nil else {
                throw LogicalProjectsError("project_paused", "Project placement admission was revoked.")
            }
        case .pause, .cancel, .snapshot, .publicationRead: break
        }
    }

    func requestProjectPlacement(_ task: ProjectTask, request: ProjectExecutionRequest) {
        guard (try? requireProjectPlacementAdmission(request)) != nil else { return }
        guard let assignment = task.executionAssignment, let transport = onProjectPlacement else { return }
        let key = assignment.key, epoch = logicalProjectEpoch
        // Coalesce hints, not mutations: Pause must overtake an in-flight execute immediately.
        if case .snapshot = request {
            guard projectPlacementReads.insert(key).inserted else { projectPlacementAgain.insert(key); return }
        }
        if case .execute = request {
            guard let project = store.state.projects.first(where: { $0.id == key.projectID }), !project.paused,
                  projectRunStarts[project.id] != nil,
                  (try? validateProjectPlacement(project, host: task.destination, spaceID: task.spaceID)) != nil else { return }
        }
        hopToMain { transport(task.destination, request) { result in
            self.queue.async {
                guard self.logicalProjectEpoch == epoch else { return }
                if case .snapshot = request { self.projectPlacementReads.remove(key) }
                if case .answer = request {
                    self.changeRuntimeProject(key.projectID, { p in
                        guard let i = p.tasks.firstIndex(where: { $0.id == task.id && $0.operationID == key.operationID }) else { return }
                        switch result {
                        case .success: p.tasks[i].pendingAnswer?.phase = .delivered
                        case .failure(let error): p.tasks[i].pendingAnswer?.phase = (error as? LogicalProjectsError)?.code == "project_paused" ? .queued : .unknown
                        }
                    })
                }
                switch result {
                case .success(let value):
                    self.applyProjectExecution(value.receipt, task: task)
                    self.reconcileProjectPublications(value.receipt, task: task)
                case .failure(let error):
                    let detail = Self.executionText(NativeRedaction.projectData(String(describing: error)))
                    // A timeout/disconnect is not a refusal or free capacity. Reconnect reads
                    // this exact key. Even a missing receipt after restart never authorizes replay.
                    self.changeRuntimeProject(key.projectID, { p in
                        guard let i = p.tasks.firstIndex(where: { $0.id == task.id && $0.operationID == key.operationID }), p.tasks[i].phase.occupiesSlot else { return }
                        if case .snapshot = request, p.tasks[i].error != nil { return }
                        p.tasks[i].error = "Executor outcome unavailable; original reservation retained. " + detail
                    })
                }
                if case .execute = request { self.requestProjectPlacement(task, request: .snapshot(key: key, watch: true)) }
                if self.projectPlacementAgain.remove(key) != nil { self.requestProjectPlacement(task, request: .snapshot(key: key, watch: true)) }
            }
        } }
    }

    private func applyProjectExecution(_ receipt: ProjectExecutionReceipt, task: ProjectTask) {
        guard let assignment = task.executionAssignment, receipt.key == assignment.key,
              receipt.assignment == assignment || (receipt.assignment == nil && receipt.phase == .cancelled),
              (try? receipt.validate()) != nil else { return }
        if receipt.assignment != nil, receipt.previousOperationID != task.previousOperations?.last { return }
        guard let current = store.state.projects.first(where: { $0.id == assignment.key.projectID })?.tasks.first(where: { $0.id == task.id }),
              current.operationID == assignment.key.operationID,
              current.executionReceipt.map({ $0.revision < receipt.revision || (current.phase == .unknown && $0.revision == receipt.revision) }) ?? true else { return }
        changeRuntimeProject(assignment.key.projectID, { p in
            guard let i = p.tasks.firstIndex(where: { $0.id == task.id && $0.operationID == assignment.key.operationID }),
                  p.tasks[i].executionReceipt.map({ $0.revision < receipt.revision || (p.tasks[i].phase == .unknown && $0.revision == receipt.revision) }) ?? true else { return }
            p.tasks[i].executionReceipt = receipt
            p.tasks[i].workerSessionID = receipt.sessionID
            p.tasks[i].question = receipt.phase == .waiting ? receipt.question : nil
            p.tasks[i].error = receipt.outcome
            p.tasks[i].revision += 1
            switch receipt.phase {
            case .reserved, .sendReserved: p.tasks[i].phase = .reserved
            case .sent, .interruptPending: p.tasks[i].phase = .running
            case .waiting: p.tasks[i].phase = .waiting
            case .unknown: p.tasks[i].phase = .unknown
            case .failed: p.tasks[i].phase = .failed
            case .cancelled: p.tasks[i].phase = receipt.matchedUserEntryID == nil ? .failed : .settled
            case .settled: p.tasks[i].phase = .settled
            }
            if p.tasks[i].phase == .settled { p.tasks[i].settledAt = Date().timeIntervalSince1970 * 1000 }
            let kind: ProjectEventSource.Kind?
            switch receipt.phase { case .waiting: kind = .question; case .settled: kind = .settled; case .failed: kind = .failed; default: kind = nil }
            if let kind {
                let source = ProjectEventSource(kind: kind, taskID: task.id, operationID: task.operationID,
                    workerAgentID: task.workerAgentID, sessionID: receipt.sessionID, dialogID: kind == .question ? receipt.questionID : nil,
                    generation: kind == .question ? receipt.generation : nil)
                let evidence = ["questionID": receipt.questionID, "question": receipt.question, "kind": receipt.questionKind,
                    "message": receipt.questionMessage, "resultEntryID": receipt.resultEntryID, "result": receipt.resultText, "outcome": receipt.outcome]
                let data = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
                Self.appendProjectEvent(&p, source: source, data: data)
            }
        }) { p in
            if p.paused {
                if p.interruptPending && receipt.phase.active && receipt.ownerPaused != true { self.interruptProjectPlacements(p) }
                self.finishProjectInterruption(p.id)
            } else { self.pumpProject(p.id) }
        }
    }

    func interruptProjectPlacements(_ project: Project) {
        for task in project.tasks where task.phase.occupiesSlot {
            guard let assignment = task.executionAssignment else { continue }
            let receipt = task.executionReceipt
            if receipt?.ownerPaused == true && receipt?.helpersStopped == true && receipt?.phase == .waiting { continue }
            requestProjectPlacement(task, request: .pause(key: assignment.key))
        }
    }

    func resumeProjectPlacements(_ id: ProjectID) {
        guard projectsEnabled, let p = store.state.projects.first(where: { $0.id == id }), !p.paused, projectRunStarts[id] != nil else { return }
        // Resume authorizes retained outputs too, including workers that already settled.
        for artifact in p.artifacts where artifact.executor != nil && artifact.state == .staged {
            startPublicationTransfer(artifact)
        }
        for task in p.tasks {
            if let receipt = task.executionReceipt { reconcileProjectPublications(receipt, task: task) }
        }
        for task in p.tasks where task.phase.occupiesSlot {
            guard let assignment = task.executionAssignment,
                  (try? validateProjectPlacement(p, host: task.destination, spaceID: task.spaceID)) != nil else { continue }
            requestProjectPlacement(task, request: task.executionReceipt == nil ? .execute(assignment) : .resume(key: assignment.key))
        }
    }
}
