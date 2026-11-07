import Foundation
import ShepherdProtocol

/// Installs an ordinary thread's design references tools (`shepherd-design-refs.ts`: design_get, design_note)
/// from its embedded literal into the support directory.
/// A design's agent never loads it. The tools register themselves only once the thread holds a
/// reference (`SHEPHERD_DESIGN_REFS`), so a thread without one carries nothing of them.
public enum DesignReferencesExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedExtensions.install("shepherd-lines.mjs", at: directory.appendingPathComponent("shepherd-lines.mjs"))
        let url = directory.appendingPathComponent("shepherd-design-refs.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-design-refs.ts") }
}
