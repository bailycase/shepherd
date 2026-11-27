import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

@Suite("Built-in Shepherd UI design system")
struct BuiltInShepherdDesignTests {
    /// NavDesigns' card: "Shepherd UI · Built into Shepherd", its swatches the accent first (the lantern), then text, background, status.
    @Test func theBuiltInSystemIsShepherdUIWithTheBrandsFirstSwatch() throws {
        let builtIn = BuiltInShepherdDesign.builtIn()
        #expect(builtIn.info.namespace == "shepherd-design" && builtIn.info.title == "Shepherd UI")
        let tokens = try DesignSystemTokens.decode(try #require(builtIn.files[DesignSystemFile.tokens]))
        let swatches = DesignSystemPresentation.swatches(tokens, count: 4)
        #expect(swatches.count == 4)
        #expect(swatches.first?.light.lowercased() == "#b55400", "\(swatches)")
        #expect(builtIn.files[DesignSystemFile.stylesheet] != nil && builtIn.files[DesignSystemFile.readme] != nil)
    }
}
