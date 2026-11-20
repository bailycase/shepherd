import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project executor wire contracts")
struct ProjectExecutionWireTests {
    // The state validation tests require canonical UUIDs for all four assignment IDs.
    static let key = ProjectExecutionKey(ownerID: Wire.projectKey.ownerID,
                                         projectID: ProjectID(rawValue: "00000000-0000-0000-0000-000000000003"),
                                         operationID: Wire.projectKey.operationID)
    static let assignment = ProjectExecutionAssignment(key: key, taskID: ProjectTaskID(rawValue: "00000000-0000-0000-0000-000000000004"),
                                                       reservedWorkerID: AgentID(rawValue: "00000000-0000-0000-0000-000000000005"),
                                                       executorSpaceID: SpaceID(rawValue: "00000000-0000-0000-0000-000000000006"),
                                                       title: "Task", prompt: "Do assigned work")
    private static let commands: [ProjectExecutionRequest] = [
        .execute(assignment), .snapshot(key: key, watch: true),
        .worker(key: key), .result(key: key, offset: 8190, sha256: "exact-content-digest"),
        .snapshot(key: key, watch: false), .cancel(key: key), .pause(key: key), .resume(key: key),
        .answer(key: key, request: .answer(expectedSessionID: "session", generation: "generation", operationID: key.operationID, dialogID: "dialog", answer: .confirm(value: true))),
    ]
    static let wireRequests = commands.map { RemoteRequest.projectExecution(id: 42, request: $0) }

    private static let admittedAt = 1_790_000_000.0
    private static let reserved = ProjectExecutionReceipt(key: key, assignment: assignment, phase: .sendReserved, admittedAt: admittedAt)
    private static let settled = ProjectExecutionReceipt(key: key, assignment: assignment, phase: .settled, admittedAt: admittedAt)
    private static let unknown = ProjectExecutionReceipt(key: key, assignment: assignment, phase: .unknown, admittedAt: admittedAt)
    private static let receiptReply = RemoteReply.projectExecution(id: 43, result: .init(receipt: reserved))
    private static let change = RemoteReply.projectExecutionChanged(key: key, revision: 3)
    private static let pageReply = RemoteReply.projectExecution(id: 44, result: .init(
        receipt: settled, resultPage: .init(availability: .unavailable, reason: "legacy capture has no exact complete result")))
    private static let proofReply = RemoteReply.projectExecution(id: 7, result: .init(receipt: unknown, workerTakenOver: true))
    static let wireReplies = [receiptReply, change, pageReply, proofReply]

    @Test(arguments: wireRequests)
    func everyExecutionActionRoundTrips(_ request: RemoteRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
    }
    @Test func receiptAndChangeHintRoundTripAndOldWorkspaceDefaultsEmpty() throws {
        #expect(try Wire.roundTrip(Self.receiptReply) == Self.receiptReply)
        #expect(try Wire.roundTrip(Self.change) == Self.change)
        let state = try JSONDecoder().decode(ShepherdState.self, from: Data(#"{"spaces":[],"tabs":[],"agents":[]}"#.utf8))
        #expect(state.projectExecutions.isEmpty)
        let saved = ShepherdState(projectExecutions: [Self.reserved])
        try saved.validate()
        #expect(try Wire.roundTrip(saved) == saved)
        #expect(saved.withoutProjectExecutions.projectExecutions.isEmpty)
    }
    @Test func completeResultPagingIsExplicitAndOldPeersHaveNoResultPage() throws {
        #expect(try Wire.roundTrip(Self.pageReply) == Self.pageReply)
        let legacy = try JSONDecoder().decode(ProjectExecutionResult.self, from: JSONEncoder().encode(ProjectExecutionResult(receipt: Self.settled)))
        #expect(legacy.resultPage == nil && RemoteProtocol.capabilities.contains(RemoteProtocol.projectResultCapability))
    }

    @Test func manualTakeoverProofRoundTripsButOlderExecutorsSupplyNoProof() throws {
        #expect(try Wire.roundTrip(Self.proofReply) == Self.proofReply)
        let old = try JSONDecoder().decode(ProjectExecutionResult.self, from: JSONEncoder().encode(ProjectExecutionResult(receipt: Self.unknown)))
        #expect(old.workerTakenOver == nil)
    }

    @Test func followupProofRoundTripsAndOldReceiptsNeedNoNewField() throws {
        var first = ProjectExecutionReceipt(key: Self.key, assignment: Self.assignment, phase: .settled)
        first.sessionID = "session"; first.matchedUserEntryID = "user:1"
        var assignment = Self.assignment; assignment.key.operationID = UUID()
        var next = ProjectExecutionReceipt(key: assignment.key, assignment: assignment, phase: .reserved)
        next.previousOperationID = first.key.operationID
        let state = ShepherdState(projectExecutions: [first, next])
        try state.validate()
        #expect(try Wire.roundTrip(state) == state)
        let old = try JSONDecoder().decode(ProjectExecutionReceipt.self, from: JSONEncoder().encode(first))
        #expect(old.previousOperationID == nil)
        #expect(old.ownerPaused == nil && old.pendingAnswer == nil)
        #expect(throws: ProjectValidationError.self) { try ShepherdState(projectExecutions: [next]).validate() }
    }

    @Test func capacityReservesEvidenceAndNeverEvictsOldIdentities() throws {
        let receipts = (0..<8).map { _ -> ProjectExecutionReceipt in
            var assignment = Self.assignment
            assignment.key.operationID = UUID()
            assignment.reservedWorkerID = AgentID()
            return .init(key: assignment.key, assignment: assignment, phase: .reserved)
        }
        #expect(throws: ProjectValidationError.self) { try ShepherdState(projectExecutions: receipts).validate() }
        let settled = receipts.map { receipt in var result = receipt; result.phase = .settled; return result }
        try ShepherdState(projectExecutions: settled).validate()
        #expect(settled.map(\.key) == receipts.map(\.key))
    }

    @Test(arguments: ["", " \n ", String(repeating: "🦊", count: 4097)])
    func invalidPromptsAreRejectedBeforeAdmission(_ prompt: String) {
        var assignment = Self.assignment
        assignment.prompt = prompt
        #expect(throws: ProjectValidationError.self) { try assignment.validate() }
    }
}
