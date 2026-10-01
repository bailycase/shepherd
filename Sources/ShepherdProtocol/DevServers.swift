import Foundation

// The dev servers a folder offers (docs/design/side-pane-browser.md › Side pane: Browser › Nothing open): the package.json
// scripts that serve an app, and the port each most likely serves on. Pure reading of files, shared
// by the Mac app (a local thread's folder) and a host's server, which answers a remote viewer's
// `RemoteAgentQuery.devServers` for the thread's folder on its own disk.

/// The package manager a repository uses, from its lockfile.
public enum PackageManager: String, Sendable {
    case pnpm, yarn, bun, npm

    public static let lockfiles: [(String, PackageManager)] = [
        ("pnpm-lock.yaml", .pnpm), ("yarn.lock", .yarn), ("bun.lockb", .bun), ("bun.lock", .bun), ("package-lock.json", .npm),
    ]

    /// The first lockfile among `names` says; nil without one.
    public static func from(lockfiles names: Set<String>) -> PackageManager? {
        lockfiles.first { names.contains($0.0) }?.1
    }

    /// "pnpm dev", "yarn dev", "bun run dev", "npm run dev" ("npm start" for start).
    public func command(_ script: String) -> String {
        switch self {
        case .pnpm: "pnpm \(script)"
        case .yarn: "yarn \(script)"
        case .bun: "bun run \(script)"
        case .npm: script == "start" ? "npm start" : "npm run \(script)"
        }
    }
}

/// A package.json script that serves the app, as Nothing open offers it.
public struct DevServer: Codable, Hashable, Identifiable, Sendable {
    public let script: String
    public let command: String
    /// The package's name, if it has one.
    public let packageName: String?
    /// The folder the script runs in (a path on the machine that found it).
    public let directory: String
    /// Where its package.json is, relative to the repository ("package.json", "apps/web/package.json").
    public let manifest: String
    /// The port it most likely serves on, from its flags or its tool's default.
    public let port: Int?

    public init(script: String, command: String, packageName: String?, directory: String, manifest: String, port: Int?) {
        self.script = script
        self.command = command
        self.packageName = packageName
        self.directory = directory
        self.manifest = manifest
        self.port = port
    }

    public var id: String { directory + "#" + script }

    /// "from package.json · acme-web".
    public var detail: String { "from \(manifest)" + (packageName.map { " · \($0)" } ?? "") }

    /// The page it serves, once it is up.
    public var url: URL? { port.flatMap { URL(string: "http://localhost:\($0)") } }
}

public enum DevServerDiscovery {
    /// The scripts that serve an app, in the order they are offered.
    public static let scripts = ["dev", "start", "serve", "preview"]
    /// Folders one level down that hold a monorepo's apps.
    public static let appFolders = ["apps"]
    public static let maxServers = 6

    /// The dev servers in `root`'s package.json, then in each `apps/*/package.json`. Reads files;
    /// run it off the main thread and off a server's queue.
    public static func find(in root: URL, fileManager: FileManager = .default) -> [DevServer] {
        var manifests: [(URL, String)] = [(root, "package.json")]
        for folder in appFolders {
            let parent = root.appendingPathComponent(folder, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: parent.path))?.sorted() ?? []
            for name in names where !name.hasPrefix(".") {
                manifests.append((parent.appendingPathComponent(name, isDirectory: true), "\(folder)/\(name)/package.json"))
            }
        }
        let rootLocks = lockfiles(in: root, fileManager: fileManager)
        var result: [DevServer] = []
        for (directory, manifest) in manifests {
            guard let data = fileManager.contents(atPath: directory.appendingPathComponent("package.json").path) else { continue }
            let manager = PackageManager.from(lockfiles: lockfiles(in: directory, fileManager: fileManager))
                ?? PackageManager.from(lockfiles: rootLocks) ?? .npm
            result += servers(packageJSON: data, directory: directory, manifest: manifest, manager: manager)
            if result.count >= maxServers { break }
        }
        return Array(result.prefix(maxServers))
    }

    private static func lockfiles(in directory: URL, fileManager: FileManager) -> Set<String> {
        Set(PackageManager.lockfiles.map(\.0).filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) })
    }

    /// The serving scripts one package.json declares.
    public static func servers(packageJSON data: Data, directory: URL, manifest: String, manager: PackageManager) -> [DevServer] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        let name = json["name"] as? String
        return Self.scripts.compactMap { script in
            guard let body = scripts[script] as? String, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return DevServer(script: script, command: manager.command(script), packageName: name?.isEmpty == false ? name : nil,
                             directory: directory.path, manifest: manifest, port: port(script: script, body: body))
        }
    }

    /// The port a script serves on: its `--port`, `-p` or `PORT=`, else its tool's default.
    public static func port(script: String, body: String) -> Int? {
        if let explicit = explicitPort(body) { return explicit }
        let words = body.lowercased()
        func has(_ tool: String) -> Bool {
            words.range(of: "(^|[\\s/&;|(])\(NSRegularExpression.escapedPattern(for: tool))($|[\\s;&|)])", options: .regularExpression) != nil
        }
        if has("vite") || has("svelte-kit") || has("remix vite:dev") { return (has("preview") || script == "preview") ? 4173 : 5173 }
        if has("astro") { return 4321 }
        if has("ng") { return 4200 }
        if has("storybook") { return 6006 }
        if has("parcel") { return 1234 }
        if has("gatsby") { return 8000 }
        if has("webpack-dev-server") || has("webpack") || has("http-server") || has("eleventy") { return 8080 }
        if has("hugo") { return 1313 }
        if has("expo") { return 8081 }
        if has("next") || has("react-scripts") || has("nuxt") || has("nuxi") || has("remix") || has("docusaurus") || has("serve") {
            return 3000
        }
        return nil
    }

    private static func explicitPort(_ body: String) -> Int? {
        let patterns = ["--port[= ]+(\\d{2,5})", "(?:^|\\s)-p[= ]+(\\d{2,5})", "PORT=(\\d{2,5})"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range(at: 1), in: body), let port = Int(body[range]), (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }
}
