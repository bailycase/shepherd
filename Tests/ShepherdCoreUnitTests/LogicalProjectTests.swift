import Foundation
import Testing
@testable import ShepherdCore

@Suite("Logical project records")
struct LogicalProjectTests {
    static let id = ProjectID(rawValue: "11111111-1111-4111-8111-111111111111")

    @Test func oldWorkspacesDecodeWithoutLogicalProjects() throws {
        let old = Data(#"{"spaces":[],"tabs":[],"agents":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ShepherdState.self, from: old).projects.isEmpty)
        let minimal = Data("{\"id\":\"\(Self.id)\",\"name\":\"Release\"}".utf8)
        let project = try JSONDecoder().decode(Project.self, from: minimal)
        #expect(project.settings.maxConcurrentWorkers == 3)
        #expect(project.settings.canRequestSpaceLinks)
        #expect(!Project(name: "New").paused)
        #expect(project.paused)
        #expect(project.coordinatorAgentID == nil)
        #expect(project.ownerID == UUID(uuidString: Self.id.rawValue))
        let link = try JSONDecoder().decode(ProjectSpaceLink.self, from: Data("{\"spaceID\":\"\(Self.id)\",\"provenance\":\"user\",\"linkedAt\":1}".utf8))
        #expect(link.destination == .local)
        #expect(try JSONDecoder().decode(LogicalProjectSettings.self, from: Data("{}".utf8)).maxConcurrentWorkers == 3)
    }

    @Test func projectsRoundTripWithSettingsMemoryAndOwnerRelativeProvenance() throws {
        let project = Project(id: Self.id, name: "Release", goal: "Ship the assigned change",
                              settings: .init(maxConcurrentWorkers: 6, conversationModel: "provider/a", threadModel: "provider/b", instructions: "Keep tests"),
                              memory: [.init(text: "Use staging", source: "user", createdAt: 123)],
                              linkedSpaces: [.init(spaceID: SpaceID(), linkedAt: 456)])
        let state = ShepherdState(projects: [project])
        try state.validate()
        #expect(try JSONDecoder().decode(ShepherdState.self, from: JSONEncoder().encode(state)) == state)
        #expect(throws: ShepherdStateValidationError.self) { try ShepherdState(projects: [project, project]).validate() }
    }

    /// The coordinator's reasoning level round-trips, decodes as nil from an older owner's record, and must be a known level.
    @Test func theConversationReasoningLevelRoundTripsDefaultsToNoneAndMustBeAKnownLevel() throws {
        var project = Project(id: Self.id, name: "Release", settings: .init(conversationModel: "provider/a", conversationThinking: "xhigh"))
        try project.validate()
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).settings.conversationThinking == "xhigh")
        #expect(try JSONDecoder().decode(LogicalProjectSettings.self, from: Data(#"{"conversationModel":"provider/a"}"#.utf8)).conversationThinking == nil)
        project.settings.conversationThinking = "turbo"
        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test(arguments: ["../outside", "", "/tmp/escape", "11111111-1111-4111-8111-11111111111Z", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
    func invalidProjectIDsAreRejectedBeforeTheyCanNameFiles(_ value: String) {
        #expect(throws: ProjectValidationError.self) { try Project(id: .init(rawValue: value), name: "Project").validate() }
    }

    @Test func limitsRejectRatherThanTruncateAndInstructionsUseCharacters() throws {
        var project = Project(id: Self.id, name: "Project")
        project.settings.instructions = String(repeating: "🦊", count: 16_000)
        try project.validate()
        project.settings.instructions += "x"
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.settings.instructions = ""
        for workers in [0, 7] {
            project.settings.maxConcurrentWorkers = workers
            #expect(throws: ProjectValidationError.self) { try project.validate() }
        }
        project.settings.maxConcurrentWorkers = 3
        project.name = " \n"
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.name = String(repeating: "a", count: 201)
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.name = "Project"
        project.goal = String(repeating: "a", count: 4_001)
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.goal = ""
        project.memory = Array(repeating: ProjectMemory(text: "Fact", source: "user", createdAt: 1), count: 2)
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.memory = [.init(text: String(repeating: "a", count: 4_001), source: "user", createdAt: 1)]
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.memory = (0..<65).map { ProjectMemory(text: "\($0)", source: "user", createdAt: 1) }
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.memory = []
        project.linkedSpaces = (0..<33).map { _ in ProjectSpaceLink(spaceID: SpaceID(), linkedAt: 1) }
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        project.linkedSpaces = Array(repeating: .init(spaceID: SpaceID(), linkedAt: 1), count: 2)
        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func placementIdentityIsHostRelativeAndAssignmentsCannotChangeTheirTask() throws {
        let space = SpaceID(), host = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        var project = Project(name: "Routing", linkedSpaces: [.init(spaceID: space, linkedAt: 1), .init(spaceID: space, linkedAt: 1, host: host)])
        try project.validate()
        #expect(project.linkedSpaces[0].id != project.linkedSpaces[1].id)
        var task = ProjectTask(operationID: UUID(), spaceID: space, title: "Work", prompt: "Assigned", host: host)
        task.executionAssignment = .init(key: .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID),
                                        taskID: task.id, reservedWorkerID: task.workerAgentID, executorSpaceID: space, title: task.title, prompt: task.prompt)
        project.tasks = [task]
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
        try project.validate()
        project.tasks[0].executionAssignment?.reservedWorkerID = AgentID()
        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func aggregateCollectionAndRecordCountsAreBounded() throws {
        let projects = (0..<33).map { Project(name: "Project \($0)") }
        #expect(throws: ProjectValidationError.self) { try ShepherdState(projects: projects).validate() }
        let heavy = (0..<12).map { Project(name: "Project \($0)", settings: .init(instructions: String(repeating: "🦊", count: 16_000))) }
        #expect(throws: ProjectValidationError.self) { try ShepherdState(projects: heavy).validate() }
    }
    /// A long conversation used to hit the 64-message ceiling and refuse every later save ("Project message queue is full").
    @Test func aLongConversationRetiresFinishedMessagesAndKeepsWhatIsStillLive() throws {
        var project = Project(id: Self.id, name: "Release")
        let worker = AgentID(), waitingOp = UUID()
        project.tasks = [ProjectTask(operationID: waitingOp, workerAgentID: worker, spaceID: SpaceID(), title: "Ask", prompt: "p", phase: .waiting)]
        let question = ProjectMessage(id: UUID(), text: "q", phase: .delivered,
                                      source: .init(kind: .question, taskID: project.tasks[0].id, operationID: waitingOp, workerAgentID: worker, sessionID: "s"))
        let wake = ProjectMessage(id: UUID(), text: "w", phase: .delivered,
                                  source: .init(kind: .settled, taskID: project.tasks[0].id, operationID: UUID(), workerAgentID: worker, sessionID: "s"))
        let queued = ProjectMessage(id: UUID(), text: "held")
        project.messages = [question, wake, queued] + (0..<200).map { ProjectMessage(id: UUID(), text: "m\($0)", phase: .delivered) }
        project.retireFinishedMessages()
        #expect(project.messages.count == Project.retainedMessages)
        #expect(project.messages.contains(question), "a question its task still waits on stays")
        #expect(project.messages.contains(queued), "a message not yet sent stays")
        #expect(!project.messages.contains(wake) && project.retiredWakeups == [wake.id], "a retired wake-up stays hidden")
        #expect(project.messages.suffix(8).map(\.text) == (192..<200).map { "m\($0)" }, "the newest stay")
        try ShepherdState(projects: [project]).validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.retiredWakeups == [wake.id])
    }
}
