import Foundation
import ShepherdProtocol

/// The active variant marker watched by external editors such as Neovim.
enum ShepherdThemeMarker {
    static let filename = "shepherd-active-theme"

    static func install(
        for theme: ShepherdTheme,
        directory: URL = ShepherdPaths.supportDirectory()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let data = Data("\(theme.id)\n".utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
    }
}
