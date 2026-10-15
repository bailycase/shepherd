import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

/// A design system's page (DesignSystemPage and its sibling boards) as plain values, for any system: derived
/// from the system's own tokens.json, with counts taken from the data and never written down.
@Suite("Design system reference")
@MainActor
struct DesignSystemReferenceTests {
    /// Shepherd UI as the user's system holds it: Night Watch's values, light and dark, and the page copy and
    /// components its tokens.json carries.
    private static var shepherdUI: DesignSystemTokens {
        var tokens = NightWatchSystem.tokens()
        tokens.name = "Shepherd UI"
        tokens.namespace = "shepherd-ui"
        tokens.radii = tokens.radii.map { step in
            var step = step
            if step.name == "--radius-xs" { step.extra["use"] = .string("pills, keycaps") }
            return step
        }
        tokens.components = [
            DesignSystemTokens.Component(name: "SettingsButton", specimen: "components/SettingsButton.html",
                                         export: "Shepherd.SettingsButton", extra: ["group": .string("Settings")]),
            DesignSystemTokens.Component(name: "ThreadChip", specimen: "components/ThreadChip.html",
                                         export: "Shepherd.ThreadChip", extra: ["group": .string("Chat & agents")]),
            DesignSystemTokens.Component(name: "AttachButton", export: "Shepherd.AttachButton"),
        ]
        tokens.extra["page"] = .object([
            "tagline": .string("The app’s own components and tokens. Quiet chrome around agents at work."),
            "summary": .string("Shepherd UI is what the Shepherd app draws with."),
            "source": .string("Made in Shepherd chat UI from the app’s Night Watch values."),
            "principles": .array([.object(["lead": .string("Readable measure."), "text": .string("The thread column is at most 820pt.")]),
                                  .object(["text": .string("A principle with no lead is left out.")])]),
            "voice": .object(["lead": .string("Write like an engineer handing over work."),
                              "examples": .array([.object(["say": .string("Tests failed twice. Open the log?"),
                                                           "avoid": .string("Oops! Something went wrong.")])]),
                              "rules": .array([.string("Sentence case in drawn UI.")])]),
            "sizes": .array([.object(["name": .string("control"), "value": .string("32px"), "use": .string("Buttons and popups")])]),
        ])
        return tokens
    }

    private static func reference(_ tokens: DesignSystemTokens? = shepherdUI, designs: [DesignSystemPageModel.BoardsRow] = []) -> DesignSystemReference {
        DesignSystemReference.make(title: "Shepherd UI", namespace: "shepherd-ui", tokens: tokens, designs: designs)
    }

    @Test func everyColorTokenLandsInExactlyOneGroupInTheBoardsOrder() {
        let reference = Self.reference()
        #expect(reference.colors.map(\.title) == ["Surfaces", "Lines", "Text", "Brand and state", "Syntax"])
        #expect(reference.colorCount == Self.shepherdUI.colors.count)
        #expect(Set(reference.colors.flatMap(\.rows).map(\.name)).count == Self.shepherdUI.colors.count)
        #expect(reference.colors[0].rows.map(\.name).first == "--bg-base")
        #expect(reference.colors[2].rows.map(\.name) == ["--text-primary", "--text-secondary", "--text-tertiary"])
        #expect(reference.colors[2].hint == "Measured against --bg-window")
        #expect(reference.colors[3].rows.contains { $0.name == "--text-on-lantern" }, "text on a role is brand and state")
    }

    @Test func aSystemWithItsOwnNamesKeepsEveryColorInAnOtherGroup() {
        var tokens = DesignSystemTokens(name: "Rain Admin", namespace: "rain-admin")
        tokens.colors = [DesignSystemTokens.Color(name: "--primary-main", value: "#7b61ff"),
                         DesignSystemTokens.Color(name: "--text-primary", value: "#111111"),
                         DesignSystemTokens.Color(name: "--background-default", value: "#ffffff")]
        let reference = Self.reference(tokens)
        #expect(reference.colors.map(\.title) == ["Text", "Other"])
        #expect(reference.colorCount == 3)
        let text = reference.colors[0].rows[0]
        #expect(text.lightRatio != nil, "a text color is measured against the system's background")
        #expect(reference.colors[0].hint == "Measured against --background-default")
        #expect(reference.colorsSub == "3 tokens", "no dark values: the head doesn't claim light and dark")
    }

    @Test func darkAndLightValuesAreBothKept() throws {
        let window = try #require(Self.reference().colors[0].rows.first { $0.name == "--bg-window" })
        #expect(window.dark != window.light)
        #expect(window.dark.lowercased() == "#0d0e10" && window.light.lowercased() == "#fbfbfa")
        #expect(Self.reference().colorsSub == "\(Self.shepherdUI.colors.count) tokens · light and dark")
    }

    @Test func textColorsCarryAContrastRatioAgainstWhatTheyAreReadOn() throws {
        let rows = Self.reference().colors.flatMap(\.rows)
        let measured = rows.filter { $0.lightRatio != nil }.map(\.name)
        #expect(measured.contains("--text-primary") && measured.contains("--text-on-lantern"))
        #expect(!measured.contains("--bg-window") && !measured.contains("--lantern"))
        let tertiary = try #require(rows.first { $0.name == "--text-tertiary" })
        #expect(try #require(tertiary.darkRatio) < DesignSystemReference.readable)
        let primary = try #require(rows.first { $0.name == "--text-primary" })
        #expect(try #require(primary.lightRatio) >= DesignSystemReference.readable)
        // Text on the lantern is measured on the lantern, not the window.
        let onLantern = try #require(rows.first { $0.name == "--text-on-lantern" })
        let lantern = try #require(Self.shepherdUI.colors.first { $0.name == "--lantern" })
        #expect(onLantern.lightRatio == DesignSystemReference.ratio(onLantern.light, on: lantern.value))
    }

    @Test func typeStylesGroupIntoDisplayTextAndMono() {
        let reference = Self.reference()
        #expect(reference.type.map(\.title) == ["Display", "Text", "Mono"])
        #expect(reference.typeCount == NWTextStyle.allCases.count)
        #expect(reference.type[0].rows.first?.tag == "Geist · 28 / 600")
        #expect(reference.type[2].rows.last?.uppercase == true)
        #expect(reference.type[2].rows.last?.sample == DesignSystemReference.Copy.microSample.uppercased())
        #expect(reference.typographySub == "Geist and Geist Mono · \(NWTextStyle.allCases.count) styles")
    }

    @Test func stepsComeFromTheTokensAndSayWhatTheyAreForWhenTheSystemSays() {
        let reference = Self.reference()
        #expect(reference.spacing.map(\.px) == [2, 4, 6, 8, 12, 16, 24, 32])
        #expect(reference.spacingSub == "2 to 32px")
        #expect(reference.radii.map(\.px) == [4, 6, 8, 12])
        #expect(reference.radii.first?.use == "pills, keycaps" && reference.radii.last?.use == "")
        #expect(reference.radiusSub == "4 to 12px")
    }

    @Test func thePageCopyAndSizesComeFromTheSystemsOwnTokens() {
        let reference = Self.reference()
        #expect(reference.tagline == "The app’s own components and tokens. Quiet chrome around agents at work.")
        #expect(reference.summary == "Shepherd UI is what the Shepherd app draws with.")
        #expect(reference.source == "Made in Shepherd chat UI from the app’s Night Watch values.")
        #expect(reference.principles == [.init(lead: "Readable measure.", text: "The thread column is at most 820pt.")])
        #expect(reference.voiceLead == "Write like an engineer handing over work.")
        #expect(reference.examples == [.init(say: "Tests failed twice. Open the log?", avoid: "Oops! Something went wrong.")])
        #expect(reference.voiceRules == ["Sentence case in drawn UI."])
        #expect(reference.sizes == [.init(name: "control", value: "32px", use: "Buttons and popups")])
    }

    @Test func aSystemWithoutPageCopyLeavesThoseParts() {
        var tokens = DesignSystemTokens(name: "acme-web", namespace: "acme-web")
        tokens.colors = [DesignSystemTokens.Color(name: "--accent", value: "#4f46e5")]
        tokens.spacing = [DesignSystemTokens.Length(name: "--space-4", px: 16)]
        let reference = Self.reference(tokens)
        #expect(reference.parts == [.overview, .colors, .spacing])
        #expect(reference.tagline == nil && reference.summary == nil && reference.source == nil)
        #expect(!reference.hasVoice && reference.sizes.isEmpty && reference.componentTotal == 0)
        // Nothing read yet: the page is the overview alone.
        let empty = Self.reference(nil)
        #expect(empty.parts == [.overview] && empty.tiles.isEmpty)
    }

    @Test func componentsAreTheOnesWithASpecimenAndTheCountIsTheSystems() {
        let reference = Self.reference()
        #expect(reference.componentTotal == 3)
        #expect(reference.components.map(\.name) == ["SettingsButton", "ThreadChip"])
        #expect(reference.components.map(\.id) == [0, 1], "a specimen is kept by the component's place in the system's list")
        #expect(reference.components.first?.export == "Shepherd.SettingsButton")
        #expect(reference.componentGroups == ["Settings", "Chat & agents"])
        #expect(reference.count(.components) == 3)
        #expect(reference.componentsSub == "3 in Shepherd UI, drawn live")
        #expect(reference.componentsShown == "Showing 2 of 3, the ones with a specimen.")
    }

    @Test func theHeroDrawsTheSystemsOwnColorsInTheBoardsRoles() throws {
        let reference = Self.reference()
        #expect(reference.tiles.count == 6)
        let lantern = try #require(Self.shepherdUI.colors.first { $0.name == "--lantern" })
        #expect(reference.tiles[0] == .init(light: lantern.value.lowercased(), dark: (lantern.dark ?? lantern.value).lowercased()))
        // A system with other names: its accent and status colors by what their names say, then its next colors.
        var acme = DesignSystemTokens(name: "acme-web", namespace: "acme-web")
        acme.colors = [DesignSystemTokens.Color(name: "--bg", value: "#f8fafc"), DesignSystemTokens.Color(name: "--accent", value: "#4f46e5"),
                       DesignSystemTokens.Color(name: "--success", value: "#059669")]
        let tiles = Self.reference(acme).tiles
        #expect(tiles[0]?.light == "#4f46e5" && tiles[2]?.light == "#059669")
        #expect(tiles.compactMap { $0 }.count == 3, "three colors fill three tiles; the rest stay empty")
    }

    @Test func theContentsCountsAreTheDataAndUsedByListsTheDesignsInTheSystem() {
        let design = DesignSystemPageModel.BoardsRow(id: DesignID(), name: "Refund ledger", detail: "4 boards", count: 4)
        let reference = Self.reference(designs: [design])
        #expect(reference.used.map(\.name) == ["Refund ledger"] && reference.used.first?.boards == 4)
        #expect(reference.count(.colors) == Self.shepherdUI.colors.count)
        #expect(reference.count(.spacing) == 8 && reference.count(.radius) == 4 && reference.count(.size) == 1)
        #expect(reference.count(.principles) == 1)
        #expect(reference.count(.overview) == nil && reference.count(.voice) == nil)
        #expect(Self.reference().used.isEmpty)
        #expect(reference.parts == DesignSystemReference.Part.allCases)
    }

    @Test func everySystemOnceReadGetsThisPage() {
        let tokens = Self.shepherdUI
        let user = DesignSystemSummary(info: DesignSystemInfo(namespace: "shepherd-ui", title: "Shepherd UI", revision: 13, createdAt: 0),
                                       counts: tokens.counts)
        let page = DesignSystemPageModel.make(summary: user, read: DesignSystemRead(summary: user, tokens: tokens, readme: nil, files: []),
                                              build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(page.reference?.title == "Shepherd UI", "the system's own title")
        #expect(page.reference?.componentTotal == 3)
        // A system whose tokens.json is unreadable still gets the page, with nothing in it but its name.
        let broken = DesignSystemPageModel.make(summary: user, read: DesignSystemRead(summary: user, tokens: nil, readme: nil, files: []),
                                                build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(broken.reference?.parts == [.overview])
        // Before it is read: the plain page.
        let reading = DesignSystemPageModel.make(summary: user, read: nil, build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(reading.reference == nil)
    }

    @Test func pageCopyIsTrimmedAndBounded() {
        var tokens = DesignSystemTokens(name: "long", namespace: "long")
        tokens.extra["page"] = .object(["tagline": .string("  " + String(repeating: "x", count: 500) + "  "),
                                        "principles": .array(Array(repeating: .object(["lead": .string("Lead.")]), count: 100))])
        let reference = Self.reference(tokens)
        #expect(reference.tagline?.count == 200)
        #expect(reference.principles.count == 24)
    }
}
