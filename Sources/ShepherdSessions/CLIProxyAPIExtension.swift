import Foundation

/// Loaded explicitly by the launcher, even for isolated drafts and children. Inert until the
/// user connects in Settings. Kept outside extensions/ so pi never discovers a second copy.
enum CLIProxyAPIExtension {
    static func install(in home: PiHome) throws -> URL {
        let path = home.directory.appendingPathComponent("shepherd-cliproxyapi.ts")
        try PiHome.write(Data(source.utf8), to: path, mode: 0o600)
        return path
    }

    static var source: String { EmbeddedExtensions.source("shepherd-cliproxyapi.ts") }
}
