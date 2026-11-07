import Foundation

// Settings › Apps (AppsSettings, AppsAdd boards): the things a person runs while they work (a dev
// server, Storybook, the Simulator), saved in `~/.shepherd/apps.json` for every space and in a
// space's own `.shepherd/apps.json` for that space. Each file is `{"apps": [...]}`; a field a file
// leaves out takes its default, so a hand-written or older file keeps loading.

/// One app: what it runs, where, and where its output and page go.
public struct AppDefinition: Codable, Hashable, Sendable, Identifiable {
    public enum Opens: String, Codable, Sendable, CaseIterable {
        /// Runs in a terminal tab, then opens `address` in the thread's Browser once it answers.
        case browser
        /// Runs in a terminal tab.
        case terminal
        /// Runs in a terminal tab and opens its own window (the Simulator, an Electron app).
        case window
    }

    /// Unique in its file: it names the app's terminal tab.
    public var name: String
    public var command: String
    /// A space's app: relative to the space's folder ("" is the folder itself). This Mac's: a
    /// path, `~` for the home folder.
    public var folder: String
    public var opens: Opens
    /// The page a browser app serves ("http://localhost:3000").
    public var address: String?
    /// A Run button in the thread header and on New thread while you are in its space.
    public var quickAction: Bool

    public var id: String { name }

    public init(name: String, command: String, folder: String = "", opens: Opens = .terminal, address: String? = nil,
                quickAction: Bool = false) {
        self.name = name
        self.command = command
        self.folder = folder
        self.opens = opens
        self.address = address
        self.quickAction = quickAction
    }

    private enum CodingKeys: String, CodingKey { case name, command, folder, opens, address, quickAction }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        // An opening this Shepherd doesn't know runs in a terminal.
        opens = (try? c.decodeIfPresent(Opens.self, forKey: .opens)) ?? .terminal
        address = try c.decodeIfPresent(String.self, forKey: .address)
        quickAction = try c.decodeIfPresent(Bool.self, forKey: .quickAction) ?? false
    }

    /// The page to open: the address when it is http(s) on any host.
    public var url: URL? {
        guard opens == .browser, let address, let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// The folder the command runs in: a space's app under `root` (the thread's folder, so a
    /// worktree thread runs its own copy); this Mac's from `home`.
    public func directory(root: String?, home: String) -> String {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        guard let root else {
            if folder.isEmpty || folder == "~" { return home }
            return folder.hasPrefix("~/") ? home + folder.dropFirst() : folder
        }
        guard !folder.isEmpty, folder != "." else { return root }
        return URL(fileURLWithPath: root).appendingPathComponent(folder).standardizedFileURL.path
    }
}

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
