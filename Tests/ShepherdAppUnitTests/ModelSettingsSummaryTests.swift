import ShepherdCore
import ShepherdSessions
import ShepherdUI
import Testing
@testable import ShepherdApp

/// What the composer's one model-settings button says, and which models carry the Fast mark.
@Suite("Model settings summary")
struct ModelSettingsSummaryTests {
    private func summary(speed: ServiceTier, speedOffered: Bool = true, thinking: String? = "medium", thinkingOffered: Bool = true,
                         model: String = "anthropic/claude-opus", shortened: Bool = false, compact: Bool = false) -> ModelSettingsSummary {
        ModelSettingsSummary(model: model, thinking: thinking, thinkingOffered: thinkingOffered, speed: speed, speedOffered: speedOffered,
                             shortenedName: shortened, dropsThinking: compact)
    }

    @Test func standardSpeedDrawsNoBoltAndFastDrawsOne() {
        #expect(summary(speed: .standard).fast == false)
        #expect(summary(speed: .fast).fast == true)
    }

    /// An agent can keep Fast for when it comes back to a model that takes it: on a model with no
    /// raised tier the button shows nothing of it.
    @Test func aModelWithoutAFastTierNeverShowsTheBolt() {
        let plain = summary(speed: .fast, speedOffered: false)
        #expect(plain.fast == false && plain.value == "Medium")
    }

    @Test func theLevelFollowsTheModelAndNeverShowsForOneWithoutThinking() {
        #expect(summary(speed: .standard).thinking == "Medium")
        #expect(summary(speed: .standard, thinking: "xhigh").thinking == "Extra high")
        #expect(summary(speed: .standard, thinkingOffered: false).thinking == nil)
        #expect(summary(speed: .standard, thinking: nil).thinking == nil)
    }

    @Test func theCompactSizeDropsTheLevelFromTheLabelButVoiceOverStillHearsIt() {
        let compact = summary(speed: .fast, compact: true)
        #expect(compact.thinking == nil && compact.fast)
        #expect(compact.value == "Medium, Fast")
        #expect(summary(speed: .standard).value == "Medium")
        #expect(summary(speed: .standard, thinkingOffered: false, model: "x/y").value == "")
    }

    @Test(arguments: [
        ("anthropic/claude-opus-4-5", false, "claude-opus-4-5"),
        ("anthropic/claude-sonnet-4-5-20250929", true, "claude-sonnet-4-5"),
        ("anthropic/claude-sonnet-4-5-20250929", false, "claude-sonnet-4-5-20250929"),
    ] as [(String, Bool, String)])
    func aNarrowRowDropsAReleaseDateFromTheName(model: String, shortened: Bool, name: String) {
        #expect(summary(speed: .standard, model: model, shortened: shortened).name == name)
    }

    // MARK: The catalog's Fast flag

    private static let entries = [
        PiModelCatalog.Entry(id: "openai/gpt-5", context: "400K"),
        PiModelCatalog.Entry(id: "anthropic/claude-opus", context: "200K"),
        PiModelCatalog.Entry(id: "openai/gpt-5-mini", context: "400K"),
    ]
    private static let tiers = ["openai/gpt-5": ["standard", "fast"], "openai/gpt-5-mini": ["standard"]]

    @Test func onlyAModelThatOffersARaisedTierIsMarkedFast() {
        let catalog = ModelCatalog(Self.entries, serviceTiers: Self.tiers)
        #expect(catalog.models.map(\.fast) == [true, false, false])
        #expect(ModelCatalog(Self.entries).models.map(\.fast) == [false, false, false], "a host that says nothing marks nothing")
    }

    @Test func thePickerTagsEachFastModelsRow() {
        let catalog = ModelCatalog(Self.entries, serviceTiers: Self.tiers)
        let list = catalog.list(query: "", recent: ["openai/gpt-5"], current: "anthropic/claude-opus")
        #expect(list.options.map(\.fast) == [true, false, false], "Recent's gpt-5, then the rest in catalog order")
    }

    @Test func theSettingsPopoverMarksTheCurrentModelByTheThreadAndTheOthersByTheCatalog() {
        let catalog = ModelCatalog(Self.entries, serviceTiers: Self.tiers)
        let choices = ModelCatalog.settingsModels(catalog: catalog, current: "anthropic/claude-opus", recent: ["openai/gpt-5"],
                                                  currentOffersFast: false)
        #expect(choices.map(\.fast) == [false, true])
        let swapped = ModelCatalog.settingsModels(catalog: catalog, current: "openai/gpt-5", recent: ["anthropic/claude-opus"],
                                                  currentOffersFast: true)
        #expect(swapped.map(\.fast) == [true, false])
        let unlisted = ModelCatalog.settingsModels(catalog: catalog, current: "openai/gpt-5", recent: [], currentOffersFast: false)
        #expect(unlisted.map(\.fast) == [false], "the thread says whether its own model offers Fast, whatever the catalog holds")
    }
}
