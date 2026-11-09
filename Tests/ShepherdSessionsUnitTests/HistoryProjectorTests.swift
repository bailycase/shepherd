import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// Projecting pi's transcript in slices: appending a slice gives the rows and the context estimate
/// the whole list would, and the projector keeps nothing it has no use for.
@Suite("History projector")
struct HistoryProjectorTests {
    private static func text(_ count: Int) -> String { String(repeating: "x", count: count) }

    private static func call(_ id: String, _ name: String, _ args: [String: JSONValue], at time: Double? = nil,
                             usage: RPCUsage? = nil) -> RPCMessage {
        RPCMessage(role: "assistant", content: [.toolCall(id: id, name: name, arguments: .object(args))], stopReason: "toolUse",
                   timestamp: time, usage: usage)
    }

    private static func result(_ id: String, _ name: String, chars: Int, at time: Double? = nil) -> RPCMessage {
        RPCMessage(role: "toolResult", content: [.text(text(chars))], toolName: name, toolCallId: id, timestamp: time)
    }

    /// ThreadProjectionTests' history: two users in one millisecond, an assistant without a time, a hidden custom message and a
    /// `shepherd-child` report.
    private static let threadHistory = #"""
    [{"role":"user","content":"Fix it","timestamp":1000},
     {"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}],"timestamp":2000},
     {"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"a"}],"timestamp":2500},
     {"role":"custom","customType":"memo","content":"model only","timestamp":2600},
     {"role":"custom","customType":"shepherd-child","display":true,"content":"Child done","timestamp":2700},
     {"role":"user","content":"again","timestamp":3000},
     {"role":"user","content":"same millisecond","timestamp":3000},
     {"role":"assistant","content":[{"type":"text","text":"no time"}]}]
    """#

    /// A codemode result with the nested calls pi saved and the excerpts Shepherd keeps.
    private static let script = #"""
    {"role":"toolResult","toolCallId":"script","toolName":"codemode","isError":false,"timestamp":4300,
     "content":[{"type":"text","text":"handled"}],
     "nestedCalls":{"complete":true,"calls":[
       {"id":"script/1","name":"read","status":"ok","arguments":{"path":"example.txt"},"durationMs":2},
       {"id":"script/2","name":"read","status":"error","arguments":{"path":"missing.txt"},"durationMs":1,"error":"ENOENT"}]},
     "details":{"calls":[
       {"id":"script/1","name":"read","status":"ok","output":"first\nsecond\n","outputTruncated":false,"startedAt":4000,"timestamp":4002},
       {"id":"script/2","name":"read","status":"error","output":"ENOENT: no such file, missing.txt","outputTruncated":false,"startedAt":4000,"timestamp":4001}]}}
    """#

    private static let system = RPCMessage(
        role: "system", content: [], timestamp: 1,
        sections: ["preamble": text(400), "docs": text(400),
                   "project_context": "<project_context>\n<project_instructions path=\"/repo/AGENTS.md\">\n\(text(800))\n</project_instructions>\n"
                       + "<project_instructions path=\"/repo/Sources/CLAUDE.md\">\nmore\n</project_instructions>\n</project_context>"],
        toolsAdded: [.object(["name": .string("read"), "description": .string(text(38))]), .object(["name": .string("ls")])])

    private static let patch = RPCMessage(role: "system", content: [], timestamp: 4400, sections: ["docs": String?.none],
                                          toolsRemoved: [.object(["name": .string("ls")])])

    private static let image = RPCContentBlock.image(
        mimeType: "image/png", data: "", ref: RPCImageRef(sha256: String(repeating: "a", count: 64), byteCount: 2048, width: 32, height: 32))

    /// A thread in the order the host projects it (a compaction after the messages it kept): every kind of message the projection and
    /// the estimate treat differently.
    private static func fixture() throws -> [RPCMessage] {
        let history: [RPCMessage] = try decode(threadHistory)
        let script: RPCMessage = try decode(Self.script)
        return [system] + history + [
            call("r1", "read", ["path": .string("Sources/App/ThreadView.swift")], at: 4000, usage: RPCUsage(input: 900, output: 40)),
            result("r1", "read", chars: 1600, at: 4100),
            call("b1", "bash", ["command": .string("swift test --filter Native\nsecond line")], at: 4150),
            result("b1", "bash", chars: 800, at: 4200),
            script,
            patch,
            RPCMessage(role: "user", content: [.text("look at this"), image], timestamp: 5000),
            RPCMessage(role: "custom", content: [.text("Report")], timestamp: 5100, customType: "memo", display: true),
            RPCMessage(role: "assistant", content: [], stopReason: "error", errorMessage: "provider failed", timestamp: 5200),
            RPCMessage(role: "compactionSummary", content: [], timestamp: 6000, summary: "Fixed the build.", tokensBefore: 90_000),
            RPCMessage(role: "assistant", content: [.text("Carrying on.")], stopReason: "stop", timestamp: 6100,
                       usage: RPCUsage(input: 1500, output: 20)),
        ]
    }

    @Test func appendingInSlicesProjectsWhatTheWholeListDoes() throws {
        let all = try Self.fixture()
        let images = ThreadImages.table(for: all)
        #expect(!images.isEmpty, "the fixture's image is offered")
        let whole = RPCThreadState.projectHistory(all, images: images)
        #expect(whole.contains { $0.entryID == "t:script" } && whole.contains { $0.entryID.hasSuffix(":nested:script/2") })
        #expect(whole.contains { $0.entryID == "user:3000#1" } && whole.contains { $0.entryID == "m:8" })
        let estimate = RPCThreadState.estimate(all)
        #expect(estimate.summaryEntryID != nil && estimate.baseline != nil && !estimate.largest.isEmpty)

        for first in 0...all.count {
            var projector = RPCThreadState.HistoryProjector()
            var rows = projector.append(Array(all[..<first]), images: images)
            #expect(projector.count == first)
            #expect(projector.estimator.estimate() == RPCThreadState.estimate(Array(all[..<first])), "estimate after \(first)")
            rows += projector.append(Array(all[first...]), images: images)
            #expect(rows.map(\.entryID) == whole.map(\.entryID), "ids split at \(first)")
            #expect(rows == whole, "rows split at \(first)")
            #expect(projector.estimator.estimate() == RPCThreadState.estimate(all))
        }
    }

    @Test func appendingInThreeSlicesProjectsWhatTheWholeListDoes() throws {
        let all = try Self.fixture()
        let images = ThreadImages.table(for: all)
        let whole = RPCThreadState.projectHistory(all, images: images)
        for first in 0...all.count {
            for second in first...all.count {
                var projector = RPCThreadState.HistoryProjector()
                var rows = projector.append(Array(all[..<first]), images: images)
                rows += projector.append(Array(all[first..<second]), images: images)
                #expect(projector.estimator.estimate() == RPCThreadState.estimate(Array(all[..<second])), "estimate after \(second)")
                rows += projector.append(Array(all[second...]), images: images)
                #expect(rows == whole, "rows split at \(first) and \(second)")
            }
        }
    }

    @Test func aSliceOfOneMessageAtATimeGivesTheSameRowsAndEstimates() throws {
        let all = try Self.fixture()
        let whole = RPCThreadState.projectHistory(all)
        var projector = RPCThreadState.HistoryProjector()
        var rows: [NativeThreadMessage] = []
        for (index, message) in all.enumerated() {
            rows += projector.append([message])
            #expect(projector.estimator.estimate() == RPCThreadState.estimate(Array(all[...index])), "estimate after \(index)")
        }
        #expect(rows == whole)
    }

    @Test func shownNamesTheIDsAppendGives() throws {
        let all = try Self.fixture()
        // The repeat of "user:3000" lands in the second slice.
        let split = try #require(all.firstIndex { $0.content == [.text("same millisecond")] })
        var projector = RPCThreadState.HistoryProjector()
        _ = projector.append(Array(all[..<split]))
        let count = projector.count
        let rest = Array(all[split...])

        let named = projector.shown(rest)
        #expect(projector.count == count, "naming the ids appends nothing")
        #expect(named.first?.entryID == "user:3000#1")
        let rows = projector.append(rest)
        #expect(rows.filter { !$0.entryID.contains(":nested:") }.map(\.entryID) == named.map(\.entryID))
        #expect(named.map(\.message) == rest.filter { $0.role != "system" && !($0.role == "custom" && $0.display != true) })
        #expect(RPCThreadState.HistoryProjector().shown(all).map(\.entryID) == RPCThreadState.shownHistory(all).map(\.entryID))
    }

    @Test func aResultKeepsItsOwnCallsArgumentsWhenAProviderReusesCallIDs() throws {
        let messages = [
            RPCMessage(role: "user", content: [.text("one")], timestamp: 1),
            Self.call("call_0", "bash", ["command": .string("echo one")], at: 2),
            Self.result("call_0", "bash", chars: 4, at: 3),
            RPCMessage(role: "assistant", content: [.text("done")], timestamp: 4),
            RPCMessage(role: "user", content: [.text("two")], timestamp: 5),
            Self.call("call_0", "bash", ["command": .string("echo two")], at: 6),
            Self.result("call_0", "bash", chars: 4, at: 7),
        ]
        func check(_ rows: [NativeThreadMessage]) {
            let results = rows.filter { $0.role == "toolResult" }
            #expect(results.map(\.entryID) == ["t:call_0", "t:call_0#1"])
            #expect(results.map(\.argumentsText) == [#"{"command":"echo one"}"#, #"{"command":"echo two"}"#])
            #expect(results.map(\.startedAt) == [2, 6])
        }
        check(RPCThreadState.projectHistory(messages))
        var projector = RPCThreadState.HistoryProjector()
        check(projector.append(Array(messages[..<4])) + projector.append(Array(messages[4...])))
    }

    @Test func aRepeatedCallBlockMergesWhatItSaysAndOnlyTheFirstResultTakesIt() throws {
        // A call block that repeats an id without arguments or a time keeps the ones the earlier block gave.
        let messages = [
            Self.call("c", "bash", ["command": .string("make")], at: 2),
            RPCMessage(role: "assistant", content: [.toolCall(id: "c", name: "bash", arguments: nil)], timestamp: nil),
            Self.result("c", "bash", chars: 4, at: 3),
            Self.result("c", "bash", chars: 4, at: 4),
        ]
        let rows = RPCThreadState.projectHistory(messages).filter { $0.role == "toolResult" }
        #expect(rows.map(\.argumentsText) == [#"{"command":"make"}"#, nil], "a second result for one call finds no arguments")
        #expect(rows.map(\.startedAt) == [2, nil])
    }

    @Test func theProjectorKeepsNoCallOnceItsResultIsIn() throws {
        var projector = RPCThreadState.HistoryProjector()
        let turn = [
            RPCMessage(role: "assistant", content: [
                .toolCall(id: "a", name: "read", arguments: .object(["path": .string("a.swift")])),
                .toolCall(id: "b", name: "read", arguments: .object(["path": .string("b.swift")])),
                .toolCall(id: "c", name: "bash", arguments: .object(["command": .string("ls")])),
            ], stopReason: "toolUse", timestamp: 10),
            Self.result("b", "read", chars: 40, at: 11),
            Self.result("a", "read", chars: 40, at: 12),
        ]
        _ = projector.append(Array(turn[..<1]))
        #expect(projector.openCallCount == 3 && projector.estimator.openCallCount == 3)
        _ = projector.append(Array(turn[1...]))
        #expect(projector.openCallCount == 1 && projector.estimator.openCallCount == 1, "only the call still running")
        _ = projector.append([Self.result("c", "bash", chars: 40, at: 13)])
        #expect(projector.openCallCount == 0 && projector.estimator.openCallCount == 0)

        var whole = RPCThreadState.HistoryProjector()
        _ = whole.append(try Self.fixture())
        #expect(whole.openCallCount == 0 && whole.estimator.openCallCount == 0, "every call in the fixture has its result")
    }

    @Test func callsNeverAnsweredAreCappedAndTheOldestGoFirst() throws {
        let limit = RPCThreadState.HistoryProjector.openCallLimit
        var projector = RPCThreadState.HistoryProjector()
        for index in 0..<(limit + 88) {
            _ = projector.append([Self.call("c\(index)", "read", ["path": .string("f\(index)")], at: Double(10 + index))])
        }
        #expect(projector.openCallCount == limit && projector.estimator.openCallCount == limit)
        let rows = projector.append([Self.result("c0", "read", chars: 4, at: 1000), Self.result("c\(limit + 87)", "read", chars: 4, at: 1001)])
        #expect(rows.map(\.argumentsText) == [nil, #"{"path":"f\#(limit + 87)"}"#])
        #expect(rows.map(\.startedAt) == [nil, Double(10 + limit + 87)])
        #expect(projector.openCallCount == limit - 1, "the dropped call's result takes nothing, the kept one's takes its call")
    }

    @Test func theLargestListKeepsItsOrder() throws {
        // Ties inside the list and across its edge: the top three are the 1,200s (first seen first) and then the first 800.
        let sizes = [800, 400, 1200, 800, 1200, 100, 800, 50, 600, 200].map { $0 * 4 }
        var messages: [RPCMessage] = []
        for (index, chars) in sizes.enumerated() {
            messages.append(Self.call("c\(index)", "bash", ["command": .string("command \(index)")], at: Double(100 + 2 * index)))
            messages.append(Self.result("c\(index)", "bash", chars: chars, at: Double(101 + 2 * index)))
        }
        let reference = sizes.enumerated()
            .sorted { $0.element != $1.element ? $0.element > $1.element : $0.offset < $1.offset }
            .prefix(NativeContextItem.limit)
        #expect(reference.map(\.offset) == [2, 4, 0])

        var projector = RPCThreadState.HistoryProjector()
        _ = projector.append(messages)
        let largest = projector.estimator.estimate().largest
        #expect(largest.map(\.entryID) == reference.map { "t:c\($0.offset)" })
        #expect(largest.map(\.tokens) == reference.map { $0.element / 4 })
        #expect(largest.map(\.label) == reference.map { "command \($0.offset)" })
        #expect(largest == RPCThreadState.estimate(messages).largest)
    }

    @Test func theSameLabelAddsUpAndKeepsTheEntryOfItsLargestResult() throws {
        let messages = [
            Self.call("r1", "read", ["path": .string("a/File.swift")], at: 10), Self.result("r1", "read", chars: 400, at: 11),
            Self.call("r2", "read", ["path": .string("b/File.swift")], at: 12), Self.result("r2", "read", chars: 1200, at: 13),
            Self.call("r3", "read", ["path": .string("c/File.swift")], at: 14), Self.result("r3", "read", chars: 800, at: 15),
        ]
        var projector = RPCThreadState.HistoryProjector()
        for message in messages { _ = projector.append([message]) }
        #expect(projector.estimator.estimate().largest == [NativeContextItem(entryID: "t:r2", kind: .file, label: "File.swift", tokens: 600)])
        #expect(projector.estimator.estimate() == RPCThreadState.estimate(messages))
    }
}
