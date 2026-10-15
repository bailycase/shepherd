import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the per-session pi extension behind an agent's browser tools (`shepherd-browser.ts`:
/// browser_open, browser_read, browser_click, …) from its embedded literal into the support
/// directory (docs/browser.md). It is inert without `SHEPHERD_EXT_BROWSER`, in a native subagent
/// and in a design's agent.
enum BrowserExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-browser.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-browser.ts") }
}
