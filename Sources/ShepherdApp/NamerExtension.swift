import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the per-session pi extension that proposes a short title for an
/// agent from its opening prompt and first reply, and reports it over the extension socket.
/// Only passed to agents whose name is still provisional.
enum NamerExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-namer.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-namer.ts") }
}
