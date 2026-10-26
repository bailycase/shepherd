import Foundation
import Testing
import ShepherdTestSupport
import ShepherdProtocol
import ShepherdUI
@testable import ShepherdApp

/// Shepherd Design as a built-in design system: generated from ShepherdUI's tokens, complete for
/// every role in both variants, and a system a design can install as it is.
@Suite("Shepherd Design design system")
struct ShepherdDesignSystemTests {
    /// A variant's roles as their Codable keys (read apart from the generator, which walks the
    /// struct): role → hex.
    static func roles<T: Encodable>(_ value: T) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try #require(object as? [String: String])
    }

    @Test func everyColorRoleIsATokenWithItsLightAndDarkValue() throws {
        let theme = ThemeDefinition.shepherdDesign
        let tokens = ShepherdDesignSystem.tokens(theme)
        let byName = Dictionary(uniqueKeysWithValues: tokens.colors.map { ($0.name, $0) })
        let groups: [(prefix: String, light: [String: String], dark: [String: String])] = [
            ("", try Self.roles(theme.light.colors), try Self.roles(theme.dark.colors)),
            ("syn-", try Self.roles(theme.light.syntax), try Self.roles(theme.dark.syntax)),
        ]
        var expected = 0
        for group in groups {
            #expect(Set(group.light.keys) == Set(group.dark.keys))
            for (role, light) in group.light {
                expected += 1
                let token = try #require(byName["--" + group.prefix + ShepherdDesignSystem.kebab(role)], "no token for \(role)")
                #expect(token.value == light && token.dark == group.dark[role], "\(role)")
            }
        }
        #expect(tokens.colors.count == expected, "nothing but the roles")
        #expect(byName["--bg-base"] != nil && byName["--text-on-lantern"] != nil && byName["--syn-keyword"] != nil)
    }

    @Test func theRampAndScalesAreShepherdsOwn() {
        let tokens = ShepherdDesignSystem.tokens()
        #expect(tokens.type.map(\.name) == SHTextStyle.allCases.map { "\($0)" })
        for style in SHTextStyle.allCases {
            let token = tokens.type.first { $0.name == "\(style)" }
            #expect(token?.size == Double(style.size) && token?.lineHeight == Double(style.lineHeight))
            #expect(token?.family == (style.isMonospaced ? SHFonts.monoFamily : SHFonts.sansFamily))
        }
        #expect(tokens.type.first { $0.name == "display" }?.weight == 600 && tokens.type.first { $0.name == "body" }?.weight == 400)
        #expect(tokens.spacing.map(\.px) == [SH.Space.xxs, SH.Space.xs, SH.Space.s, SH.Space.m, SH.Space.l, SH.Space.xl,
                                             SH.Space.xxl, SH.Space.xxxl].map(Double.init))
        #expect(tokens.radii.map(\.px) == [SH.Radius.xs, SH.Radius.s, SH.Radius.m, SH.Radius.l].map(Double.init))
        #expect(tokens.fonts.map(\.family) == [SHFonts.sansFamily, SHFonts.monoFamily])
    }

    @Test func theBuiltInIsASoundSystemADesignCanInstall() throws {
        let builtIn = ShepherdDesignSystem.builtIn()
        #expect(builtIn.info.namespace == "shepherd-design" && builtIn.info.title == "Shepherd Design")
        #expect(Set(builtIn.files.keys) == [DesignSystemFile.tokens, DesignSystemFile.stylesheet, DesignSystemFile.readme])
        #expect(builtIn.files.keys.allSatisfy(DesignSystemFile.isPath))
        let tokens = try DesignSystemTokens.decode(try #require(builtIn.files[DesignSystemFile.tokens]))
        #expect(tokens == ShepherdDesignSystem.tokens() && tokens.problems().isEmpty)
        let css = String(decoding: try #require(builtIn.files[DesignSystemFile.stylesheet]), as: UTF8.self)
        let declared = DesignSystemCSS.declarations(css, file: "tokens.css")
        // Every color twice (light, then dark), and every step once.
        for color in tokens.colors {
            #expect(declared.filter { $0.name == color.name }.map(\.value) == [color.value, color.dark].compactMap { $0 })
        }
        #expect(declared.contains { $0.name == "--space-xl" && $0.value == "16px" })
        let readme = String(decoding: try #require(builtIn.files[DesignSystemFile.readme]), as: UTF8.self)
        #expect(readme.contains("ds/shepherd-design/tokens.css") && readme.contains("data-theme=\"dark\""))
    }
}
