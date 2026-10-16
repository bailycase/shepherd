import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the per-session pi extension that lets an agent drive its own Shepherd
/// terminals (open, run, read, focus, close), message other threads and manage automations.
enum PanesExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-panes.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-panes.ts") }
}
