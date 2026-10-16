import Foundation
import ShepherdSessions
import ShepherdProtocol

/// Installs the opt-in, extension-owned native child runtime.
enum ChildrenExtension {
    static func installedPath() throws -> String {
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

    static var sources: [(String, String)] {
        [("shepherd-children.ts", extensionSource), ("shepherd-children-config.ts", configSource),
         ("shepherd-workflow.ts", workflowSource), ("shepherd-missions.ts", missionsSource),
         ("shepherd-children-ui.ts", uiSource), ("shepherd-inspect.mjs", InspectExtension.extensionSource)]
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-children.ts") }
    static var configSource: String { EmbeddedExtensions.source("shepherd-children-config.ts") }
    static var workflowSource: String { EmbeddedExtensions.source("shepherd-workflow.ts") }
    static var missionsSource: String { EmbeddedExtensions.source("shepherd-missions.ts") }
    static var uiSource: String { EmbeddedExtensions.source("shepherd-children-ui.ts") }

}
