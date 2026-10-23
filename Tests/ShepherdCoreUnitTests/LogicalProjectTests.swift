import Foundation
import Testing
@testable import ShepherdCore

@Suite("Logical project records")
struct LogicalProjectTests {
    static let id = ProjectID(rawValue: "11111111-1111-4111-8111-111111111111")

    @Test func archivedWorkerOwnershipSurvivesCodingWithoutBecomingDispatchAuthority() throws {
        var worker = Agent(name: "Retained worker", spaceID: SpaceID(), tabID: TabID())
        worker.projectWorkerFor = Self.id
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(worker))
        #expect(decoded.projectWorkerFor == Self.id && decoded.executionFor == nil)
        var state = ShepherdState(); state.agents = [decoded]; state.projects = [Project(id: Self.id, name: "Owning Project")]
        #expect(state.isProjectWorker(decoded.id) && !state.isSidebarThread(decoded))
        #expect(state.projectContext(for: decoded.id) == nil, "The marker preserves presentation, not a replayable activation or tool authority.")
    }

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
        #expect(project.messages.count == 203, "Working history cannot be retired without durable archive confirmation.")
        project.retireFinishedMessages(archived: Set(project.messages.map(\.id)))
        #expect(project.messages.count == Project.retainedMessages)
        #expect(project.messages.contains(question), "a question its task still waits on stays")
        #expect(project.messages.contains(queued), "a message not yet sent stays")
        #expect(!project.messages.contains(wake) && project.retiredWakeups == [wake.id], "a retired wake-up stays hidden")
        #expect(project.messages.suffix(8).map(\.text) == (192..<200).map { "m\($0)" }, "the newest stay")
        try ShepherdState(projects: [project]).validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.retiredWakeups == [wake.id])
    }

    /// A Project is a long-lived multi-task workspace: no goal, milestone or project-wide done is required to create, validate or
    /// work in one, and a legacy task decodes with an unknown outcome, never an inferred success.
    @Test func aGoallessProjectValidatesAndLegacyTasksKeepAnUnknownOutcome() throws {
        var project = Project(id: Self.id, name: "Workspace")
        #expect(project.goal.isEmpty)
        project.tasks = [.init(operationID: UUID(), spaceID: SpaceID(), title: "Investigate", prompt: "look", phase: .resolved)]
        try project.validate()
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(project.tasks[0])) as? [String: Any])
        json["outcomes"] = nil
        let legacy = try JSONDecoder().decode(ProjectTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.outcomes == nil && legacy.currentOutcome == nil && legacy.phase == .resolved)
    }

    @Test func outcomesAreBoundedAndDeliveryFactsNeedEvidence() throws {
        var project = Project(id: Self.id, name: "Workspace")
        var task = ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "Ship", prompt: "p", phase: .settled)
        func outcome(_ kind: ProjectTaskOutcome.Kind, _ evidence: String? = nil) -> ProjectTaskOutcome {
            .init(id: UUID(), operationID: task.operationID, kind: kind, evidence: evidence, recordedBy: AgentID(), recordedAt: 1)
        }
        task.outcomes = [outcome(.accepted), outcome(.needsChanges), outcome(.merged, "PR #1"), outcome(.uploaded, "build 329"), outcome(.available, "group A")]
        project.tasks = [task]
        try project.validate()
        #expect(project.tasks[0].currentOutcome?.kind == .available, "the newest fact for this activation")
        for bad in [outcome(.merged), outcome(.uploaded, "  "), outcome(.available, String(repeating: "x", count: 257))] {
            project.tasks[0].outcomes = [bad]
            #expect(throws: ProjectValidationError.self) { try project.validate() }
        }
        project.tasks[0].outcomes = (0...ProjectTaskOutcome.maximumPerTask).map { _ in outcome(.accepted) }
        #expect(throws: ProjectValidationError.self) { try project.validate() }
        let decoded = try JSONDecoder().decode(ProjectTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.outcomes == task.outcomes)
    }

    /// The brief carries only the newest remembered facts that fit; older ones stay stored. Each kept fact is whole.
    @Test func briefMemoryKeepsTheNewestWholeFactsWithinItsBudget() {
        let facts = (0..<40).map { "fact \($0) " + String(repeating: "x", count: 400) }
        let brief = Project.briefMemory(facts)
        #expect(brief.joined(separator: "\n").utf8.count <= Project.briefMemoryBytes)
        #expect(brief.last == facts.last && brief.count < facts.count && brief.allSatisfy(facts.contains))
        #expect(brief == Array(facts.suffix(brief.count)))
        #expect(Project.briefMemory(["a", "b"]) == ["a", "b"])
        #expect(Project.briefMemory([String(repeating: "y", count: Project.briefMemoryBytes + 1)]).isEmpty)
        #expect(Project.briefMemory([]).isEmpty)
    }
}
