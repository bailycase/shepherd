import Foundation

/// The pi extensions and node scripts Shepherd ships, read from this module's resource bundle.
///
/// `Extensions/` at the repository root is the one copy: `Sources/ShepherdSessions/Extensions` is a
/// symlink to it, declared as a resource, so SwiftPM and Xcode both copy the files into
/// `Shepherd_ShepherdSessions.bundle`. Editing a `.ts` file is the whole change; nothing is synced.
public enum EmbeddedExtensions {
    /// The bytes of `Extensions/<name>` (`design-skill/SKILL.md` for a file in a folder).
    public static func data(_ name: String) -> Data {
        // `.process` flattens resource paths, including design-skill/SKILL.md and format.md.
        guard let url = Bundle.module.url(forResource: (name as NSString).lastPathComponent, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("Shepherd's resource bundle has no Extensions/\(name)")
        }
        return data
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
}
