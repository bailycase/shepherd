import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Server-wide read cache", .integrationTimeLimit)
struct ServerReadCacheTests {
    @Test func aHundredTranscriptOwnersStayWithinOneBudgetAndRetirementReleasesIt() throws {
        let dir = try makeScratchDirectory("read-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("child.jsonl")
        try #"{"type":"message","id":"u","message":{"role":"user","content":"bounded transcript"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let cache = ThreadReadCache(byteLimit: 4096)
        var readers = (0..<100).map { _ in ChildTranscriptReader(cache: cache) }
        for reader in readers {
            let (result, built) = reader.read(runID: "child", file: file.path, generation: "same-generation", before: nil)
            guard case .transcript = result else { Issue.record("expected transcript"); return }
            #expect(built, "different owners cannot reuse each other's rows")
            #expect(cache.retainedBytes <= 4096 && cache.inFlightBytes == 0)
        }
        #expect(!readers[99].read(runID: "child", file: file.path, generation: "same-generation", before: nil).built)
        #expect(readers[0].read(runID: "child", file: file.path, generation: "same-generation", before: nil).built,
                "fleet pressure evicts the oldest owner's retained rows")
        var reservation = cache.reserve(bytes: ThreadReadCache.defaultInFlightBytes)
        #expect(reservation != nil)
        #expect(readers[0].read(runID: "child", file: file.path, generation: "same-generation", before: nil).0.failureCode == "transcript_unavailable")
        reservation = nil
        #expect(!readers[0].read(runID: "child", file: file.path, generation: "same-generation", before: nil).built)
        readers.removeAll()
        #expect(cache.retainedBytes == 0 && cache.inFlightBytes == 0)
    }

    @Test func separateRPCThreadsEvictWithinTheSharedImageBudgetAndReleaseOnRetirement() async throws {
        let dir = try makeScratchDirectory("image-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = ThreadImagesTests.png(bytes: 600_000), file = dir.appendingPathComponent("history.json")
        let rows: [[String: Any]] = [
            ["role": "user", "timestamp": 1, "content": [["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()]]],
            ["role": "assistant", "timestamp": 2, "content": [["type": "text", "text": "seen"]], "stopReason": "stop"],
        ]
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        let cache = ThreadReadCache(byteLimit: data.count)
        var first: ThreadEventTests.Thread? = try .init(env: ["STUB_PI_MESSAGES_FILE": file.path], readCache: cache)
        var second: ThreadEventTests.Thread? = try .init(env: ["STUB_PI_MESSAGES_FILE": file.path], readCache: cache)
        defer { first?.stop(); second?.stop() }
        let a = try await first!.ready(), b = try await second!.ready()
        let imageID = try #require(a.messages.flatMap(\.blocks).compactMap(\.imageID).first)
        #expect(b.messages.flatMap(\.blocks).compactMap(\.imageID).first == imageID)
        func fetch(_ thread: ThreadEventTests.Thread) async throws {
            guard case .imageChunk = await thread.request(.image(expectedSessionID: a.piSessionID, imageID: imageID, offset: 0)) else {
                Issue.record("expected verified chunk"); return
            }
            #expect(cache.retainedBytes == data.count)
            try await eventually("read reservation released") { cache.inFlightBytes == 0 }
        }
        try await fetch(first!)
        try await fetch(second!)
        try await fetch(first!)
        #expect(first!.queue.sync { first!.state.imageVerificationCount } == 2)
        #expect(second!.queue.sync { second!.state.imageVerificationCount } == 1)
        first?.stop(); first = nil
        try await eventually("the retired first thread releases its retained entry") { cache.retainedBytes == 0 }
        guard case .imageChunk = await second!.request(.image(expectedSessionID: b.piSessionID, imageID: imageID, offset: 0)) else {
            Issue.record("expected remaining owner to read again"); return
        }
        second?.stop(); second = nil
        try await eventually("all retired image owners and workers release their budget") { cache.retainedBytes == 0 && cache.inFlightBytes == 0 }
    }
}
