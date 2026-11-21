import Foundation
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

struct ChangesRecentsTests {
    @Test(arguments: ["{", #"{"/tmp/acme":["main",42]}"#, #"{"version":2,"value":{"/tmp/acme":["main"]}}"#])
    func damageAfterAHealthyReadRefusesBothPaths(_ text: String) throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bases.json")
        let store = ChangesRecents(url: url)
        let repository = "/tmp/acme"
        try Data(#"{"/tmp/acme":["main"]}"#.utf8).write(to: url)
        #expect(try store.list(repository) == ["main"])

        let damaged = Data(text.utf8)
        try damaged.write(to: url, options: .atomic)
        #expect(throws: ChangesError.self) { _ = try store.list(repository) }
        #expect(throws: ChangesError.self) { try store.note("release", repository: repository) }
        #expect(try Data(contentsOf: url) == damaged)

        try FileManager.default.removeItem(at: url)
        #expect(try store.list(repository).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try store.note("release", repository: repository)
        #expect(try store.list(repository) == ["release"])
    }

    @Test func unreadableEntryIsNotMissing() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bases.json")
        let target = directory.appendingPathComponent("not-present.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = ChangesRecents(url: url)
        #expect(throws: ChangesError.self) { _ = try store.list("/tmp/acme") }
        #expect(throws: ChangesError.self) { try store.note("main", repository: "/tmp/acme") }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    }

    @Test func envelopeReadsAndWritesTheLegacyDictionary() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bases.json")
        let store = ChangesRecents(url: url)
        try Data(#"{"value":{"/tmp/acme":["main","release","pilot","old","oldest"],"/tmp/beacon":["trunk"]},"version":1}"#.utf8).write(to: url)
        #expect(try store.list("/tmp/acme") == ["main", "release", "pilot", "old", "oldest"])
        try store.note("release", repository: "/tmp/acme")
        try store.note("staging", repository: "/tmp/acme")
        let legacy = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(legacy == ["/tmp/acme": ["staging", "release", "main", "pilot", "old"], "/tmp/beacon": ["trunk"]])
    }
}
