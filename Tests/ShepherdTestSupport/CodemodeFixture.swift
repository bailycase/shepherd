import Foundation
import ShepherdProtocol

/// Pi 1.0's persisted parallel-call shape, with Shepherd's bounded display-only excerpts.
public enum CodemodeFixture {
    public static let json = #"""
    {"role":"toolResult","toolCallId":"script","toolName":"codemode","isError":false,"timestamp":1200,
     "content":[{"type":"text","text":"handled"}],
     "nestedCalls":{"complete":true,"calls":[
       {"id":"script/1","name":"read","status":"ok","arguments":{"path":"example.txt"},"durationMs":2},
       {"id":"script/2","name":"read","status":"error","arguments":{"path":"missing.txt"},"durationMs":1,"error":"ENOENT"}]},
     "details":{"calls":[
       {"id":"script/1","name":"read","status":"ok","output":"first\nsecond\n","outputTruncated":false,"startedAt":1000,"timestamp":1002},
       {"id":"script/2","name":"read","status":"error","output":"ENOENT: no such file, missing.txt","outputTruncated":false,"startedAt":1000,"timestamp":1001}]}}
    """#

    public static func message() throws -> RPCMessage {
        try JSONDecoder().decode(RPCMessage.self, from: Data(json.utf8))
    }
}
