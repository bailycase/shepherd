import Foundation
import ShepherdProtocol

// Settings › Apps (AppsSettings, AppsAdd boards): the things a person runs while they work (a dev
// server, Storybook, the Simulator), saved in `~/.shepherd/apps.json` for every space and in a
// space's own `.shepherd/apps.json` for that space. Each file is `{"apps": [...]}`; a field a file
// leaves out takes its default, so a hand-written or older file keeps loading.

/// Reads and writes one apps file.
public enum AppsFile {
    /// Where the file sits under a home folder or a space's folder.
    public static let relativePath = ".shepherd/apps.json"

    public static func url(in folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(relativePath)
    }

    private struct Document: Codable {
        var apps: [AppDefinition]
        init(apps: [AppDefinition]) { self.apps = apps }
        init(from decoder: Decoder) throws {
            apps = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([AppDefinition].self, forKey: .apps) ?? []
        }
    }

    /// The apps in `url`: none when there is no file. Throws when the file can't be read as apps.
    public static func load(_ url: URL) throws -> [AppDefinition] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Document.self, from: data).apps
    }

    /// Writes `apps` whole, pretty-printed, making the `.shepherd` folder when needed.
    public static func save(_ apps: [AppDefinition], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Document(apps: apps)).write(to: url, options: .atomic)
    }
}
