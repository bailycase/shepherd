import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

@Suite("Built-in Shepherd UI design system")
@MainActor
struct BuiltInShepherdDesignTests {
    /// NavDesigns' card: "Shepherd UI · Built into Shepherd", its swatches the accent first (the lantern), then text, background, status.
    @Test func theBuiltInSystemIsShepherdUIWithTheBrandsFirstSwatch() throws {
        let builtIn = BuiltInShepherdDesign.builtIn()
        #expect(builtIn.info.namespace == "shepherd-built-in" && builtIn.info.title == "Shepherd UI")
        let tokens = try DesignSystemTokens.decode(try #require(builtIn.files[DesignSystemFile.tokens]))
        let swatches = DesignSystemPresentation.swatches(tokens, count: 4)
        #expect(swatches.count == 4)
        #expect(swatches.first?.light.lowercased() == "#b55400", "\(swatches)")
        #expect(builtIn.files[DesignSystemFile.stylesheet] != nil && builtIn.files[DesignSystemFile.readme] != nil)
    }

    /// A new design starts on a blank canvas unless the person has a system of their own: Shepherd UI is listed, never the default.
    @Test func aNewDesignNeverStartsInTheAppsOwnSystem() throws {
        let builtIn = DesignSystemSummary(info: BuiltInShepherdDesign.builtIn().info, builtIn: true)
        #expect(NewDesignState.defaultSystem(in: [builtIn]) == nil)
        let own = DesignSystemSummary(info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", createdAt: 1))
        #expect(NewDesignState.defaultSystem(in: [builtIn, own])?.namespace == "acme-web")
    }
}
