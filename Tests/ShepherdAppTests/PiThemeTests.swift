import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

@Suite("Shepherd pi theming")
@MainActor
struct PiThemeTests {
    private static let requiredColorKeys: Set<String> = [
        "accent", "border", "borderAccent", "borderMuted", "success", "error", "warning",
        "muted", "dim", "text", "thinkingText",
        "selectedBg", "scrollbarThumb", "searchMatchBg", "searchMatchText",
        "userMessageBg", "userMessageText", "customMessageBg", "customMessageText",
        "customMessageLabel", "toolPendingBg", "toolSuccessBg", "toolErrorBg", "toolTitle",
        "toolOutput",
        "mdHeading", "mdLink", "mdLinkUrl", "mdCode", "mdCodeBlock", "mdCodeBlockBorder",
        "mdQuote", "mdQuoteBorder", "mdHr", "mdListBullet",
        "toolDiffAdded", "toolDiffRemoved", "toolDiffContext",
        "syntaxComment", "syntaxKeyword", "syntaxFunction", "syntaxVariable", "syntaxString",
        "syntaxNumber", "syntaxType", "syntaxOperator", "syntaxPunctuation",
        "thinkingOff", "thinkingMinimal", "thinkingLow", "thinkingMedium", "thinkingHigh",
        "thinkingXhigh", "thinkingMax", "bashMode",
    ]

    @Test func everyThemeGeneratesCompleteValidPiColors() throws {
        for theme in ShepherdTheme.all {
            let data = try ShepherdPiTheme.encodedData(for: theme)
            let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(document["name"] as? String == ShepherdPiTheme.name)
            let colors = try #require(document["colors"] as? [String: String])
            #expect(Set(colors.keys) == Self.requiredColorKeys)
            for value in colors.values {
                // Pi uses an empty string to inherit Ghostty's configured
                // foreground; every explicit color remains six-digit RGB.
                #expect(
                    value.isEmpty
                        || value.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
                )
            }
        }
    }

    @Test func installingThemeWritesActiveVariant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-pi-theme-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try ShepherdPiTheme.installedPath(for: .basaltDark, directory: directory)
        let variantURL = directory.appendingPathComponent(ShepherdPiTheme.variantFilename)
        #expect(try String(contentsOf: variantURL, encoding: .utf8) == "basalt-dark\n")

        _ = try ShepherdPiTheme.installedPath(for: .basaltLight, directory: directory)
        #expect(try String(contentsOf: variantURL, encoding: .utf8) == "basalt-light\n")
    }

    @Test func basaltLightToolBackgroundsRemainDistinct() throws {
        let background = ShepherdTheme.basaltLight.terminal.background
        let toolBackgrounds = [
            ShepherdTheme.basaltLight.pi.toolPendingBg,
            ShepherdTheme.basaltLight.pi.toolSuccessBg,
            ShepherdTheme.basaltLight.pi.toolErrorBg,
        ]

        for toolBackground in toolBackgrounds {
            #expect(try rgbDistance(background, toolBackground) >= 25)
        }
        for first in toolBackgrounds.indices {
            for second in toolBackgrounds.indices where second > first {
                #expect(try rgbDistance(toolBackgrounds[first], toolBackgrounds[second]) >= 5)
            }
        }
    }

    @Test func basaltLightPiEditorUsesOneRestrainedAccent() {
        let colors = ShepherdTheme.basaltLight.pi
        let activeBorders = [
            colors.thinkingMinimal,
            colors.thinkingLow,
            colors.thinkingMedium,
            colors.thinkingHigh,
            colors.thinkingXhigh,
            colors.thinkingMax,
        ]

        #expect(Set(activeBorders) == Set([colors.accent]))
        #expect(colors.thinkingText == colors.muted)
    }

    @Test func launchCommandForcesTheGeneratedTheme() {
        let command = StatusExtension.command(
            agentID: AgentID(rawValue: "11111111-1111-1111-1111-111111111111"),
            piSessionID: "11111111-1111-1111-1111-111111111111",
            socketPath: "/tmp/shepherd.sock",
            extensionPath: "/tmp/status.ts",
            themeExtensionPath: "/tmp/theme.ts",
            panesExtensionPath: "/tmp/panes.ts",
            reviewExtensionPath: "/tmp/review.ts",
            subagentsExtensionPath: "/tmp/subagents.ts",
            piThemePath: "/tmp/theme file.json",
            piThemeName: ShepherdPiTheme.name,
            model: nil,
            thinking: nil,
            initialPrompt: nil
        )

        let shellCommand = command.argv[3]
        #expect(shellCommand.contains("--theme '/tmp/theme file.json'"))
        #expect(shellCommand.contains("--use-theme '\(ShepherdPiTheme.name)'"))
        #expect(shellCommand.contains("-e '/tmp/theme.ts'"))
        #expect(shellCommand.contains("-e '/tmp/review.ts'"))
        #expect(command.env["SHEPHERD_EXT_THEME"] == "/tmp/theme.ts")
        #expect(command.env["SHEPHERD_PI_THEME_PATH"] == "/tmp/theme file.json")
        #expect(command.env["SHEPHERD_PI_THEME_NAME"] == ShepherdPiTheme.name)
    }

    private func rgbDistance(_ lhs: String, _ rhs: String) throws -> Double {
        let left = try rgb(lhs)
        let right = try rgb(rhs)
        let red = left.red - right.red
        let green = left.green - right.green
        let blue = left.blue - right.blue
        return (red * red + green * green + blue * blue).squareRoot()
    }

    private func rgb(_ hex: String) throws -> (red: Double, green: Double, blue: Double) {
        let normalized = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = try #require(UInt32(normalized, radix: 16))
        return (
            Double((value >> 16) & 0xFF),
            Double((value >> 8) & 0xFF),
            Double(value & 0xFF)
        )
    }

    @Test func embeddedExtensionsMatchCanonicalSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let copies: [(String, String)] = [
            ("shepherd-status.ts", StatusExtension.extensionSource),
            ("shepherd-theme.ts", ThemeExtension.extensionSource),
            ("shepherd-namer.ts", NamerExtension.extensionSource),
            ("shepherd-panes.ts", PanesExtension.extensionSource),
            ("shepherd-review.ts", ReviewExtension.extensionSource),
            ("shepherd-subagents.ts", SubagentsExtension.extensionSource),
            ("shepherd-inspect.mjs", InspectExtension.extensionSource),
        ]

        for (filename, embedded) in copies {
            let canonical = try String(
                contentsOf: root.appendingPathComponent("Extensions").appendingPathComponent(filename),
                encoding: .utf8
            )
            #expect(embedded == canonical, "Embedded copy drifted from Extensions/\(filename)")
        }
    }
}
