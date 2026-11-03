import Foundation

/// The hooks runtime (docs/hooks.md): installed beside the pi home's files, outside extensions/ so
/// it is never discovered twice, and loaded by an agent's own pi with `-e` and
/// `SHEPHERD_HOOKS_DIR`, the folder holding `trust.json` (`<support>/hooks`; the pi home is
/// `<support>/pi`). A native subagent's pi gets no `SHEPHERD_` variable, so it runs no hooks.
public enum HooksExtension {
    static let fileName = "shepherd-hooks.ts"
    public static let environmentKey = "SHEPHERD_HOOKS_DIR"

    public static func path(in home: PiHome) -> String {
        home.directory.appendingPathComponent(fileName).path
    }

    /// `<support>/hooks`: the support folder is the pi home's parent.
    public static func directory(in home: PiHome) -> URL {
        home.directory.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
    }

    @discardableResult
    static func install(in home: PiHome) throws -> URL {
        try FileManager.default.createDirectory(at: directory(in: home), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = home.directory.appendingPathComponent(fileName)
        try PiHome.write(Data(extensionSource.utf8), to: path, mode: 0o600)
        return path
    }
    static var extensionSource: String { EmbeddedExtensions.source(fileName) }
}
