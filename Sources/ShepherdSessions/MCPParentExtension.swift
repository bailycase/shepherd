import Foundation
import ShepherdProtocol

/// Registers MCP servers from the host-authorized owning space or a trusted parent project.
/// The canonical extension enforces the checkout binding and project-trust rules.
public enum MCPParentExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-mcp-parent.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-mcp-parent.ts") }
}
