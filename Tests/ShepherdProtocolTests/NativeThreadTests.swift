import Foundation
import Testing
import ShepherdProtocol

@Suite("Native thread wire")
struct NativeThreadTests {
    @Test func sharedJSONFixturesRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Extensions/native-thread-wire.json"))
        let frames = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for frame in frames {
            let json = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            let encoded: Data
            switch frame["type"] as? String {
            case "helloNativeAgent", "nativeThreadResult":
                encoded = try NDJSON.encode(JSONDecoder().decode(ExtensionMessage.self, from: json))
            case "nativeThreadCommand":
                encoded = try NDJSON.encode(JSONDecoder().decode(ExtensionReply.self, from: json))
            default:
                if frame["request"] != nil {
                    encoded = try NDJSON.encode(JSONDecoder().decode(RemoteRequest.self, from: json))
                } else {
                    encoded = try NDJSON.encode(JSONDecoder().decode(RemoteReply.self, from: json))
                }
            }
            let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            #expect(decoded == frame as NSDictionary)
        }
        #expect(RemoteProtocol.capabilities.contains("native.thread.v1"))
    }

    @Test func allAnswersAndDeliveriesRoundTrip() throws {
        let answers: [NativeDialogAnswer] = [.select(value: "a"), .confirm(value: false), .input(value: ""), .editor(value: "draft\nnext"), .cancel]
        for answer in answers {
            let request = NativeThreadRequest.answer(expectedSessionID: "s", generation: "g", operationID: UUID(), dialogID: "d", answer: answer)
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
        }
        for delivery in [NativeThreadDelivery.followUp, .steer] {
            let request = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "hello", delivery: delivery)
            #expect(try NDJSON.decode(NativeThreadRequest.self, from: NDJSON.encode(request)) == request)
        }
    }
}
