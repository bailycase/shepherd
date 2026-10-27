import Testing
@testable import ShepherdUI

@Suite("Mermaid components")
@MainActor
struct MermaidComponentTests {
    @Test func routingAndStreaming() {
        #expect(SHMermaidBlock.renders(language: " Mermaid ", writing: false))
        #expect(!SHMermaidBlock.renders(language: "mermaid", writing: true))
        #expect(!SHMermaidBlock.renders(language: "swift", writing: false))
        #expect(!SHMermaidBlock.renders(language: nil, writing: false))
        let blocks: [SHProseBlock] = [.code("finished", language: "mermaid"),
            .quote([.list(ordered: false, start: 1, items: [.init(text: "", children: [.code("writing", language: "mermaid")])])])]
        #expect(SHProseBlock.lastCodePath(blocks) == [1, 0, 0, 0])
        #expect(SHProseBlock.lastCodePath([.code("same", language: "mermaid"), .code("same", language: "mermaid")]) == [1])
    }
}
