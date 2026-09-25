import Foundation
import Testing
@testable import ShepherdApp

/// pi loads the copies the app writes from embedded Swift literals, and `installedPath()`
/// rewrites the installed file whenever content differs — so a literal that drifts from its
/// canonical `Extensions/*` source ships a bug.
@Suite("Embedded extensions")
struct EmbeddedExtensionTests {
    private static let extensionsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions", isDirectory: true)

    /// Every embedded literal paired with its canonical file.
    private static let embedded: [String: String] = [
        "shepherd-status.ts": StatusExtension.extensionSource,
        "shepherd-namer.ts": NamerExtension.extensionSource,
        "shepherd-panes.ts": PanesExtension.extensionSource,
        "shepherd-review.ts": ReviewExtension.extensionSource,
        "shepherd-subagents.ts": SubagentsExtension.extensionSource,
        "shepherd-children.ts": ChildrenExtension.extensionSource,
        "shepherd-children-config.ts": ChildrenExtension.configSource,
        "shepherd-children-ui.ts": ChildrenExtension.uiSource,
        "shepherd-workflow.ts": ChildrenExtension.workflowSource,
        "shepherd-missions.ts": ChildrenExtension.missionsSource,
        "shepherd-inspect.mjs": InspectExtension.extensionSource,
        "shepherd-instructions.ts": InstructionsExtension.extensionSource,
    ]

    @Test(arguments: embedded.keys.sorted())
    func theEmbeddedCopyIsByteIdenticalToTheCanonicalSource(filename: String) throws {
        let canonical = try Data(contentsOf: Self.extensionsDirectory.appendingPathComponent(filename))
        let literal = try #require(Self.embedded[filename])
        #expect(Data(literal.utf8) == canonical, "embedded copy drifted from Extensions/\(filename)")
    }

    /// A new file under Extensions/ must get an embedded copy (and a row above).
    @Test func everyCanonicalExtensionHasAnEmbeddedCopy() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.extensionsDirectory.path)
            .filter { $0.hasSuffix(".ts") || $0.hasSuffix(".mjs") }
        #expect(Set(files) == Set(Self.embedded.keys))
    }
}
