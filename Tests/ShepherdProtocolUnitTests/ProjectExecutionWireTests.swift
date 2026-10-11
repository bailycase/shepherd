import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project executor wire contracts")
struct ProjectExecutionWireTests {
    static let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
    static let assignment = ProjectExecutionAssignment(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(),
                                                       executorSpaceID: SpaceID(), title: "Task", prompt: "Do assigned work")
    @Test(arguments: [ProjectExecutionRequest.execute(assignment), .snapshot(key: key, watch: true),
                      .snapshot(key: key, watch: false), .cancel(key: key), .pause(key: key), .resume(key: key),
                      .answer(key: key, request: .answer(expectedSessionID: "session", generation: "generation", operationID: UUID(), dialogID: "dialog", answer: .confirm(value: true)))])
    func everyExecutionActionRoundTrips(_ command: ProjectExecutionRequest) throws {
        let request = RemoteRequest.projectExecution(id: 42, request: command)
        #expect(try Wire.roundTrip(request) == request)
    }
    @Test func receiptAndChangeHintRoundTripAndOldWorkspaceDefaultsEmpty() throws {
        let receipt = ProjectExecutionReceipt(key: Self.key, assignment: Self.assignment, phase: .sendReserved)
        let reply = RemoteReply.projectExecution(id: 43, result: .init(receipt: receipt))
        #expect(try Wire.roundTrip(reply) == reply)
        let push = RemoteReply.projectExecutionChanged(key: Self.key, revision: 3)
        #expect(try Wire.roundTrip(push) == push)
        let state = try JSONDecoder().decode(ShepherdState.self, from: Data(#"{"spaces":[],"tabs":[],"agents":[]}"#.utf8))
        #expect(state.projectExecutions.isEmpty)
        let saved = ShepherdState(projectExecutions: [receipt])
        try saved.validate()
        #expect(try Wire.roundTrip(saved) == saved)
        #expect(saved.withoutProjectExecutions.projectExecutions.isEmpty)
    }
    @Test func manualTakeoverProofRoundTripsButOlderExecutorsSupplyNoProof() throws {
        let receipt = ProjectExecutionReceipt(key: Self.key, assignment: Self.assignment, phase: .unknown)
        let proven = ProjectExecutionResult(receipt: receipt, workerTakenOver: true)
        #expect(try Wire.roundTrip(RemoteReply.projectExecution(id: 7, result: proven))
            == .projectExecution(id: 7, result: proven))
        let old = try JSONDecoder().decode(ProjectExecutionResult.self, from: JSONEncoder().encode(ProjectExecutionResult(receipt: receipt)))
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
