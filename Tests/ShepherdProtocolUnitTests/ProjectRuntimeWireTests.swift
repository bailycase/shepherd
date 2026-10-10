import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project local runtime contracts")
struct ProjectRuntimeWireTests {
    static let task = ProjectTaskID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    static let space = SpaceID(rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    static let operation = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    @Test(arguments: [ProjectRuntimeRequest.conversation, .read,
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
                      .resolve(taskID: task), .reopen(taskID: task), .pause, .resume])
    func everyLocalActionRoundTrips(_ request: ProjectRuntimeRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }

    @Test func modelToolAndRemoteOwnerShapesRoundTrip() throws {
        let id = ProjectID(), agent = AgentID()
        let frame = "{\"type\":\"projectRuntime\",\"id\":1,\"agentID\":\"\(agent)\",\"projectID\":\"\(id)\",\"expectedRevision\":2,\"request\":{\"assign\":{\"operationID\":\"\(Self.operation)\",\"spaceID\":\"\(Self.space)\",\"title\":\"Task\",\"prompt\":\"Do it\"}}}"
        let message = try NDJSON.decode(ExtensionMessage.self, from: Data(frame.utf8))
        #expect(message.speaksFor == agent && message.replyID == 1)
        #expect(try Wire.roundTrip(message) == message)
        let requests: [ProjectRuntimeTransport] = [.hosts, .action(projectID: id, expectedRevision: 2, request: .read),
            .conversation(projectID: id, request: .snapshot()), .worker(projectID: id, taskID: Self.task, request: .snapshot()),
            .answer(projectID: id, expectedRevision: 2, taskID: Self.task,
                request: .answer(expectedSessionID: "s", generation: "g", operationID: Self.operation, dialogID: "q", answer: .confirm(value: true)))]
        for request in requests { #expect(try Wire.roundTrip(RemoteRequest.logicalProjectRuntime(id: 1, request: request)) == .logicalProjectRuntime(id: 1, request: request)) }
        let result = ProjectRuntimeResult.hosts([.init(reference: .remote(hostID: Self.operation, bindingID: UUID()), name: "build-01")])
        #expect(try Wire.roundTrip(result) == result)
        var project = Project(name: "Project")
        #expect(project.settings.allowedHosts == [.local] && project.settings.hostPolicy == .selected)
        project.spaceProposals = [.init(id: Self.operation, operationID: Self.operation, path: "/source", displayPath: "/source", phase: .denied)]
        #expect(try Wire.roundTrip(project) == project)
    }

    @Test func olderMessageWireAndStoredMessageDefaultImagesToNil() throws {
        let old = Data("{\"message\":{\"operationID\":\"\(Self.operation)\",\"text\":\"hello\"}}".utf8)
        #expect(try JSONDecoder().decode(ProjectRuntimeRequest.self, from: old) == .message(operationID: Self.operation, text: "hello"))
        let stored = Data("{\"id\":\"\(Self.operation)\",\"text\":\"hello\",\"phase\":\"queued\"}".utf8)
        let legacy = try JSONDecoder().decode(ProjectMessage.self, from: stored)
        #expect(legacy.images == nil && legacy.humanSubmitted == nil && legacy.answerReceipts == nil)
        var human = legacy
        human.humanSubmitted = true
        human.answerReceipts = [.init(taskID: Self.task, questionEventID: Self.operation,
            nativeAnswer: .init(operationID: Self.operation, sessionID: "s", generation: "g", dialogID: "q", request: Data([1]))) ]
        #expect(try Wire.roundTrip(human) == human)
        let answer = ProjectRuntimeRequest.answer(operationID: Self.operation, taskID: Self.task,
            questionEventID: Self.operation, humanReplyID: Self.operation, answer: .confirm(value: false))
        let frame = ExtensionMessage.projectRuntime(id: 8, agentID: AgentID(), projectID: ProjectID(), expectedRevision: 2, request: answer)
        #expect(try Wire.roundTrip(frame) == frame && frame.replyID == 8 && frame.speaksFor != nil)
        let remote = RemoteRequest.logicalProjectRuntime(id: 9, request: .action(projectID: ProjectID(), expectedRevision: 2, request: answer))
        #expect(try Wire.roundTrip(remote) == remote)
        let ref = ProjectInputImage(id: Self.operation, mimeType: "image/png", name: "tiny.png", byteCount: 68)
        let message = ProjectMessage(id: Self.operation, text: "", images: [ref])
        #expect(try Wire.roundTrip(message) == message)
        let request = RemoteRequest.logicalProjectRuntime(id: 7, request: .action(projectID: ProjectID(), expectedRevision: 1,
            request: .message(operationID: Self.operation, text: "", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])))
        #expect(try Wire.roundTrip(request) == request)
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
