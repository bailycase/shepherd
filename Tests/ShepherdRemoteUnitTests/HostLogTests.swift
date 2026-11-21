import Foundation
import Testing
@testable import ShepherdRemote
import ShepherdTestKit

@Suite("Host log")
struct HostLogTests {
    @Test func appendsThroughTheCapThenRotates() throws {
        let dir = try makeScratchDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("host.log")
        let previous = dir.appendingPathComponent("host.log.1")
        ShepherdLog.appendHostLog("one\n", url: log, limit: 8)
        ShepherdLog.appendHostLog("two\n", url: log, limit: 8)
        #expect(try String(contentsOf: log, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: previous.path))

        ShepherdLog.appendHostLog("three\n", url: log, limit: 8)
        #expect(try String(contentsOf: previous, encoding: .utf8) == "one\ntwo\n")
        #expect(try String(contentsOf: log, encoding: .utf8) == "three\n")
    }

    @Test func refusesASymlinkEvenWhenItsTargetWouldRotate() throws {
        let dir = try makeScratchDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("host.log")
        let target = dir.appendingPathComponent("other")
        try Data("untouched\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)

        ShepherdLog.appendHostLog("one\n", url: log, limit: 8)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: log.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
    }

    @Test func truncatesALongLineWithoutSplittingUTF8() throws {
        let dir = try makeScratchDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("host.log")
        ShepherdLog.appendHostLog("12345🐏more\n", url: log, limit: 8)
        #expect(try String(contentsOf: log, encoding: .utf8) == "12345\n")
    }
}
