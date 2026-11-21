import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Native child extension installation", .integrationTimeLimit)
struct ChildrenExtensionTests {
    private static let entry = "shepherd-children.ts"
    private static let oldFiles = [
        entry: "import './shepherd-lines.mjs'; export default function () {}",
        "shepherd-lines.mjs": "export const lines = 'old';",
        "shepherd-children-config.ts": "export const config = 'old';",
        "shepherd-workflow.ts": "export const workflow = 'old';",
        "shepherd-children-ui.ts": "export const ui = 'old';",
        "shepherd-cli.ts": "export const cli = 'old';",
        "shepherd-cli-client.mjs": "export const client = 'old';",
        "shepherd-bash.mjs": "export const bash = 'old';",
        "shepherd-inspect.mjs": "export const inspect = 'old';",
    ].mapValues { Data($0.utf8) }

    @Test func theInstallerKeepsTheRunningBuildsBytesAfterAnUpdateAddsAnImport() throws {
        let scratch = try makeScratchDirectory("child-ext")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Extensions.bundle")
        try Self.writeBundle(Self.oldFiles, at: bundle)
        let running = try EmbeddedExtensions.Snapshot(directory: bundle)

        let replacement = scratch.appendingPathComponent("Update.bundle")
        var newFiles = Self.oldFiles
        newFiles[Self.entry] = Data("import './new-helper.mjs'; export default function () {}".utf8)
        newFiles["new-helper.mjs"] = Data("export {};".utf8)
        newFiles["shepherd-lines.mjs"] = Data("export const lines = 'new';".utf8)
        try Self.writeBundle(newFiles, at: replacement)
        _ = try fm.replaceItemAt(bundle, withItemAt: replacement, options: .usingNewMetadataOnly)
        try #require(try Data(contentsOf: bundle.appendingPathComponent(Self.entry)) == newFiles[Self.entry])

        let support = scratch.appendingPathComponent("support")
        let installed = try ChildrenExtension.installedPath(in: support, snapshot: running)
        #expect(installed == support.appendingPathComponent(Self.entry).path)
        #expect(Set(try fm.contentsOfDirectory(atPath: support.path)) == Set(Self.oldFiles.keys))
        for (name, bytes) in Self.oldFiles {
            #expect(try Data(contentsOf: support.appendingPathComponent(name)) == bytes, "installed \(name)")
        }
    }

    @Test func aFailedHelperWriteLeavesThePreviousEntryPointInPlace() throws {
        let scratch = try makeScratchDirectory("child-ext")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Extensions.bundle")
        try Self.writeBundle(Self.oldFiles, at: bundle)
        let running = try EmbeddedExtensions.Snapshot(directory: bundle)

        let support = scratch.appendingPathComponent("support")
        let blockedHelper = support.appendingPathComponent("shepherd-inspect.mjs")
        try fm.createDirectory(at: blockedHelper, withIntermediateDirectories: true)
        try Data().write(to: blockedHelper.appendingPathComponent("keep"))
        let entry = support.appendingPathComponent(Self.entry)
        let previous = Data("export default function () {}".utf8)
        try previous.write(to: entry)

        #expect(throws: CocoaError.self) { try ChildrenExtension.installedPath(in: support, snapshot: running) }
        #expect(try Data(contentsOf: entry) == previous)
    }

    private static func writeBundle(_ files: [String: Data], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in files { try bytes.write(to: directory.appendingPathComponent(name)) }
    }
}
