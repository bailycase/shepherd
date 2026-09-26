import Foundation
import Testing
import ShepherdProtocol
import ShepherdUI
@testable import ShepherdApp

/// Night Watch as a built-in design system: generated from ShepherdUI's tokens, complete for
/// every role in both variants, and a system a design can install as it is.
@Suite("Night Watch design system")
struct NightWatchSystemTests {
    /// A variant's roles as their Codable keys (read apart from the generator, which walks the
    /// struct): role → hex.
    static func roles<T: Encodable>(_ value: T) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try #require(object as? [String: String])
    }

    @Test func everyColorRoleIsATokenWithItsLightAndDarkValue() throws {
        let theme = ThemeDefinition.nightWatch
        let tokens = NightWatchSystem.tokens(theme)
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
                let token = try #require(byName["--" + group.prefix + NightWatchSystem.kebab(role)], "no token for \(role)")
                #expect(token.value == light && token.dark == group.dark[role], "\(role)")
            }
        }
        #expect(tokens.colors.count == expected, "nothing but the roles")
        #expect(byName["--bg-base"] != nil && byName["--text-on-lantern"] != nil && byName["--syn-keyword"] != nil)
    }

    @Test func theRampAndScalesAreShepherdsOwn() {
        let tokens = NightWatchSystem.tokens()
        #expect(tokens.type.map(\.name) == NWTextStyle.allCases.map { "\($0)" })
        for style in NWTextStyle.allCases {
            let token = tokens.type.first { $0.name == "\(style)" }
            #expect(token?.size == Double(style.size) && token?.lineHeight == Double(style.lineHeight))
            #expect(token?.family == (style.isMonospaced ? NWFonts.monoFamily : NWFonts.sansFamily))
        }
        #expect(tokens.type.first { $0.name == "display" }?.weight == 600 && tokens.type.first { $0.name == "body" }?.weight == 400)
        #expect(tokens.spacing.map(\.px) == [NW.Space.xxs, NW.Space.xs, NW.Space.s, NW.Space.m, NW.Space.l, NW.Space.xl,
                                             NW.Space.xxl, NW.Space.xxxl].map(Double.init))
        #expect(tokens.radii.map(\.px) == [NW.Radius.xs, NW.Radius.s, NW.Radius.m, NW.Radius.l].map(Double.init))
        #expect(tokens.fonts.map(\.family) == [NWFonts.sansFamily, NWFonts.monoFamily])
    }

    @Test func theBuiltInIsASoundSystemADesignCanInstall() throws {
        let builtIn = NightWatchSystem.builtIn()
        #expect(builtIn.info.namespace == "night-watch" && builtIn.info.title == "Night Watch")
        #expect(Set(builtIn.files.keys) == [DesignSystemFile.tokens, DesignSystemFile.stylesheet, DesignSystemFile.readme])
        #expect(builtIn.files.keys.allSatisfy(DesignSystemFile.isPath))
        let tokens = try DesignSystemTokens.decode(try #require(builtIn.files[DesignSystemFile.tokens]))
        #expect(tokens == NightWatchSystem.tokens() && tokens.problems().isEmpty)
        let css = String(decoding: try #require(builtIn.files[DesignSystemFile.stylesheet]), as: UTF8.self)
        let declared = DesignSystemCSS.declarations(css, file: "tokens.css")
        // Every color twice (light, then dark), and every step once.
        for color in tokens.colors {
            #expect(declared.filter { $0.name == color.name }.map(\.value) == [color.value, color.dark].compactMap { $0 })
        }
        #expect(declared.contains { $0.name == "--space-xl" && $0.value == "16px" })
        let readme = String(decoding: try #require(builtIn.files[DesignSystemFile.readme]), as: UTF8.self)
        #expect(readme.contains("ds/night-watch/tokens.css") && readme.contains("data-theme=\"dark\""))
    }
}
