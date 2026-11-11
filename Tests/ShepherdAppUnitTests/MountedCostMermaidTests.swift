import Testing
import ShepherdRemote
@testable import ShepherdUI
import SwiftUI

/// `NativeMountedCost` cannot import ShepherdUI, so it copies the language tests of `SHMermaidBlock.renders` and
/// `SHHTMLBlock.renders`.
/// This pins the two together.
@Suite("Mounted cost and Mermaid")
struct MountedCostMermaidTests {
    @Test func aFenceCostsAsADiagramExactlyWhereTheViewDrawsOne() {
        for language in ["mermaid", " Mermaid ", "MERMAID\n", "plantuml", "swift", "", nil] {
            let costed = NativeMountedCost.block(.code("graph TD\n  A --> B", language: language)) == NativeMountedCost.mermaid
            #expect(costed == SHMermaidBlock.renders(language: language, writing: false), "\(language ?? "nil")")
        }
        for language in ["html-render", " HTML-Render\n", "html", nil] {
            let costed = NativeMountedCost.block(.code("<p>hi</p>", language: language)) == NativeMountedCost.mermaid
            #expect(costed == SHHTMLBlock<EmptyView>.renders(language: language, pages: true), "\(language ?? "nil")")
        }
    }
}
