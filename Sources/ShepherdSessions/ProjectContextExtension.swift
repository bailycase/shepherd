import Foundation
import ShepherdCore
import ShepherdProtocol

public enum ProjectContextExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedExtensions.install("shepherd-lines.mjs", at: directory.appendingPathComponent("shepherd-lines.mjs"))
        let url = directory.appendingPathComponent("shepherd-project-context.ts")
        let data = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url.path
    }

    public static func context(_ project: Project) throws -> String {
        struct Context: Encodable { var projectID: ProjectID }
        return String(decoding: try JSONEncoder().encode(Context(projectID: project.id)), as: UTF8.self)
    }

    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-project-context.ts") }
}
