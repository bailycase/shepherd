import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Palette content search cancellation and bounded reads", .integrationTimeLimit)
struct PaletteContentSearchIntegrationTests {
    private static let session = #"{"type":"message","message":{"role":"user","content":"Make marmalade today"}}"# + "\n"

    @Test func appendsDuringTheReadCannotGrowTheTailBudget() throws {
        let directory = try makeScratchDirectory("palette-growth")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let original = Data(Self.session.utf8)
        try original.write(to: file)
        let appended = Data(#"{"type":"message","message":{"role":"user","content":"otters arrived later"}}"#.utf8)
        let result = PaletteContentSearch.snippet(for: "otters", inSessionAt: file, tailBudget: original.count) { handle, count in
            #expect(count == original.count)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: appended)
            let data = try handle.read(upToCount: count)
            #expect(data?.count == original.count)
            return data
        }
        #expect(result == nil, "the scan stops at the end observed before the append")
    }

    @Test(arguments: [false, true])
    func ownedScanPreservesOrderOrStopsWhenItsCallerCancels(cancel: Bool) async throws {
        let root = try makeScratchDirectory("palette-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/fixture"
        let directory = PiSessionFile.projectDirectory(forCwd: cwd, sessionsRoot: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targets = ["second", "first"].map { (id: AgentID(), piSessionID: $0, cwd: cwd) }
        for target in targets {
            try Data(Self.session.utf8).write(to: directory.appendingPathComponent("stamp_\(target.piSessionID).jsonl"))
        }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let reads = Locked(0)
        let snippets = Locked<[String?]>([])
        let work = Task {
            defer { signal.finish() }
            return await PaletteContentSearch.search(query: "marmalade", agents: targets, sessionsRoot: root) { query, url in
                let snippet = PaletteContentSearch.snippet(for: query, inSessionAt: url) { handle, count in
                    let first = reads.withValue { $0 += 1; return $0 == 1 }
                    if first {
                        signal.yield(())
                        release.wait()
                    }
                    return try handle.read(upToCount: count)
                }
                snippets.withValue { $0.append(snippet) }
                return snippet
            }
        }
        defer { work.cancel(); release.signal(); signal.finish() }
        var iterator = started.makeAsyncIterator()
        let didStart = await iterator.next()
        #expect(didStart != nil)
        if cancel { work.cancel() }
        release.signal()
        let matches = await work.value
        if cancel {
            #expect(matches.isEmpty)
            #expect(reads.current == 1, "cancellation must stop before the next agent")
            #expect(snippets.current.count == 1 && snippets.current[0] == nil, "cancelled lines are not decoded")
        } else {
            #expect(matches.map(\.agentID) == targets.map(\.id))
            #expect(matches.map(\.snippet) == Array(repeating: "Make marmalade today", count: 2))
            #expect(reads.current == 2)
        }
    }
}
