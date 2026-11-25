import Foundation
import ShepherdProtocol

/// Installs the opt-in, extension-owned native child runtime.
public enum ChildrenExtension {
    private static let entry = "shepherd-children.ts"
    private static let helpers = [
        "shepherd-lines.mjs", "shepherd-children-config.ts", "shepherd-workflow.ts",
        "shepherd-children-ui.ts", "shepherd-cli.ts", "shepherd-cli-client.mjs",
        "shepherd-bash.mjs", "shepherd-inspect.mjs",
    ]

    public static func installedPath() throws -> String {
        try installedPath(in: ShepherdPaths.supportDirectory(), snapshot: EmbeddedExtensions.snapshot)
    }

    static func installedPath(in directory: URL, snapshot: EmbeddedExtensions.Snapshot) throws -> String {
        for name in helpers {
            try snapshot.install(name, at: directory.appendingPathComponent(name))
        }
        // Don't publish a new entry point until all its imports have been installed.
        return try snapshot.install(entry, at: directory.appendingPathComponent(entry)).path
    }

    public static var sources: [(String, String)] {
        (helpers + [entry]).map { ($0, EmbeddedExtensions.source($0)) }
    }
    public static var extensionSource: String { EmbeddedExtensions.source(entry) }
    public static var configSource: String { EmbeddedExtensions.source("shepherd-children-config.ts") }
    public static var workflowSource: String { EmbeddedExtensions.source("shepherd-workflow.ts") }
    public static var uiSource: String { EmbeddedExtensions.source("shepherd-children-ui.ts") }

}
