import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Goal policy stdin backpressure", .integrationTimeLimit)
struct GoalPolicyBackpressureTests {
    @Test(arguments: [false, true])
    func aFullStdinRetainsDisableBeforeTheLatestPolicyAndPreservesOrdinaryRecords(reenable: Bool) async throws {
        let h = try RPCSessionTests.Harness(command: ["python3", "-c", """
        import json, os, sys
        os.mkfifo('read-now')
        print('{"type":"agent_start"}', flush=True)
        with open('read-now', 'rb') as gate: gate.read(1)
        with open('commands.jsonl', 'w') as log:
            for i, line in enumerate(sys.stdin, 1):
                json.loads(line)
                log.write(line)
                log.flush()
                print(json.dumps({'type': 'received_' + str(i)}), flush=True)
        """], env: [GoalExtension.environmentKey: "1"])
        defer { h.stop() }
        try await h.waitFor("agent_start")
        let thread = await h.onQueue { Locked(RPCThreadState(session: h.session, queue: h.queue)) }
        let overhead = try NDJSON.encode(RPCCommandFrame(id: nil, command: .prompt(message: ""))).count
        let first = String(repeating: "x", count: RPCSession.outputQueueLimit - overhead)
        let retries = Locked(0)
        let last = await h.onQueue {
            let state = thread.current
            #expect(h.session.send(.prompt(message: first)))
            let room = RPCSession.outputQueueLimit - h.session.pendingInputBytes
            #expect(room >= overhead)
            let last = String(repeating: "y", count: max(0, room - overhead))
            #expect(h.session.send(.prompt(message: last)))
            #expect(h.session.pendingInputBytes == RPCSession.outputQueueLimit)
            #expect(!h.session.send(.getState), "stdin really is full, not merely slow")
            state.setGoalsEnabled(false)
            #expect(!state.goalsEnabled)
            if reenable {
                // Repeated toggles still retain only the disable barrier and final On.
                for _ in 0..<8 {
                    state.setGoalsEnabled(true)
                    state.setGoalsEnabled(false)
                }
                state.setGoalsEnabled(true)
                #expect(state.goalsEnabled)
            }
            #expect(h.session.pendingInputBytes == RPCSession.outputQueueLimit)
            #expect(retries.current == 0)
            let retry = h.session.onInputDrained
            #expect(retry != nil)
            h.session.onInputDrained = {
                #expect(h.session.onInputDrained == nil, "consume the callback before retrying send")
                retries.withValue { $0 += 1 }
                retry?()
            }
            return last
        }

        let gate = try FileHandle(forWritingTo: h.dir.appendingPathComponent("read-now"))
        try gate.write(contentsOf: Data([1]))
        try gate.close()
        let expectedCount = reenable ? 4 : 3
        try await h.waitFor("unknown:received_\(expectedCount)")
        #expect(await h.onQueue { h.session.pendingInputBytes } == 0)
        #expect(await h.onQueue { thread.current.goalsEnabled } == reenable)
        #expect(retries.current == 1)
        #expect(await h.onQueue { h.session.onInputDrained == nil })
        let bytes = try Data(contentsOf: h.dir.appendingPathComponent("commands.jsonl"))
        let records = try bytes.split(separator: UInt8(ascii: "\n")).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        #expect(records.count == expectedCount, "no abort or queue clearing may be injected")
        #expect(records.allSatisfy { $0["type"] as? String == "prompt" })
        #expect(records.prefix(2).compactMap { $0["message"] as? String } == [first, last])
        let policies = try records.dropFirst(2).map { record in
            #expect(record["streamingBehavior"] as? String == "steer")
            let message = try #require(record["message"] as? String)
            #expect(message.hasPrefix("/shepherd-goal "))
            let policy = try #require(JSONSerialization.jsonObject(with: Data(message.dropFirst("/shepherd-goal ".count).utf8)) as? [String: Any])
            #expect(policy["action"] as? String == "configure")
            return try #require(policy["enabled"] as? Bool)
        }
        #expect(policies == (reenable ? [false, true] : [false]))
        #expect(await h.onQueue { h.session.isAlive })
    }
}
