import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdProtocol

/// The shared resolver behind the Mac's Files pane and a host's `files.v1` (docs/design/side-pane-files.md).
@Suite("Thread files")
struct ThreadFilesTests {
    /// `root/a/b.txt`, `root/up -> ..` (inside `a`), `root/out -> <outside>`.
    static func folder() throws -> (root: URL, outside: URL) {
        let root = try makeScratchDirectory("thread-files")
        let outside = try makeScratchDirectory("thread-files-out")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("b\n".utf8).write(to: root.appendingPathComponent("a/b.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a/up").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("out").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "a")
        return (root, outside)
    }

    @Test(arguments: ["/etc", "~/x", "../x", "a/../a", "./a", "a/./b.txt", "a\0b"])
    func remotePathsAreRelativeWithoutDots(_ path: String) {
        #expect(ThreadFileSystem.resolve(path, in: "/tmp") == .failure(.invalidPath))
    }

    @Test func pathsResolveInsideTheRootAndNeverThroughAnEscapeOrALoop() throws {
        let (root, outside) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        #expect(ThreadFileSystem.resolve("", in: root.path) == .success(root.path))
        #expect(ThreadFileSystem.resolve("a//b.txt/", in: root.path) == .success(root.path + "/a/b.txt"))
        #expect(ThreadFileSystem.resolve("alias/b.txt", in: root.path) == .success(root.path + "/alias/b.txt"))
        #expect(ThreadFileSystem.resolve("out", in: root.path) == .failure(.outsideRoot))
        #expect(ThreadFileSystem.resolve("a/up", in: root.path) == .failure(.outsideRoot))
        #expect(ThreadFileSystem.resolve("a/up/a/b.txt", in: root.path) == .failure(.outsideRoot))
        #expect(ThreadFileSystem.resolve("nope", in: root.path) == .failure(.notFound))
    }

    @Test func aListingHidesEscapesAndLoopsAndATextReadIsBounded() throws {
        let (root, outside) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        #expect(try ThreadFileSystem.listing("", in: root.path, showHidden: false).get().entries.map(\.name) == ["a", "alias"])
        #expect(try ThreadFileSystem.listing("a", in: root.path, showHidden: false).get().entries.map(\.name) == ["b.txt"])
        #expect(try ThreadFileSystem.listing("alias", in: root.path, showHidden: false).get().entries.first?.size == 2)
        #expect(ThreadFileSystem.text("a/b.txt", in: root.path) == .success(Data("b\n".utf8)))

        try Data(count: ThreadFilesLimits.readBytes + 1).write(to: root.appendingPathComponent("big.txt"))
        #expect(ThreadFileSystem.text("big.txt", in: root.path) == .failure(.tooLarge(Int64(ThreadFilesLimits.readBytes + 1))))
    }

    @Test func aListingIsCutToFitOneReply() throws {
        let many = (0...ThreadFilesLimits.listedEntries).map { ThreadFileEntry(name: "f\($0)", kind: .file, size: 1) }
        let cut = ThreadFileSystem.capped(many)
        #expect(cut.truncated && cut.entries.count == ThreadFilesLimits.listedEntries)

        // Names that escape to six bytes a character are counted at that.
        let escaped = (0..<1_000).map { ThreadFileEntry(name: String(repeating: "\u{1}", count: 255) + "\($0)", kind: .file) }
        let fit = ThreadFileSystem.capped(escaped)
        #expect(fit.truncated)
        #expect(try JSONEncoder().encode(fit).count <= ThreadFilesLimits.listingBytes)
        #expect(!ThreadFileSystem.capped(Array(many.prefix(3))).truncated)
    }

    @Test func textIsUTF8WithoutNULOrManyControlCharacters() {
        #expect(ThreadFileSystem.decodeText(Data("é\tok\r\n".utf8)) == "é\tok\r\n")
        #expect(ThreadFileSystem.decodeText(Data([0x61, 0x00])) == nil)
        #expect(ThreadFileSystem.decodeText(Data(repeating: 1, count: 20)) == nil)
        #expect(ThreadFileSystem.decodeText(Data([0xFF, 0xFE])) == nil)
        #expect(ThreadFileSystem.decodeText(Data()) == "")
    }
}
