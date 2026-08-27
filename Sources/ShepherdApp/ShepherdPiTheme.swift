import Foundation
import ShepherdProtocol

/// Materializes the active Shepherd theme for external tools. Pi watches the
/// generated JSON, while Neovim watches the adjacent Basalt variant marker.
enum ShepherdPiTheme {
    static let name = "basalt"
    private static let filename = "shepherd-active-theme.json"
    static let variantFilename = "shepherd-active-theme"

    private struct Document: Encodable {
        let schema = "https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json"
        let name: String
        let colors: ShepherdTheme.PiColors

        enum CodingKeys: String, CodingKey {
            case schema = "$schema"
            case name
            case colors
        }
    }

    static func installedPath(
        for theme: ShepherdTheme,
        directory: URL = ShepherdPaths.supportDirectory()
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(filename)
        let data = try encodedData(for: theme)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }

        let variantURL = directory.appendingPathComponent(variantFilename)
        let variantData = Data("\(theme.id)\n".utf8)
        if (try? Data(contentsOf: variantURL)) != variantData {
            try variantData.write(to: variantURL, options: .atomic)
        }

        return url.path
    }

    static func encodedData(for theme: ShepherdTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Document(name: name, colors: theme.pi))
        data.append(0x0A)
        return data
    }
}
