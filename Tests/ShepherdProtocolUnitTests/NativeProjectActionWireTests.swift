import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Native Project action wire")
struct NativeProjectActionWireTests {
    @Test func actionIsAnOptionalTypedProjectionNotOpaqueToolDetails() throws {
        let id = ProjectID(rawValue: "11111111-1111-4111-8111-111111111111")
        let operation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let task = ProjectTaskID(rawValue: "33333333-3333-4333-8333-333333333333")
        for action in [NativeProjectAction(projectID: id, revision: 9, operationID: operation, taskID: task),
                       NativeProjectAction(projectID: id, revision: 9, operationID: operation, proposalID: operation)] {
            let row = NativeThreadMessage(entryID: "tool", role: "toolResult", blocks: [], projectAction: action)
            #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: JSONEncoder().encode(row)) == row)
            let wire = RemoteReply.nativeThread(id: 7, result: .snapshot(value: .init(piSessionID: "s", generation: "g", revision: 1,
                running: false, supportedActions: [], dialogsSupported: true, dialogs: [], messages: [row], provisional: [], clipped: false)))
            #expect(try Wire.roundTrip(wire) == wire)
        }
        let old = Data(#"{"entryID":"tool","role":"toolResult","blocks":[],"truncated":false}"#.utf8)
        #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: old).projectAction == nil)
        for malformed in [#"{"projectID":"invalid"}"#, #""invalid""#, "null"] {
            let data = Data("{\"entryID\":\"tool\",\"role\":\"toolResult\",\"blocks\":[],\"truncated\":false,\"projectAction\":\(malformed)}".utf8)
            #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: data).projectAction == nil)
        }
    }
}
