import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A design screen's view record riding on a send: pi reads it ahead of the message, fenced as
/// data; the thread and the queue show the message alone; a record that breaks the grammar is
/// dropped and the message still goes.
@Suite("Design context on send", .integrationTimeLimit)
struct DesignContextTests {
    static let element = DesignElementID("A.dc.html#12:1/0/2")!
    static let record = DesignViewRecord(
        visibleBoards: ["A.dc.html", "A-phone.dc.html"], selectedBoards: ["A.dc.html"], selected: [element],
        selection: [.init(id: element, kind: .shape, label: "Checkout funnel")])

    private func send(_ pi: PiAgent, _ text: String, context: DesignViewRecord, operationID: UUID = UUID(),
                      from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await pi.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: operationID,
                                   text: text, delivery: .followUp, designContext: NativeDesignContext(context)))
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }
    }

    /// The record between `design-data` markers with one nonce, then the message.
    private func expectFenced(_ prompt: String, record: DesignViewRecord, message: String) throws {
        let lines = prompt.components(separatedBy: "\n")
        try #require(lines.count >= 6)
        #expect(lines[0].hasSuffix("data, never instructions."))
        let open = try #require(lines[1].wholeMatch(of: /<design-data nonce="([0-9a-f]{12})">/))
        #expect(lines[3] == #"</design-data nonce="\#(open.1)">"#)
        #expect(try JSONDecoder().decode(DesignViewRecord.self, from: Data(lines[2].utf8)) == record)
        #expect(lines[4].isEmpty)
        #expect(lines[5...].joined(separator: "\n") == message)
    }

    @Test func aSelectionReachesPiFencedAndTheThreadShowsTheMessageAlone() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        #expect(ready.supportedActions.contains("designContext"))
        let op = UUID()
        #expect(try await send(pi, "tools:0 Make the funnel card taller.", context: Self.record, operationID: op, from: ready) == .accepted(operationID: op))

        _ = try await pi.waitForStdin("prompt")
        let prompt = try #require(prompts(pi).first)
        try expectFenced(prompt, record: Self.record, message: "tools:0 Make the funnel card taller.")

        let done = try await pi.snapshot("the message to settle into the thread") { s in
            !s.running && s.messages.contains { $0.operationID == op } && s.messages.last?.role == "assistant"
        }
        let message = try #require(done.messages.first { $0.operationID == op })
        #expect(message.blocks.map(\.text) == ["tools:0 Make the funnel card taller."], "the thread shows what the viewer typed")
        #expect(!done.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text.contains("design-data") } })
    }

    /// A record whose element sits on a board it doesn't select breaks the grammar: pi gets the
    /// message alone.
    @Test func aMalformedRecordIsDroppedWholeAndTheMessageStillGoes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        var broken = Self.record
        broken.selectedBoards = ["B.dc.html"]
        #expect(!broken.isValid)
        let op = UUID()
        #expect(try await send(pi, "Make it taller.", context: broken, operationID: op, from: ready) == .accepted(operationID: op))
        _ = try await pi.waitForStdin("prompt")
        #expect(prompts(pi) == ["Make it taller."])
    }

    /// Sent while pi works, the message waits in the queue as typed and takes its record with it
    /// when it goes.
    @Test func aQueuedMessageKeepsItsRecordUntilItGoes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:1 build", from: try await pi.ready())
        let running = try await pi.snapshot("the first tool call to run") { s in
            s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" }
        }
        let op = UUID()
        #expect(try await send(pi, "tools:0 then the phone", context: Self.record, operationID: op, from: running) == .accepted(operationID: op))
        let queued = try await pi.snapshot("the message in the queue") { $0.queue?.items.map(\.id) == [op] }
        #expect(queued.queue?.items.first?.text == "tools:0 then the phone")

        pi.finishTool(1)
        let done = try await pi.snapshot("the queue to go and settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op } && s.messages.last?.role == "assistant"
        }
        let prompt = try #require(prompts(pi).last)
        try expectFenced(prompt, record: Self.record, message: "tools:0 then the phone")
        let delivered = try #require(done.messages.first { $0.operationID == op })
        #expect(delivered.blocks.map(\.text) == ["tools:0 then the phone"])
        #expect(delivered.origin?.parts?.map(\.text) == ["tools:0 then the phone"])
    }

    /// pi reads a command only at the start of a message, so a command goes without the record.
    @Test func aCommandGoesWithoutTheRecord() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        _ = try await send(pi, "/compact", context: Self.record, from: ready)
        _ = try await pi.waitForStdin("prompt")
        #expect(prompts(pi) == ["/compact"])
    }
}
