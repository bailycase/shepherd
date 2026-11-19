import Foundation
import ShepherdProtocol

/// Settings ▸ Experiments ▸ Computer use: `shepherd-computer-use.ts`, the driver the app ships at
/// `Contents/Helpers/ShepherdComputerUse.app`, and the folder the driver keeps its state in.
public enum ComputerUseExtension {
    public static let driverPath = "Helpers/ShepherdComputerUse.app/Contents/MacOS/computer-use"

    /// The bundled driver, or nil when this build has none (`swift test`).
    public static func driver(app: URL = Bundle.main.bundleURL) -> String? {
        let path = app.appendingPathComponent("Contents", isDirectory: true).appendingPathComponent(driverPath).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The driver's state: its tool list and runtime files, never the user's home folder.
    public static func home() -> String {
        ShepherdPaths.supportDirectory().appendingPathComponent("computer-use", isDirectory: true).path
    }

    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedExtensions.install("shepherd-lines.mjs", at: directory.appendingPathComponent("shepherd-lines.mjs"))
        let url = directory.appendingPathComponent("shepherd-computer-use.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-computer-use.ts") }
}
