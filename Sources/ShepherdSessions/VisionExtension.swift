import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that lets a model which cannot view images work from
/// a description of each one (`shepherd-vision.ts`: in pi's `context` event it swaps every
/// image in what the model is sent for words from Settings ▸ Agents ▸ Image reading model, or
/// the cheapest signed-in model that takes images) from its embedded literal into the support
/// directory. It is inert without `SHEPHERD_EXT_VISION`, and it changes only the request: the
/// thread and the session file keep the real image.
public enum VisionExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-vision.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-vision.ts") }
}
