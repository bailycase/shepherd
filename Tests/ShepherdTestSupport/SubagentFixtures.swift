import Foundation
import ShepherdSessions
import Testing

/// Real Markdown and the shipped parser, always under a test-owned pi home. No launch or model.
public enum SubagentFixtures {
    /// The staged engine (`python3 scripts/pi_engine.py stage`) that checks the profiles. A test that needs it is skipped,
    /// saying so, where none is staged.
    private static func stagedEngine(under root: URL) throws -> BundledPiEngine {
        guard let engine = BundledPiEngine(contents: root.appendingPathComponent(".build/pi-engine")) else {
            try Test.cancel("needs the staged engine: python3 scripts/pi_engine.py stage")
        }
        return engine
    }

    public static func store(in directory: URL, populated: Bool = false, seed: Bool = true) throws -> SubagentDefinitionsStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try stagedEngine(under: root)
        let source = try String(contentsOf: root.appendingPathComponent("Extensions/shepherd-children-config.ts"), encoding: .utf8)
        let store = SubagentDefinitionsStore(pi: PiSetup(engine: .bundled(engine), home: directory.appendingPathComponent("subagents-pi")), parserSource: source)
        if seed || populated { _ = try store.snapshot() }
        if populated {
            for (file, text) in samples {
                try Data(text.utf8).write(to: store.directory.appendingPathComponent(file))
            }
        }
        return store
    }
    /// The store of a host's own pi home, with the staged engine to check profiles with: what a scratch host's
    /// fleet writes through, because its own `PiSetup` has no bundled engine.
    public static func store(piHome: URL) throws -> SubagentDefinitionsStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try stagedEngine(under: root)
        let source = try String(contentsOf: root.appendingPathComponent("Extensions/shepherd-children-config.ts"), encoding: .utf8)
        return SubagentDefinitionsStore(pi: PiSetup(engine: .bundled(engine), home: piHome), parserSource: source)
    }
    public static let samples = [
        "api-review.md": "---\nname: api-review\ndescription: Checks API contracts and error responses against the existing conventions.\ntools: [read, grep, find, ls]\n---\nInspect the assigned API change. Report contract and error-handling defects with paths and evidence. Do not edit files.\n",
        "test-writer.md": "---\nname: test-writer\ndescription: Adds focused tests for the change. Uses a fork of the parent's conversation.\ntools: [read, grep, find, ls, bash, edit, write]\ndefaultContext: fork\n---\nAdd focused tests for the assigned behavior. Run the relevant checks and return the result.\n",
        "reviewer-strict.md": "---\nname: reviewer-strict\ndescription: Strict review\nrunner: strict\n---\nReview the assigned change.\n"
    ]
}
