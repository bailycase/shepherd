import Foundation
import Testing
import ShepherdTestSupport
@testable import DesignSurfaceKit

@Suite(.integrationTimeLimit)
struct DesignAssetIndexTests {
    @Test(arguments: [100, 1_000])
    func suffixedAssetsEnumerateOnceAndNeverCacheContents(_ count: Int) throws {
        let folder = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = folder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for n in 0..<count { try Data("first".utf8).write(to: assets.appendingPathComponent("a\(n).png")) }
        let index = DesignSchemeHandler.AssetIndex()
        for n in 0..<count {
            #expect(DesignSchemeHandler.read(.blob("a\(n)"), folder: folder, assets: index)?.data == Data("first".utf8))
        }
        #expect(index.enumerations == 1)
        try Data("changed".utf8).write(to: assets.appendingPathComponent("a0.png"))
        #expect(DesignSchemeHandler.read(.blob("a0"), folder: folder, assets: index)?.data == Data("changed".utf8))
        #expect(index.enumerations == 1)
    }

    @Test func importsRenamesDeletesDuplicatesAndEscapingLinksAreRechecked() throws {
        let folder = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = folder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let index = DesignSchemeHandler.AssetIndex()
        func read(_ id: String) -> Data? { DesignSchemeHandler.read(.blob(id), folder: folder, assets: index)?.data }
        #expect(read("new") == nil)
        try Data("png".utf8).write(to: assets.appendingPathComponent("new.png"))
        #expect(read("new") == Data("png".utf8))
        try Data("jpg".utf8).write(to: assets.appendingPathComponent("new.jpg"))
        #expect(read("new") == Data("jpg".utf8), "Duplicate suffixes choose the lexical minimum")
        try FileManager.default.moveItem(at: assets.appendingPathComponent("new.jpg"), to: assets.appendingPathComponent("renamed.jpg"))
        #expect(read("new") == Data("png".utf8))
        #expect(read("renamed") == Data("jpg".utf8))
        try FileManager.default.removeItem(at: assets.appendingPathComponent("new.png"))
        #expect(read("new") == nil)
        try Data("bare".utf8).write(to: assets.appendingPathComponent("renamed"))
        #expect(read("renamed") == Data("bare".utf8))
        let secret = folder.appendingPathComponent("secret")
        try Data("outside".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("escape.png"), withDestinationURL: secret)
        #expect(read("escape") == nil)
        #expect(read("../secret") == nil)
        // Replacing a previously safe file with an escaping link must not serve old bytes.
        try FileManager.default.removeItem(at: assets.appendingPathComponent("renamed.jpg"))
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("renamed.jpg"), withDestinationURL: secret)
        try FileManager.default.removeItem(at: assets.appendingPathComponent("renamed"))
        #expect(read("renamed") == nil)
        let outside = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("escape.png"))
        try FileManager.default.moveItem(at: assets, to: folder.appendingPathComponent("old-assets"))
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
        #expect(read("escape") == nil, "The assets directory itself cannot redirect outside the design")
    }
}
