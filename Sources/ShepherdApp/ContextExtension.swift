import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the per-session pi extension that keeps the old, bulky parts of a long run out of what
/// the model is sent (`shepherd-context.ts`: clips any one tool result, and in batches clears the
/// oldest tool output, tool-call contents, reasoning payloads, screenshots and hidden notices
/// before the context fills; docs/context-budget.md) from its embedded literal into the support
/// directory. It is inert without `SHEPHERD_EXT_CONTEXT`, which the app sets while Settings ▸
/// Agents ▸ Trim old tool output is on, and it changes only the request: the thread, the session
/// file and every result in them stay whole.
enum ContextExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-context.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-context.ts") }
}
