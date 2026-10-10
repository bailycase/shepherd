import Foundation
import Testing
@testable import ShepherdSessions

/// Where the shipped engine lives in an app: the layout `scripts/pi_engine.py` stages, found from
/// the bundle's Contents, and nothing when any part of it is missing.
@Suite("The bundled pi engine's layout")
struct BundledPiEngineTests {
    enum Missing: String, CaseIterable {
        case nothing, node, nodeExecuteBit, entry, packageManifest, version
    }

    /// A scratch Contents/ holding the engine's layout, minus `missing`.
    func makeContents(missing: Missing) throws -> URL {
        let contents = try makeTempDirectory().appendingPathComponent("Contents", isDirectory: true)
        let files = FileManager.default
        let node = contents.appendingPathComponent(BundledPiEngine.nodePath)
        let package = contents.appendingPathComponent(BundledPiEngine.packagePath, isDirectory: true)
        let entry = package.appendingPathComponent(BundledPiEngine.entryPath)
        try files.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        if missing != .node {
            try Data().write(to: node)
            try files.setAttributes([.posixPermissions: missing == .nodeExecuteBit ? 0o644 : 0o755], ofItemAtPath: node.path)
        }
        if missing != .entry { try Data().write(to: entry) }
        if missing != .packageManifest {
            let manifest = missing == .version ? #"{"name":"@earendil-works/pi-coding-agent"}"# : #"{"version":"1.0.0"}"#
            try Data(manifest.utf8).write(to: package.appendingPathComponent("package.json"))
        }
        return contents
    }

    @Test func theEngineIsNodeRunningThePackagesEntryFromContents() throws {
        let contents = try makeContents(missing: .nothing)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let engine = try #require(BundledPiEngine(contents: contents))
        #expect(engine.node == contents.appendingPathComponent("Helpers/node"))
        #expect(engine.packageDirectory.standardizedFileURL == contents.appendingPathComponent("Resources/pi-engine").standardizedFileURL)
        #expect(engine.command == [contents.appendingPathComponent("Helpers/node").path,
                                   contents.appendingPathComponent("Resources/pi-engine/dist/cli.js").path])
        #expect(engine.version == "1.0.0")
        #expect(BundledPiEngine(app: contents.deletingLastPathComponent()) == engine)
    }

    @Test(arguments: Missing.allCases.filter { $0 != .nothing })
    func anIncompleteEngineIsNoEngine(missing: Missing) throws {
        let contents = try makeContents(missing: missing)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        #expect(BundledPiEngine(contents: contents) == nil)
    }
}
