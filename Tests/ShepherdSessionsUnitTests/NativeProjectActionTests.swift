import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

@Suite("Project action receipt projection")
struct NativeProjectActionProjectionTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let task = "22222222-2222-4222-8222-222222222222"
    static let operation = "33333333-3333-4333-8333-333333333333"
    static let proposal = "44444444-4444-4444-8444-444444444444"

    private func message(_ name: String = "project_assign", details: [String: Any]? = nil, receipt: [String: Any]? = nil, isError: Bool = false) throws -> RPCMessage {
        let fields: [String: Any] = details ?? ["projectID": Self.project, "revision": 7, "operationID": Self.operation, "taskID": Self.task, "secret": "not native metadata"]
        let project: [String: Any] = receipt ?? ["id": Self.project, "revision": 7, "tasks": [["id": Self.task, "operationID": Self.operation]]]
        let payload: [String: Any] = ["role": "toolResult", "toolName": name, "toolCallId": "call", "isError": isError,
                                      "content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: project), as: UTF8.self)]], "details": fields]
        return try JSONDecoder().decode(RPCMessage.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func historyDecoderRetainsOnlyAllowlistedMetadataAndProjectionChecksTheReceipt() throws {
        let raw = try message()
        #expect(raw.details?["secret"] == nil)
        let row = RPCThreadState.project(entryID: "t:call", message: raw)
        #expect(row.projectAction == NativeProjectAction(projectID: .init(rawValue: Self.project), revision: 7,
                                                        operationID: UUID(uuidString: Self.operation)!, taskID: .init(rawValue: Self.task)))
        if case .text(let text) = raw.content.first { #expect(row.blocks.first?.text == text) }
        else { Issue.record("Missing receipt text") }
    }

    @Test(arguments: ["bash", "project_read", "project_inspect", "project_remember", "foreign_project_assign"])
    func ordinaryAndUnknownToolsNeverAcquireProjectIdentity(_ name: String) throws {
        let raw = try message(name)
        #expect(raw.details == nil)
        #expect(RPCThreadState.project(entryID: "tool", message: raw).projectAction == nil)
        #expect(!RPCThreadState.project(entryID: "tool", message: raw).blocks.isEmpty)
    }

    @Test func malformedMissingErrorAndInconsistentReceiptsFailClosed() throws {
        for fields: [String: Any] in [[:], ["projectID": Self.project],
            ["projectID": "../escape", "revision": 7, "operationID": Self.operation, "taskID": Self.task],
            ["projectID": Self.project, "revision": -1, "operationID": Self.operation, "taskID": Self.task],
            ["projectID": Self.project, "revision": 7, "operationID": "invalid", "taskID": Self.task],
            ["projectID": Self.project, "revision": 7, "operationID": Self.operation, "taskID": Self.task, "proposalID": Self.proposal]] {
            #expect(RPCThreadState.project(entryID: "tool", message: try message(details: fields)).projectAction == nil)
        }
        for receipt: [String: Any] in [[:], ["id": Self.project, "revision": 8],
            ["id": Self.project, "revision": 7, "tasks": [["id": Self.task, "operationID": Self.proposal]]],
            ["id": Self.project, "revision": 7, "tasks": [["id": Self.task, "operationID": Self.operation], ["id": Self.task, "operationID": Self.operation]]]] {
            #expect(RPCThreadState.project(entryID: "tool", message: try message(receipt: receipt)).projectAction == nil)
        }
        #expect(RPCThreadState.project(entryID: "tool", message: try message(isError: true)).projectAction == nil)
        var raw = try message()
        raw.content = [.text("not a Project JSON receipt")]
        let edited = try JSONDecoder().decode(RPCMessage.self, from: JSONEncoder().encode(raw))
        #expect(RPCThreadState.project(entryID: "tool", message: edited).projectAction == nil)
    }

    @Test func followUpResolveAndProposalUseOperationReceiptsRatherThanTitle() throws {
        for (tool, operationField) in [("project_follow_up", "previousOperations"), ("project_resolve", "resolutionOperations")] {
            let raw = try message(tool, receipt: ["id": Self.project, "revision": 7,
                                                  "tasks": [["id": Self.task, "operationID": Self.proposal, operationField: [Self.operation]]]])
            #expect(RPCThreadState.project(entryID: "tool", message: raw).projectAction?.taskID?.rawValue == Self.task)
        }
        let raw = try message("project_propose_space", details: ["projectID": Self.project, "revision": 7, "operationID": Self.operation, "proposalID": Self.proposal],
                              receipt: ["id": Self.project, "revision": 7, "spaceProposals": [["id": Self.proposal, "operationID": Self.operation]]])
        #expect(RPCThreadState.project(entryID: "tool", message: raw).projectAction?.proposalID == UUID(uuidString: Self.proposal))
    }
}
