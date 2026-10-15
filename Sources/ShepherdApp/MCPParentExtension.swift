import Foundation
import ShepherdSessions
import ShepherdProtocol

/// A subproject's share of its parent's MCP servers (Settings ▸ Projects, parents and subprojects;
/// docs/mcp.md): registers the parent's `.shepherd/mcp.json` servers with pi's own MCP, in a project pi
/// trusts. Loaded only for an agent whose project sits inside another project's folder.
enum MCPParentExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-mcp-parent.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-mcp-parent.ts") }
}
