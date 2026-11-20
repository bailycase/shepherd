import Foundation

/// The pi extensions and node scripts Shepherd ships, read from this module's resource bundle.
///
/// `Extensions/` at the repository root is the one copy: `Sources/ShepherdSessions/Extensions` is a
/// symlink to it, declared as a resource, so SwiftPM and Xcode both copy the files into
/// `Shepherd_ShepherdSessions.bundle`. Editing a `.ts` file is the whole change; nothing is synced.
public enum EmbeddedExtensions {
    private static let bundled = Result {
        try Snapshot(directory: Bundle.module.resourceURL ?? Bundle.module.bundleURL)
    }

    /// The host calls this before serving. Sparkle can replace the bundle before the host drains;
    /// the running build's installers must keep using the files that shipped with it.
    static func preload() throws {
        _ = try bundled.get()
    }

    /// The bytes of `Extensions/<name>` (`design-skill/SKILL.md` for a file in a folder).
    public static func data(_ name: String) -> Data {
        guard let snapshot = try? bundled.get(), let bytes = snapshot.data(name) else {
            preconditionFailure("Shepherd's resource bundle has no Extensions/\(name)")
        }
        return bytes
    }

    /// `data(name)` as text.
    public static func source(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }

    /// Writes `Extensions/<name>` to `url` when the file there differs, and returns `url`.
    @discardableResult
    public static func install(_ name: String, at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = data(name)
        if (try? Data(contentsOf: url)) != bytes {
            try bytes.write(to: url, options: .atomic)
        }
        return url
    }

    struct Snapshot {
        private let files: [String: Data]

        init(directory: URL) throws {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            var files: [String: Data] = [:]
            for url in urls where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.lastPathComponent] = try Data(contentsOf: url)
            }
            self.files = files
        }

        func data(_ name: String) -> Data? {
            // SwiftPM's `.process` flattens resource paths.
            files[(name as NSString).lastPathComponent]
        }
    }
}
