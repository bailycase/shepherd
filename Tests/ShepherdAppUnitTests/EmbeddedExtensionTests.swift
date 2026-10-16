import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// pi loads the copies the app installs from `Extensions/`, which ships in ShepherdSessions'
/// resource bundle through a symlink. These tests fail when a file is missing from the bundle,
/// when it is not the repository's copy, or when an installer stops writing it.
@Suite("Embedded extensions")
struct EmbeddedExtensionTests {
    private static let extensionsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions", isDirectory: true)

    /// Every file under Extensions/, as the installers name it.
    private static var canonical: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: extensionsDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".ts") || $0.hasSuffix(".mjs") }.sorted()
            + ["design-skill/SKILL.md", "design-skill/format.md"]
    }

    @Test(arguments: canonical)
    func theBundledCopyIsByteIdenticalToTheRepositorysFile(name: String) throws {
        let repository = try Data(contentsOf: Self.extensionsDirectory.appendingPathComponent(name))
        #expect(EmbeddedExtensions.data(name) == repository, "the bundle's Extensions/\(name) is not the repository's")
    }

    @Test func installingWritesTheFileOnceAndRewritesItWhenItDiffers() throws {
        let directory = try makeScratchDirectory()
        let url = directory.appendingPathComponent("shepherd-panes.ts")
        try EmbeddedExtensions.install("shepherd-panes.ts", at: url)
        let installed = try Data(contentsOf: url)
        #expect(installed == EmbeddedExtensions.data("shepherd-panes.ts"))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try EmbeddedExtensions.install("shepherd-panes.ts", at: url)
        let unchanged = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == unchanged, "an identical file is not rewritten")
        try Data("stale".utf8).write(to: url)
        try EmbeddedExtensions.install("shepherd-panes.ts", at: url)
        #expect(try Data(contentsOf: url) == installed, "a drifted file is put back")
    }

    /// Terminals are tabs: the tools an agent drives them with are `terminal_*`, and the old
    /// `pane_*` names are gone with no alias (`Tests/Extensions/terminal-tools.test.mjs` runs the
    /// tools and reads every string an agent is shown about them).
    @Test func thePanesExtensionRegistersTerminalToolsAndNoPaneTools() throws {
        let source = PanesExtension.extensionSource
        let registered = source.matches(of: #/name: "([a-z_]+)",/#).map { String($0.output.1) }
        for name in ["terminal_list", "terminal_open", "terminal_run", "terminal_read", "terminal_focus", "terminal_close"] {
            #expect(registered.contains(name), "\(name) is registered")
        }
        #expect(!registered.contains { $0.hasPrefix("pane_") }, "no pane_* tool, and no alias for one")
        #expect(!source.contains("pane_"), "no text names a pane_* tool")
        #expect(!source.contains("relativeTo") && !source.contains("axis"), "terminal_open names no place to split")
    }
}
