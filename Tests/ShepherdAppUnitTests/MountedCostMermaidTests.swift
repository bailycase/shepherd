import Testing
import ShepherdRemote
import ShepherdUI

/// `NativeMountedCost` cannot import ShepherdUI, so it copies the language test of `SHMermaidBlock.renders`.
/// This pins the two together.
@Suite("Mounted cost and Mermaid")
struct MountedCostMermaidTests {
    @Test func aFenceCostsAsADiagramExactlyWhereTheViewDrawsOne() {
        for language in ["mermaid", " Mermaid ", "MERMAID\n", "plantuml", "swift", "", nil] {
            let costed = NativeMountedCost.block(.code("graph TD\n  A --> B", language: language)) == NativeMountedCost.mermaid
            #expect(costed == SHMermaidBlock.renders(language: language, writing: false), "\(language ?? "nil")")
        }
    }
}
