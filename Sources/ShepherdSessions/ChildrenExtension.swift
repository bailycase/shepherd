import Foundation
import ShepherdProtocol

/// Installs the opt-in, extension-owned native child runtime.
public enum ChildrenExtension {
    public static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in sources {
            let url = directory.appendingPathComponent(name)
            let source = Data(text.utf8)
            if (try? Data(contentsOf: url)) != source {
                try source.write(to: url, options: .atomic)
            }
        }
        let url = directory.appendingPathComponent("shepherd-children.ts")
        return url.path
    }

    public static var sources: [(String, String)] {
        [("shepherd-lines.mjs", EmbeddedExtensions.source("shepherd-lines.mjs")),
         ("shepherd-children.ts", extensionSource), ("shepherd-children-config.ts", configSource),
         ("shepherd-workflow.ts", workflowSource), ("shepherd-missions.ts", missionsSource),
         ("shepherd-children-ui.ts", uiSource), ("shepherd-cli.ts", EmbeddedExtensions.source("shepherd-cli.ts")),
         ("shepherd-cli-client.mjs", EmbeddedExtensions.source("shepherd-cli-client.mjs")),
         ("shepherd-inspect.mjs", InspectExtension.extensionSource)]
    }
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-children.ts") }
    public static var configSource: String { EmbeddedExtensions.source("shepherd-children-config.ts") }
    public static var workflowSource: String { EmbeddedExtensions.source("shepherd-workflow.ts") }
    public static var missionsSource: String { EmbeddedExtensions.source("shepherd-missions.ts") }
    public static var uiSource: String { EmbeddedExtensions.source("shepherd-children-ui.ts") }

}
