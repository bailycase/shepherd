import Testing
@testable import ShepherdUI

@Suite("Mermaid components")
@MainActor
struct MermaidComponentTests {
    @Test func routingAndStreaming() {
        #expect(NWMermaidBlock.renders(language: " Mermaid ", writing: false))
        #expect(!NWMermaidBlock.renders(language: "mermaid", writing: true))
        #expect(!NWMermaidBlock.renders(language: "swift", writing: false))
        #expect(!NWMermaidBlock.renders(language: nil, writing: false))
        let blocks: [NWProseBlock] = [.code("finished", language: "mermaid"),
            .quote([.list(ordered: false, start: 1, items: [.init(text: "", children: [.code("writing", language: "mermaid")])])])]
        #expect(NWProseBlock.lastCodePath(blocks) == [1, 0, 0, 0])
        #expect(NWProseBlock.lastCodePath([.code("same", language: "mermaid"), .code("same", language: "mermaid")]) == [1])
    }
}
