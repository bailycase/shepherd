import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that hands pi Shepherd's root instructions
/// (Settings ▸ Instructions): `AGENTS.md` as a context file right after pi's own root one, and
/// `APPEND_SYSTEM.md` added to pi's system prompt. Every agent loads it; with no files it does
/// nothing.
public enum InstructionsExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedExtensions.install("shepherd-lines.mjs", at: directory.appendingPathComponent("shepherd-lines.mjs"))
        let url = directory.appendingPathComponent("shepherd-instructions.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-instructions.ts") }
}
