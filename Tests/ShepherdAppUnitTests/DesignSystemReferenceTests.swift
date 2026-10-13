import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The built-in Shepherd UI system's page (DesignSystemPage and its sibling boards) as plain values:
/// derived from the tokens Night Watch generates, with counts taken from the data and never written down.
@Suite("Design system reference")
@MainActor
struct DesignSystemReferenceTests {
    private static let tokens = NightWatchSystem.tokens()
    private static func reference(designs: [DesignSystemPageModel.BoardsRow] = []) -> DesignSystemReference {
        DesignSystemReference.make(tokens: tokens, namespace: NightWatchSystem.namespace,
                                   designs: designs, components: NWComponentCatalog.entries.count)
    }

    @Test func everyColorTokenLandsInExactlyOneGroupInTheBoardsOrder() {
        let reference = Self.reference()
        #expect(reference.colors.map(\.title) == ["Surfaces", "Lines", "Text", "Brand and state", "Syntax"])
        #expect(reference.colorCount == Self.tokens.colors.count)
        #expect(Set(reference.colors.flatMap(\.rows).map(\.name)).count == Self.tokens.colors.count)
        #expect(reference.colors[0].rows.map(\.name).first == "--bg-base")
        #expect(reference.colors[2].rows.map(\.name) == ["--text-primary", "--text-secondary", "--text-tertiary"])
    }

    @Test func darkAndLightValuesAreBothKept() throws {
        let window = try #require(Self.reference().colors[0].rows.first { $0.name == "--bg-window" })
        #expect(window.dark != window.light)
        #expect(window.dark.lowercased() == "#0d0e10" && window.light.lowercased() == "#fbfbfa")
    }

    @Test func onlyTextTokensCarryAContrastRatioAgainstTheirOwnWindow() throws {
        let rows = Self.reference().colors.flatMap(\.rows)
        #expect(rows.filter { $0.lightRatio != nil }.map(\.name) == ["--text-primary", "--text-secondary", "--text-tertiary"])
        let tertiary = try #require(rows.first { $0.name == "--text-tertiary" })
        #expect(try #require(tertiary.darkRatio) < DesignSystemReference.readable)
        let primary = try #require(rows.first { $0.name == "--text-primary" })
        #expect(try #require(primary.lightRatio) >= DesignSystemReference.readable)
    }

    @Test func typeStylesGroupIntoDisplayTextAndMono() {
        let reference = Self.reference()
        #expect(reference.type.map(\.title) == ["Display", "Text", "Mono"])
        #expect(reference.typeCount == NWTextStyle.allCases.count)
        #expect(reference.type[0].rows.first?.tag == "Geist · 28 / 600")
        #expect(reference.type[2].rows.last?.uppercase == true)
    }

    @Test func spacingRadiiAndSizesComeFromTheCodeThatSetsThem() {
        let reference = Self.reference()
        #expect(reference.spacing.map(\.px) == [2, 4, 6, 8, 12, 16, 24, 32])
        #expect(reference.radii.map(\.px) == [4, 6, 8, 12])
        #expect(reference.radii.allSatisfy { !$0.use.isEmpty })
        #expect(reference.sizes.map(\.name) == ["control", "field", "segment", "row", "rail", "thread", "prose"])
        #expect(reference.sizes.first { $0.name == "thread" }?.px == Double(AppLayout.threadMaxWidth))
        #expect(reference.sizes.first { $0.name == "prose" }?.px == Double(AppLayout.proseMaxWidth))
    }

    @Test func theComponentCountIsTheCatalogsAndGroupsAreItsOwn() {
        let reference = Self.reference()
        #expect(reference.components == NWComponentCatalog.entries.count)
        #expect(reference.count(.components) == NWComponentCatalog.entries.count)
        #expect(Set(NWComponentCatalog.groups) == Set(NWComponentCatalog.entries.map(\.group)))
        #expect(Set(NWComponentCatalog.entries.map(\.id)).count == NWComponentCatalog.entries.count)
        #expect(DesignSystemCopy.lead(components: reference.components, namespace: "night-watch").contains("\(reference.components) components"))
    }

    @Test func theContentsCountsAreTheDataAndUsedByListsTheDesignsInTheSystem() {
        let design = DesignSystemPageModel.BoardsRow(id: DesignID(), name: "Refund ledger", detail: "4 boards", count: 4)
        let reference = Self.reference(designs: [design])
        #expect(reference.used.map(\.name) == ["Refund ledger"] && reference.used.first?.boards == 4)
        #expect(reference.count(.colors) == Self.tokens.colors.count)
        #expect(reference.count(.spacing) == 8 && reference.count(.radius) == 4 && reference.count(.size) == 7)
        #expect(reference.count(.overview) == nil && reference.count(.voice) == nil)
        #expect(Self.reference().used.isEmpty)
    }

    @Test func onlyTheBuiltInSystemGetsThisPageAndNoOtherSystemChanges() {
        let builtIn = DesignSystemSummary(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", revision: 1, createdAt: 0),
                                          builtIn: true, counts: Self.tokens.counts)
                let read = DesignSystemRead(summary: builtIn, tokens: Self.tokens, readme: nil, files: [])
        let page = DesignSystemPageModel.make(summary: builtIn, read: read, build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(page.reference?.components == NWComponentCatalog.entries.count)
        let acme = DesignSystemSummary(info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", revision: 1, createdAt: 0),
                                       builtIn: false, counts: Self.tokens.counts)
        let other = DesignSystemPageModel.make(summary: acme, read: DesignSystemRead(summary: acme, tokens: Self.tokens, readme: nil, files: []), build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(other.reference == nil)
        let reading = DesignSystemPageModel.make(summary: builtIn, read: nil, build: nil, spaces: [], designs: [], syncing: false, now: Date())
        #expect(reading.reference == nil)
    }

    @Test func theProvenanceClaimsOnlyWhatTheServerEnforces() {
        let words = DesignSystemCopy.provenance.lowercased()
        #expect(!words.contains("chat ui") && !words.contains("nothing to"), "no claim the code does not back")
        #expect(words.contains("read-only") && words.contains("never synced"))
    }

    @Test func thePageNamesTheSystemAsTheBoardsDoWithoutChangingItsRegisteredIdentity() {
        #expect(Self.reference().title == "Shepherd UI")
        #expect(NightWatchSystem.title == "Night Watch" && NightWatchSystem.namespace == "night-watch", "the stored identity is not renamed")
        #expect(NightWatchSystem.builtIn().info.title == "Night Watch")
    }
}
