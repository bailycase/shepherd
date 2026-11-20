import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project local runtime contracts")
struct ProjectRuntimeWireTests {
    static let task = ProjectTaskID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    static let space = SpaceID(rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    static let operation = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private static let id = Wire.projectKey.projectID
    private static let worker = AgentID(rawValue: "worker")
    private static let transport: [ProjectRuntimeTransport] = [.hosts, .action(projectID: id, expectedRevision: 2, request: .read),
        .conversation(projectID: id, request: .snapshot()), .worker(projectID: id, taskID: task, request: .snapshot()),
        .answer(projectID: id, expectedRevision: 2, taskID: task,
            request: .answer(expectedSessionID: "s", generation: "g", operationID: operation, dialogID: "q", answer: .confirm(value: true)))]
    private static let ownerRequests = transport.map { RemoteRequest.logicalProjectRuntime(id: 1, request: $0) }
    private static let answer = ProjectRuntimeRequest.answer(operationID: operation, taskID: task,
        questionEventID: operation, humanReplyID: operation, answer: .confirm(value: false))
    private static let answerRequest = RemoteRequest.logicalProjectRuntime(id: 9, request: .action(projectID: id, expectedRevision: 2, request: answer))
    private static let imageRequest = RemoteRequest.logicalProjectRuntime(id: 7, request: .action(projectID: id, expectedRevision: 1,
            request: .message(operationID: operation, text: "", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])))
    static let wireRequests = ownerRequests + [answerRequest, imageRequest]

    private static let ownerWithResult: Project = {
        var project = Wire.project(named: "Owner")
        let source = ProjectEventSource(kind: .settled, taskID: task, operationID: operation, workerAgentID: worker, sessionID: "session", generation: "generation")
        let identity = ProjectResultIdentity(ownerID: project.ownerID, projectID: project.id, eventID: operation, source: source, host: .local, deliveryID: operation, observedProjectRevision: 7)
        project.resultPage = .init(identity: identity, availability: .complete, totalBytes: 4, sha256: "digest", data: Data("done".utf8), stopReason: "stop")
        return project
    }()
    private static let ownerWithFailure: Project = {
        var project = Wire.project(named: "Project")
        var message = ProjectMessage(id: operation, text: "hello", phase: .failed)
        message.failureDetail = "The agent refused it: No API key found for test-provider."
        project.messages = [message]
        return project
    }()
    private static let resultReply = RemoteReply.logicalProjectRuntime(id: 7, result: .project(ownerWithResult))
    private static let failureReply = RemoteReply.logicalProjectRuntime(id: 1, result: .project(ownerWithFailure))
    static let wireReplies = [resultReply, failureReply]

    @Test(arguments: [ProjectRuntimeRequest.conversation, .read,
                      .worker(taskID: task), .inspect(taskID: task), .inspect(taskID: task, operationID: operation),
                      .history(), .history(taskID: task, beforeSequence: 42, includeBodies: true),
                      .result(taskID: task, operationID: operation, offset: 8190, sha256: "exact-content-digest"),
                      .answer(operationID: operation, taskID: task, questionEventID: operation, humanReplyID: operation, answer: .select(value: "Allow")),
                      .answer(operationID: operation, taskID: task, questionEventID: operation, humanReplyID: operation, answer: .confirm(value: true)),
                      .answer(operationID: operation, taskID: task, questionEventID: operation, humanReplyID: operation, answer: .input(value: "")),
                      .answer(operationID: operation, taskID: task, questionEventID: operation, humanReplyID: operation, answer: .editor(value: "Edited")),
                      .proposeSpace(operationID: operation, path: "/scratch/source", spaceID: nil, originTaskID: task),
                      .decideSpace(proposalID: operation, expectedProposalRevision: 1, accept: true),
                      .remember(operationID: operation, text: "Fact", taskID: task),
                      .message(operationID: operation, text: "hello"),
                      .message(operationID: operation, text: "", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]),
                      .assign(operationID: operation, spaceID: space, title: "Task", prompt: "Assigned"),
                      .followUp(taskID: task, operationID: operation, text: "Follow up"),
                      .resolve(taskID: task), .reopen(taskID: task), .pause, .resume,
                      .recordOutcome(operationID: operation, taskID: task, taskOperationID: operation, kind: .needsChanges),
                      .recordOutcome(operationID: operation, taskID: task, taskOperationID: operation, kind: .merged, evidence: "PR #12")])
    func everyLocalActionRoundTrips(_ request: ProjectRuntimeRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test func modelToolAndRemoteOwnerShapesRoundTrip() throws {
        let id = ProjectID(), agent = AgentID()
        let frame = "{\"type\":\"projectRuntime\",\"id\":1,\"agentID\":\"\(agent)\",\"projectID\":\"\(id)\",\"expectedRevision\":2,\"request\":{\"assign\":{\"operationID\":\"\(Self.operation)\",\"spaceID\":\"\(Self.space)\",\"title\":\"Task\",\"prompt\":\"Do it\"}}}"
        let message = try NDJSON.decode(ExtensionMessage.self, from: Data(frame.utf8))
        #expect(message.speaksFor == agent && message.replyID == 1)
        #expect(try Wire.roundTrip(message) == message)
        for request in Self.ownerRequests { #expect(try Wire.roundTrip(request) == request) }
        let result = ProjectRuntimeResult.hosts([.init(reference: .remote(hostID: Self.operation, bindingID: UUID()), name: "demo-mac")])
        #expect(try Wire.roundTrip(result) == result)
        var project = Project(name: "Project")
        #expect(project.settings.allowedHosts == [.local] && project.settings.hostPolicy == .selected)
        project.spaceProposals = [.init(id: Self.operation, operationID: Self.operation, path: "/source", displayPath: "/source", phase: .denied)]
        #expect(try Wire.roundTrip(project) == project)
    }

    @Test func oldInspectShapeAndNewResultDescriptorRoundTrip() throws {
        let old = Data("{\"inspect\":{\"taskID\":\"\(Self.task)\"}}".utf8)
        #expect(try JSONDecoder().decode(ProjectRuntimeRequest.self, from: old) == .inspect(taskID: Self.task))
        let project = Self.ownerWithResult
        #expect(try Wire.roundTrip(Self.resultReply) == Self.resultReply)
        let extensionFrame = ExtensionMessage.projectRuntime(id: 8, agentID: Self.worker, projectID: project.id, expectedRevision: 7, request: .result(taskID: Self.task, operationID: Self.operation, offset: 0, sha256: nil))
        let decoded = try Wire.roundTrip(extensionFrame)
        #expect(extensionFrame.replyID == 8 && extensionFrame.speaksFor == Self.worker && decoded == extensionFrame)
    }

    @Test func olderMessageWireAndStoredMessageDefaultImagesToNil() throws {
        let old = Data("{\"message\":{\"operationID\":\"\(Self.operation)\",\"text\":\"hello\"}}".utf8)
        #expect(try JSONDecoder().decode(ProjectRuntimeRequest.self, from: old) == .message(operationID: Self.operation, text: "hello"))
        let stored = Data("{\"id\":\"\(Self.operation)\",\"text\":\"hello\",\"phase\":\"queued\"}".utf8)
        let legacy = try JSONDecoder().decode(ProjectMessage.self, from: stored)
        #expect(legacy.images == nil && legacy.humanSubmitted == nil && legacy.answerReceipts == nil && legacy.failureDetail == nil)
        var human = legacy
        human.humanSubmitted = true
        human.answerReceipts = [.init(taskID: Self.task, questionEventID: Self.operation,
            nativeAnswer: .init(operationID: Self.operation, sessionID: "s", generation: "g", dialogID: "q", request: Data([1]))) ]
        #expect(try Wire.roundTrip(human) == human)
        let frame = ExtensionMessage.projectRuntime(id: 8, agentID: AgentID(), projectID: ProjectID(), expectedRevision: 2, request: Self.answer)
        #expect(try Wire.roundTrip(frame) == frame && frame.replyID == 8 && frame.speaksFor != nil)
        #expect(try Wire.roundTrip(Self.answerRequest) == Self.answerRequest)
        let ref = ProjectInputImage(id: Self.operation, mimeType: "image/png", name: "tiny.png", byteCount: 68)
        let message = ProjectMessage(id: Self.operation, text: "", images: [ref])
        #expect(try Wire.roundTrip(message) == message)
        #expect(try Wire.roundTrip(Self.imageRequest) == Self.imageRequest)
    }

    @Test func failedMessageDetailSurvivesStateAndOwnerReplyRoundTrips() throws {
        let project = Self.ownerWithFailure
        #expect(try Wire.roundTrip(ShepherdState(projects: [project])).projects.first?.messages == project.messages)
        #expect(try Wire.roundTrip(Self.failureReply) == Self.failureReply)
    }

    @Test func chatAnswerReceiptsAreBoundedAndLegacyQuestionEventsHaveNoGenerationProof() throws {
        var project = Project(name: "Project")
        var human = ProjectMessage(id: Self.operation, text: "Allow it")
        human.humanSubmitted = true
        let receipts = (1...65).map { index in
            ProjectChatAnswerReceipt(taskID: Self.task, questionEventID: Self.operation,
                nativeAnswer: .init(operationID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                                    sessionID: "s", generation: "g", dialogID: "q", request: Data()))
        }
        human.answerReceipts = Array(receipts.prefix(64)); project.messages = [human]
        try project.validate()
        project.messages[0].answerReceipts = receipts
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.messages[0].answerReceipts = Array(receipts.prefix(1))
        project.messages[0].humanSubmitted = nil
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        let legacy = ProjectEventSource(kind: .question, taskID: Self.task, operationID: Self.operation,
                                        workerAgentID: AgentID(), sessionID: "s", dialogID: "q")
        #expect(try Wire.roundTrip(legacy).generation == nil)
    }

    @Test func projectRuntimeRecordsRoundTripWithoutChangingOrdinaryAgents() throws {
        var project = Project(name: "Project")
        let space = Space(name: "Projects", path: "~", hidden: true, holdsProjects: true)
        let agentID = AgentID()
        let pane = LeafPane(cwd: "/scratch/project", agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "Project", spaceID: space.id, tabID: tab.id, paneID: pane.id, coordinatorFor: project.id)
        project.coordinatorAgentID = agentID
        project.tasks = [.init(id: Self.task, operationID: Self.operation, spaceID: Self.space, title: "Assigned", prompt: "Do this", phase: .unknown)]
        project.messages = [.init(id: Self.operation, text: "Original", phase: .unknown)]
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent], projects: [project])
        try state.validate()
        #expect(try Wire.roundTrip(state) == state)
        #expect(!space.holdsAutomations)
        #expect(state.isProjectCoordinator(agent))
        #expect(!state.isOrdinaryThread(agent))
        #expect(state.withoutProjectCoordinators.agents.isEmpty)
        #expect(state.withoutProjectCoordinators.projects == [project])
    }
}
