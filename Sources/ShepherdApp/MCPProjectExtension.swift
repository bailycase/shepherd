import Foundation
import ShepherdSessions
import ShepherdProtocol

/// The one piece of MCP that runs in an agent's pi: registers the servers of a repo's `.mcp.json`
/// with pi's own MCP while Settings ▸ MCP servers ▸ Also use a repo's .mcp.json is on
/// (docs/mcp.md). pi reads only `.shepherd/mcp.json`, and only in a project it trusts.
enum MCPProjectExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-mcp-project.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-mcp-project.ts") }
}
