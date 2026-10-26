import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the design agent's pi extension (`shepherd-design.ts`: design_read, board_write,
/// board_edit, boards_edit, board_search, board_render, board_extract, the checkpoint tools,
/// canvas_update, design_check, the comment tools, system_read and system_write) and the bundled
/// design skill it hands pi, both from embedded
/// literals into the support directory. Only an agent that draws a design loads them
/// (`SHEPHERD_DESIGN_ID`), or an ordinary thread explicitly targeting designs (`SHEPHERD_DESIGN_TOOLS`); the user's `~/.pi/agent` is never touched.
enum DesignExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-design.ts")
        try writeIfChanged(extensionSource, to: url)
        return url.path
    }

    /// `<support>/design-skill/`: `SKILL.md` and `format.md`, rewritten whenever they differ
    /// from the literals.
    static func installedSkillDirectory() throws -> String {
        let directory = ShepherdPaths.supportDirectory().appendingPathComponent("design-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeIfChanged(skillSource, to: directory.appendingPathComponent("SKILL.md"))
        try writeIfChanged(formatSource, to: directory.appendingPathComponent("format.md"))
        return directory.path
    }

    private static func writeIfChanged(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-design.ts") }
    static var skillSource: String { EmbeddedExtensions.source("design-skill/SKILL.md") }
    static var formatSource: String { EmbeddedExtensions.source("design-skill/format.md") }
}
