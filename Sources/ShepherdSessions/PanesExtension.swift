import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that lets an agent drive its own Shepherd
/// terminals (open, run, read, focus, close), message other threads and manage automations.
public enum PanesExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedExtensions.install("shepherd-lines.mjs", at: directory.appendingPathComponent("shepherd-lines.mjs"))
        let url = directory.appendingPathComponent("shepherd-panes.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-panes.ts") }
}
