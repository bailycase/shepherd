import Foundation

/// The canonical bridge lives in Extensions/shepherd-project-mcp-sign-in.mjs.
enum ProjectMCPScript {
    static func install(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("shepherd-project-mcp-sign-in.mjs")
        let data = Data(source.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }
    static var source: String { EmbeddedExtensions.source("shepherd-project-mcp-sign-in.mjs") }
}
