import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs an ordinary thread's design references tools (`shepherd-design-refs.ts`: design_get, design_note)
/// from its embedded literal into the support directory (docs/designs.md › Design references).
/// A design's agent never loads it. The tools register themselves only once the thread holds a
/// reference (`SHEPHERD_DESIGN_REFS`), so a thread without one carries nothing of them.
enum DesignReferencesExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-design-refs.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-design-refs.ts") }
}
