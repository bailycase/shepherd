import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

@Suite("Goal extension")
struct GoalExtensionTests {
    @Test func theInstalledExtensionIsPrivateAndByteIdenticalToItsCanonicalSource() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PiEngine(command: ["/tmp/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node"))
        let home = PiHome(directory: directory.appendingPathComponent("pi"), engine: engine)
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        let installed = try GoalExtension.install(in: home)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try String(contentsOf: root.appendingPathComponent("Extensions/shepherd-goal.ts"), encoding: .utf8)
        #expect(GoalExtension.environmentKey == "SHEPHERD_EXT_GOAL")
        #expect(GoalExtension.path(in: home) == installed.path)
        #expect(installed.lastPathComponent == "shepherd-goal.ts")
        #expect(try posixPermissions(installed) == 0o600)
        #expect(GoalExtension.extensionSource == canonical)
        #expect(try String(contentsOf: installed, encoding: .utf8) == canonical)
    }
}
